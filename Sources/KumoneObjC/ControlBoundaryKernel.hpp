#pragma once

// Portable processing kernel used by the serial production output AU,
// after the final mixed DSP and user gain.
// prepare() allocates on the stopped/control side. processFrame() allocates
// nothing and never locks, logs, touches Swift, dispatches or changes clocks.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace qieting {

class BoundarySmoother {
public:
    enum class Command : std::uint64_t { none = 0, pause = 1, resume = 2, start = 3 };
    enum class Mode { unarmed, paused, recentRunningControl, waitingForSignal };
    struct Receipt {
        std::uint64_t inputID = noFrame;
        double gain = 1;
        bool hasInput = false;
    };
    struct Statistics {
        std::uint64_t inputFrames = 0;
        std::uint64_t realOutputFrames = 0;
        std::uint64_t silenceEntriesSmoothed = 0;
        std::uint64_t silenceExitsSmoothed = 0;
        std::uint64_t retiredNoGapWindows = 0;
        std::uint64_t modifiedOutputFrames = 0;
    };
    static constexpr std::uint64_t noFrame = std::numeric_limits<std::uint64_t>::max();
    static constexpr std::uint32_t confirmationFrames = 2;
    // Detection only; raw samples are never snapped to zero or discarded.
    // CI43's real DSP tail at the pause edge is about 5e-15, not exact zero.
    // 1e-12 (-240 dBFS) is far below one 24-bit source LSB (~6e-8), while
    // remaining large enough to recognize that measured numerical tail.
    static constexpr float silenceDetectionFloor = 1e-12f;
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
                  "Transport publication must be lock-free on the target");

    void prepare(double sampleRate, std::uint32_t channels, double envelopeMilliseconds) {
        if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 768000
            || channels == 0 || channels > 32 || !std::isfinite(envelopeMilliseconds)
            || envelopeMilliseconds <= 0 || envelopeMilliseconds > 20)
            throw std::invalid_argument("Invalid stopped-side DSP preparation");
        rate_ = sampleRate;
        channels_ = channels;
        length_ = std::max<std::uint32_t>(2, static_cast<std::uint32_t>(std::ceil(rate_ * envelopeMilliseconds / 1000)));
        delay_ = length_ + confirmationFrames;
        capacity_ = delay_ + 1;
        raw_.assign(static_cast<std::size_t>(capacity_) * channels_, 0);
        gains_.assign(capacity_, 1);
        ids_.assign(capacity_, noFrame);
        fadeIn_.resize(length_);
        fadeOut_.resize(length_);
        constexpr double pi = 3.1415926535897932384626433832795;
        for (std::uint32_t i = 0; i < length_; ++i) {
            const double u = static_cast<double>(i) / (length_ - 1);
            const double s = std::sin(pi * u / 2);
            const double c = std::cos(pi * u / 2);
            fadeIn_[i] = s * s;
            fadeOut_[i] = c * c;
        }
        // Exact endpoints, including exact digital silence, are intentional.
        fadeIn_.front() = 0;
        fadeIn_.back() = 1;
        fadeOut_.front() = 1;
        fadeOut_.back() = 0;
        resetStopped();
    }

    // Call only while rendering is stopped. Never call for ordinary pause,
    // resume, deck retirement, segment hand-off or direct song replacement.
    void resetStopped() noexcept {
        std::fill(raw_.begin(), raw_.end(), 0);
        std::fill(gains_.begin(), gains_.end(), 1);
        std::fill(ids_.begin(), ids_.end(), noFrame);
        nextInput_ = 0;
        silenceRun_ = confirmationFrames;
        fadeInStart_ = noFrame;
        mode_ = Mode::unarmed;
        runningDeadline_ = 0;
        mayContainMultipleControls_ = false;
        pauseSilenceObserved_ = false;
        controlSerial_ = 0;
        consumedSerial_ = 0;
        command_.store(0, std::memory_order_relaxed);
        statistics_ = {};
    }

    // Single producer: the existing serial engine-control queue. `budget` is
    // NOT an arbitrary UI delay: the caller must derive it from the measured
    // upstream DSP/prefetch bound in FINAL output frames. The wrapper must log
    // that provenance outside rendering. The portable test supplies a known
    // simulated pipeline bound; it does not validate a physical-device bound.
    void announce(Command kind, std::uint32_t budget, std::uint64_t serialAdvance = 1) noexcept {
        constexpr std::uint64_t budgetMask = (1ULL << 22) - 1;
        const auto bounded = std::min<std::uint64_t>(budget, budgetMask);
        controlSerial_ += std::max<std::uint64_t>(1, serialAdvance);
        const auto serial = controlSerial_;
        command_.store((serial << 24) | (bounded << 2) | static_cast<std::uint64_t>(kind),
                       std::memory_order_release);
    }

    // Called once by each real render invocation, never from the UI. Repeated
    // same-state commands have no waveform effect unless actual silence edges
    // occur. A burst with no IO between commands still retains an epoch change.
    void beginBlock() noexcept {
        const auto packet = command_.load(std::memory_order_acquire);
        const auto serial = packet >> 24;
        if (serial == consumedSerial_) return;
        const auto delta = serial - consumedSerial_;
        const bool unresolved = mode_ == Mode::recentRunningControl
            || (mode_ == Mode::paused && !pauseSilenceObserved_);
        consumedSerial_ = serial;
        const auto kind = static_cast<Command>(packet & 3);
        const auto budget = static_cast<std::uint32_t>((packet >> 2) & ((1ULL << 22) - 1));
        mayContainMultipleControls_ = delta > 1 || unresolved;
        runningDeadline_ = nextInput_ + budget;
        if (kind == Command::pause) {
            mode_ = Mode::paused;
            pauseSilenceObserved_ = silenceRun_ >= confirmationFrames;
        } else if (kind == Command::resume || kind == Command::start) {
            mode_ = silenceRun_ >= confirmationFrames ? Mode::waitingForSignal : Mode::recentRunningControl;
        } else {
            mode_ = Mode::unarmed;
        }
    }

    // input/output are noninterleaved single-frame channel arrays. A wrapper
    // can call this inside its preallocated planar-buffer loop. `rawOutput` is
    // optional test-only raw POST-DSP input BEFORE the gain, with the SAME
    // fixed FIFO latency; it is never substituted for the actual output.
    // Every receipt with hasInput=true consumes exactly the next inputID.
    bool processFrame(const float *input, float *output, Receipt &receipt, float *rawOutput = nullptr) noexcept {
        if (channels_ == 0 || capacity_ == 0) return false;
        const auto id = nextInput_++;
        const auto write = static_cast<std::size_t>(id % capacity_);
        ids_[write] = id;
        gains_[write] = 1;
        bool silent = true;
        for (std::uint32_t c = 0; c < channels_; ++c) {
            raw_[write * channels_ + c] = input[c];
            // This floor only classifies an explicitly control-armed edge;
            // the original sub-floor post-DSP samples remain in the FIFO.
            silent = silent && std::abs(input[c]) <= silenceDetectionFloor;
        }
        // Resume while already silent has a finite refill/control window too.
        // A later natural musical note outside that budget must stay intact.
        // Paused mode remains armed for arbitrarily long intentional pauses;
        // the accepted resume establishes its own new bounded window.
        if ((mode_ == Mode::recentRunningControl || mode_ == Mode::waitingForSignal)
            && id >= runningDeadline_ && fadeInStart_ == noFrame) {
            mode_ = Mode::unarmed;
            ++statistics_.retiredNoGapWindows;
        }
        const bool armed = mode_ != Mode::unarmed;
        const auto beforeSilence = silenceRun_;
        if (silent) {
            if (silenceRun_ < confirmationFrames) ++silenceRun_;
            if (beforeSilence < confirmationFrames && silenceRun_ == confirmationFrames) {
                if (armed) {
                    const auto lastSignal = id >= confirmationFrames ? id - confirmationFrames : noFrame;
                    if (lastSignal != noFrame) {
                        for (std::uint32_t i = 0; i < length_; ++i) {
                            const auto offset = length_ - 1 - i;
                            if (lastSignal < offset) continue;
                            const auto taperedID = lastSignal - offset;
                            const auto slot = static_cast<std::size_t>(taperedID % capacity_);
                            if (ids_[slot] == taperedID)
                                gains_[slot] = std::min(gains_[slot], fadeOut_[i]);
                        }
                        ++statistics_.silenceEntriesSmoothed;
                    }
                    if (mode_ == Mode::recentRunningControl) mode_ = Mode::waitingForSignal;
                    if (mode_ == Mode::paused) pauseSilenceObserved_ = true;
                }
                fadeInStart_ = noFrame;
            }
        } else {
            if (beforeSilence >= confirmationFrames && armed) {
                fadeInStart_ = id;
                ++statistics_.silenceExitsSmoothed;
                if (mode_ == Mode::waitingForSignal) {
                    mode_ = Mode::recentRunningControl;
                    runningDeadline_ = mayContainMultipleControls_
                        ? std::max(runningDeadline_, id + length_) : id + length_;
                }
            }
            silenceRun_ = 0;
            if (mode_ == Mode::paused) pauseSilenceObserved_ = false;
        }
        // Advance through isolated zero crossings too. Resetting an in-ramp
        // on a single zero would jump gain back to unity on the next sample.
        if (fadeInStart_ != noFrame) {
            const auto age = id - fadeInStart_;
            if (age < length_) gains_[write] = std::min(gains_[write], fadeIn_[age]);
            if (age + 1 >= length_) fadeInStart_ = noFrame;
        }
        ++statistics_.inputFrames;
        if (id < delay_) {
            for (std::uint32_t c = 0; c < channels_; ++c) {
                output[c] = 0;
                if (rawOutput) rawOutput[c] = 0;
            }
            receipt = {};
            return true;
        }
        const auto outputID = id - delay_;
        const auto read = static_cast<std::size_t>(outputID % capacity_);
        if (ids_[read] != outputID) return false;
        const auto gain = gains_[read];
        for (std::uint32_t c = 0; c < channels_; ++c) {
            const auto raw = raw_[read * channels_ + c];
            if (rawOutput) rawOutput[c] = raw;
            output[c] = static_cast<float>(raw * gain);
        }
        receipt = {outputID, gain, true};
        ++statistics_.realOutputFrames;
        if (gain != 1) ++statistics_.modifiedOutputFrames;
        return true;
    }

    double sampleRate() const noexcept { return rate_; }
    std::uint32_t channels() const noexcept { return channels_; }
    std::uint32_t envelopeFrames() const noexcept { return length_; }
    std::uint32_t delayFrames() const noexcept { return delay_; }
    double delaySeconds() const noexcept { return delay_ / rate_; }
    Mode modeForTesting() const noexcept { return mode_; }
    Statistics statisticsAfterStoppedRendering() const noexcept { return statistics_; }

private:
    double rate_ = 0;
    std::uint32_t channels_ = 0, length_ = 0, delay_ = 0, capacity_ = 0;
    std::vector<float> raw_;
    std::vector<double> gains_, fadeIn_, fadeOut_;
    std::vector<std::uint64_t> ids_;
    std::atomic<std::uint64_t> command_{0};
    std::uint64_t controlSerial_ = 0, consumedSerial_ = 0;
    std::uint64_t nextInput_ = 0, fadeInStart_ = noFrame, runningDeadline_ = 0;
    std::uint32_t silenceRun_ = confirmationFrames;
    Mode mode_ = Mode::unarmed;
    bool mayContainMultipleControls_ = false, pauseSilenceObserved_ = false;
    Statistics statistics_;
};

} // namespace qieting
