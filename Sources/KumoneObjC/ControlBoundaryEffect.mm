// Process-local serial output effect; no extension, plugin installation,
// signature or storage identity changes. Native validation is documented
// separately; source integration alone is not a Click/Pop acceptance claim.
#import "include/KumoneControlBoundary.h"
#import <AudioToolbox/AudioToolbox.h>
#include "ControlBoundaryKernel.hpp"
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <vector>

#if !__has_feature(objc_arc)
#error ControlBoundaryEffect.mm requires ARC; compile KumoneObjC with -fobjc-arc.
#endif

namespace {
constexpr double envelopeMilliseconds = 2.0;
constexpr uint32_t maximumChannels = 32;
constexpr std::size_t maximumCaptureBytes = 64ULL * 1024 * 1024;
constexpr int64_t noTimestamp = std::numeric_limits<int64_t>::min();
constexpr uint64_t budgetMask = (1ULL << 22) - 1;
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Control publication must be lock-free");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "Render state must be lock-free");
static_assert(std::atomic<double>::is_always_lock_free, "Format publication must be lock-free");
static_assert(std::atomic<bool>::is_always_lock_free, "Ready flags must be lock-free");

static NSError *BoundaryError(NSInteger code, NSString *reason) {
    return [NSError errorWithDomain:@"KumoneControlBoundary" code:code
                            userInfo:@{NSLocalizedDescriptionKey: reason}];
}

static BOOL AssignError(NSError **error, NSInteger code, NSString *reason) {
    if (error) *error = BoundaryError(code, reason);
    return NO;
}

static bool SupportedFormat(AVAudioFormat *format) {
    return format && format.commonFormat == AVAudioPCMFormatFloat32 && !format.isInterleaved
        && std::isfinite(format.sampleRate) && format.sampleRate >= 8000 && format.sampleRate <= 768000
        && format.channelCount > 0 && format.channelCount <= maximumChannels;
}

static bool MatchingFormats(AVAudioFormat *input, AVAudioFormat *output) {
    return SupportedFormat(input) && SupportedFormat(output)
        && input.sampleRate == output.sampleRate && input.channelCount == output.channelCount;
}

static uint32_t DelayForRate(double rate) {
    return static_cast<uint32_t>(std::max(2.0, std::ceil(rate * envelopeMilliseconds / 1000)))
        + qieting::BoundarySmoother::confirmationFrames;
}

struct AudioBufferListDeleter {
    void operator()(AudioBufferList *value) const noexcept { std::free(value); }
};

/// Stable address captured by the AU render block. It is never replaced while
/// the AU exists. Allocation/deallocation obey the host's stopped lifecycle.
struct RenderState {
    qieting::BoundarySmoother kernel;
    std::unique_ptr<AudioBufferList, AudioBufferListDeleter> inputList;
    std::vector<float> inputStorage, fallbackOutputStorage;
    std::array<const float *, maximumChannels> inputs{};
    std::array<float *, maximumChannels> outputs{};
    uint32_t channels = 0, maximumFrames = 0;

    // Only the existing serial engine queue publishes controls. The render
    // block reads a complete packet AFTER its upstream pull, so a source
    // pause observed within that pull cannot be missed by reading too early.
    uint64_t nextControlSerial = 0;
    uint64_t consumedControlSerial = 0;
    std::atomic<uint64_t> controlPacket{0};
    std::atomic<uint64_t> transportCommands{0};
    std::atomic<uint32_t> lastGateBudgetFrames{0};

    // reset() may be called by the host; it does not mutate kernel vectors on
    // a different thread. Its public contract takes effect before the next
    // processed sample, and invalidates old raw-capture epochs explicitly.
    std::atomic<uint64_t> resetRequests{0}, resetControlSerial{0};
    uint64_t consumedResetRequests = 0;
    std::atomic<uint64_t> appliedResetRequests{0};

    // Test-only raw storage. Copy is permitted only between synchronous
    // offline pulls or with rendering quiesced and resources still allocated.
    // No live vector reads; deallocation invalidates this instrumentation.
    uint32_t requestedCaptureFrames = 0, captureCapacity = 0;
    std::vector<float> rawCapture;
    std::vector<int64_t> captureTimestamps;
    std::vector<uint64_t> captureGenerations;
    int64_t captureReadThrough = noTimestamp;

    std::atomic<bool> ready{false}, captureOverflow{false}, captureTimestampFault{false};
    std::atomic<uint32_t> activeRenderCalls{0};
    std::atomic<double> inputRate{0}, outputRate{0};
    std::atomic<uint32_t> publishedChannels{0}, publishedDelay{0}, publishedEnvelope{0};
    std::atomic<uint64_t> generation{0}, inputFrames{0}, outputFrames{0}, modifiedFrames{0};
    std::atomic<uint64_t> silenceEntries{0}, silenceExits{0};
    uint32_t componentFlags = 0;

    void allocate(double rate, uint32_t channelCount, uint32_t maximumFrameCount) {
        ready.store(false, std::memory_order_release);
        if (maximumFrameCount == 0 || maximumFrameCount > std::numeric_limits<uint32_t>::max() / sizeof(float)
            || channelCount == 0 || channelCount > maximumChannels
            || std::size_t(maximumFrameCount) > std::numeric_limits<std::size_t>::max() / channelCount)
            throw std::invalid_argument("Invalid AU render capacity");
        const std::size_t captureBytesPerFrame = channelCount * sizeof(float)
            + sizeof(int64_t) + sizeof(uint64_t);
        if (requestedCaptureFrames > maximumCaptureBytes / captureBytesPerFrame)
            throw std::invalid_argument("Raw-capture storage exceeds its bounded test-only memory budget");
        kernel.prepare(rate, channelCount, envelopeMilliseconds);
        channels = channelCount;
        maximumFrames = maximumFrameCount;
        inputStorage.assign(std::size_t(channelCount) * maximumFrameCount, 0);
        fallbackOutputStorage.assign(std::size_t(channelCount) * maximumFrameCount, 0);
        const auto bytes = offsetof(AudioBufferList, mBuffers) + channelCount * sizeof(AudioBuffer);
        inputList.reset(static_cast<AudioBufferList *>(std::calloc(1, bytes)));
        if (!inputList) throw std::bad_alloc();
        captureCapacity = requestedCaptureFrames;
        rawCapture.assign(std::size_t(captureCapacity) * channelCount, 0);
        captureTimestamps.assign(captureCapacity, noTimestamp);
        captureGenerations.assign(captureCapacity, 0);
        captureReadThrough = noTimestamp;
        // A stopped graph epoch cannot replay a transport packet published
        // for the previous resource epoch and taper a later natural rest.
        consumedControlSerial = controlPacket.load(std::memory_order_acquire) >> 24;
        consumedResetRequests = resetRequests.load(std::memory_order_acquire);
        appliedResetRequests.store(consumedResetRequests, std::memory_order_release);
        captureOverflow.store(false, std::memory_order_relaxed);
        captureTimestampFault.store(false, std::memory_order_relaxed);
        inputRate.store(rate, std::memory_order_relaxed);
        outputRate.store(rate, std::memory_order_relaxed);
        publishedChannels.store(channelCount, std::memory_order_relaxed);
        publishedDelay.store(kernel.delayFrames(), std::memory_order_relaxed);
        publishedEnvelope.store(kernel.envelopeFrames(), std::memory_order_relaxed);
        publishCounters();
    }

    void activate() noexcept {
        generation.fetch_add(1, std::memory_order_relaxed);
        ready.store(true, std::memory_order_release);
    }

    void unprepare() noexcept {
        ready.store(false, std::memory_order_release);
        // The host has finished all rendering before resource deallocation.
        inputList.reset();
        std::vector<float>().swap(inputStorage);
        std::vector<float>().swap(fallbackOutputStorage);
        std::vector<float>().swap(rawCapture);
        std::vector<int64_t>().swap(captureTimestamps);
        std::vector<uint64_t>().swap(captureGenerations);
        captureCapacity = 0;
        channels = maximumFrames = 0;
        kernel.resetStopped();
        publishCounters();
    }

    bool announce(uint32_t command, uint32_t budget) noexcept {
        if (!ready.load(std::memory_order_acquire) || command < 1 || command > 3) return false;
        const uint64_t boundedBudget = std::min<uint64_t>(budget, budgetMask);
        const uint64_t serial = ++nextControlSerial;
        lastGateBudgetFrames.store(static_cast<uint32_t>(boundedBudget), std::memory_order_relaxed);
        transportCommands.store(serial, std::memory_order_relaxed);
        controlPacket.store((serial << 24) | (boundedBudget << 2) | command, std::memory_order_release);
        return true;
    }

    void requestReset() noexcept {
        resetControlSerial.store(controlPacket.load(std::memory_order_acquire) >> 24,
                                 std::memory_order_relaxed);
        resetRequests.fetch_add(1, std::memory_order_release);
    }

    void applyControlsAfterPull() noexcept {
        const uint64_t reset = resetRequests.load(std::memory_order_acquire);
        if (reset != consumedResetRequests) {
            kernel.resetStopped();
            consumedResetRequests = reset;
            consumedControlSerial = resetControlSerial.load(std::memory_order_relaxed);
            captureReadThrough = noTimestamp;
            captureOverflow.store(false, std::memory_order_relaxed);
            captureTimestampFault.store(false, std::memory_order_relaxed);
            // Old slots keep their bytes but are invalid in this new stream
            // epoch; no large capture memset runs on the audio thread.
            generation.fetch_add(1, std::memory_order_relaxed);
            appliedResetRequests.store(reset, std::memory_order_release);
        }
        const uint64_t packet = controlPacket.load(std::memory_order_acquire);
        if (packet != 0) {
            const uint64_t serial = packet >> 24;
            if (serial > consumedControlSerial) {
                const auto kind = static_cast<qieting::BoundarySmoother::Command>(packet & 3);
                const auto budget = static_cast<uint32_t>((packet >> 2) & budgetMask);
                // Preserve coalesced no-render command history. Advancing a
                // serial is bookkeeping, not an extra source/Seek operation.
                kernel.announce(kind, budget, serial - consumedControlSerial);
                consumedControlSerial = serial;
            }
        }
        kernel.beginBlock();
    }

    void restoreInputList(uint32_t count) noexcept {
        inputList->mNumberBuffers = channels;
        for (uint32_t channel = 0; channel < channels; ++channel) {
            auto &buffer = inputList->mBuffers[channel];
            buffer.mNumberChannels = 1;
            buffer.mData = inputStorage.data() + std::size_t(channel) * maximumFrames;
            buffer.mDataByteSize = count * sizeof(float);
        }
    }

    bool bindPulledInput(AudioUnitRenderActionFlags flags, uint32_t count) noexcept {
        if (flags & kAudioUnitRenderAction_OutputIsSilence) {
            // A silent upstream unit need not have written its buffer. Never
            // feed stale scratch contents into the fixed-delay FIFO.
            restoreInputList(count);
            for (uint32_t channel = 0; channel < channels; ++channel) {
                auto *data = inputStorage.data() + std::size_t(channel) * maximumFrames;
                std::fill_n(data, count, 0.0f);
                inputs[channel] = data;
            }
            return true;
        }
        if (inputList->mNumberBuffers != channels) return false;
        for (uint32_t channel = 0; channel < channels; ++channel) {
            const auto &buffer = inputList->mBuffers[channel];
            if (buffer.mNumberChannels != 1 || !buffer.mData || buffer.mDataByteSize < count * sizeof(float))
                return false;
            inputs[channel] = static_cast<const float *>(buffer.mData);
        }
        return true;
    }

    bool bindOutput(AudioBufferList *list, uint32_t count) noexcept {
        if (!list || list->mNumberBuffers != channels) return false;
        for (uint32_t channel = 0; channel < channels; ++channel) {
            auto &buffer = list->mBuffers[channel];
            if (buffer.mData) {
                if (buffer.mNumberChannels != 1 || buffer.mDataByteSize < count * sizeof(float)) return false;
            } else {
                buffer.mData = fallbackOutputStorage.data() + std::size_t(channel) * maximumFrames;
                buffer.mNumberChannels = 1;
            }
            buffer.mDataByteSize = count * sizeof(float);
            outputs[channel] = static_cast<float *>(buffer.mData);
        }
        return true;
    }

    std::size_t captureSlot(int64_t timestamp) const noexcept {
        int64_t slot = timestamp % int64_t(captureCapacity);
        if (slot < 0) slot += captureCapacity;
        return static_cast<std::size_t>(slot);
    }

    void capture(int64_t timestamp, const float *raw, uint64_t epoch) noexcept {
        const auto slot = captureSlot(timestamp);
        if (captureGenerations[slot] == epoch && captureTimestamps[slot] != noTimestamp
            && captureTimestamps[slot] > captureReadThrough)
            captureOverflow.store(true, std::memory_order_relaxed);
        for (uint32_t channel = 0; channel < channels; ++channel)
            rawCapture[slot * channels + channel] = raw[channel];
        captureTimestamps[slot] = timestamp;
        captureGenerations[slot] = epoch;
    }

    void publishCounters() noexcept {
        // This read occurs only on the render thread (or while fully stopped).
        // Cross-thread readers see atomics, never the kernel's mutable struct.
        const auto stats = kernel.statisticsAfterStoppedRendering();
        inputFrames.store(stats.inputFrames, std::memory_order_relaxed);
        outputFrames.store(stats.realOutputFrames, std::memory_order_relaxed);
        modifiedFrames.store(stats.modifiedOutputFrames, std::memory_order_relaxed);
        silenceEntries.store(stats.silenceEntriesSmoothed, std::memory_order_relaxed);
        silenceExits.store(stats.silenceExitsSmoothed, std::memory_order_relaxed);
    }

    AUAudioUnitStatus render(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                             AUAudioFrameCount count, NSInteger bus, AudioBufferList *output,
                             AURenderPullInputBlock __unsafe_unretained pull) noexcept {
        if (!ready.load(std::memory_order_acquire) || bus != 0) return kAudioUnitErr_Uninitialized;
        if (!flags || !timestamp || !pull || !output) return kAudio_ParamError;
        if (count > maximumFrames) return kAudioUnitErr_TooManyFramesToProcess;
        struct RenderCall {
            std::atomic<uint32_t> &calls;
            explicit RenderCall(std::atomic<uint32_t> &value) noexcept : calls(value) { calls.fetch_add(1); }
            ~RenderCall() { calls.fetch_sub(1); }
        } guard(activeRenderCalls);
        restoreInputList(count);
        AudioUnitRenderActionFlags inputFlags = *flags & ~kAudioUnitRenderAction_OutputIsSilence;
        const auto status = pull(&inputFlags, timestamp, count, 0, inputList.get());
        if (status != noErr) return status;
        if (!bindPulledInput(inputFlags, count) || !bindOutput(output, count)) return kAudio_ParamError;
        applyControlsAfterPull();

        bool validTimestamp = false;
        int64_t firstSample = 0;
        if (captureCapacity > 0) {
            const double value = timestamp->mSampleTime;
            validTimestamp = (timestamp->mFlags & kAudioTimeStampSampleTimeValid) && std::isfinite(value)
                && value > double(std::numeric_limits<int64_t>::min()) + maximumFrames
                && value < double(std::numeric_limits<int64_t>::max()) - maximumFrames
                && std::abs(value - std::round(value)) < 0.001;
            if (validTimestamp) firstSample = static_cast<int64_t>(std::llround(value));
            else captureTimestampFault.store(true, std::memory_order_relaxed);
        }
        const uint64_t epoch = generation.load(std::memory_order_relaxed);
        std::array<float, maximumChannels> inputFrame{}, outputFrame{}, rawFrame{};
        bool allZero = true;
        for (uint32_t frame = 0; frame < count; ++frame) {
            for (uint32_t channel = 0; channel < channels; ++channel) inputFrame[channel] = inputs[channel][frame];
            qieting::BoundarySmoother::Receipt receipt;
            if (!kernel.processFrame(inputFrame.data(), outputFrame.data(), receipt,
                                     validTimestamp ? rawFrame.data() : nullptr))
                return kAudioUnitErr_Uninitialized;
            for (uint32_t channel = 0; channel < channels; ++channel) {
                outputs[channel][frame] = outputFrame[channel];
                allZero = allZero && outputFrame[channel] == 0;
            }
            if (validTimestamp) capture(firstSample + frame, rawFrame.data(), epoch);
        }
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        if (allZero) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        publishCounters();
        return noErr;
    }
};
} // namespace

@interface QieTingControlBoundaryAudioUnit : AUAudioUnit {
    AUAudioUnitBus *_inputBus;
    AUAudioUnitBus *_outputBus;
    AUAudioUnitBusArray *_inputs;
    AUAudioUnitBusArray *_outputs;
    std::unique_ptr<RenderState> _state;
}
- (BOOL)announce:(uint32_t)command budget:(uint32_t)budget;
- (BOOL)prepareRawCapture:(uint32_t)capacity error:(NSError **)error;
- (AVAudioPCMBuffer *)copyRawAtSampleTime:(int64_t)start count:(uint32_t)count error:(NSError **)error;
- (BOOL)copySnapshot:(KumoneControlBoundarySnapshot *)snapshot;
- (void)setRegisteredComponentFlags:(uint32_t)flags;
@end

@implementation QieTingControlBoundaryAudioUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!_inputBus) return nil;
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!_outputBus) return nil;
    _inputBus.maximumChannelCount = maximumChannels;
    _outputBus.maximumChannelCount = maximumChannels;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];
    try { _state = std::make_unique<RenderState>(); }
    catch (const std::exception &) {
        AssignError(error, 2, @"Could not allocate the control-boundary processor");
        return nil;
    }
    return self;
}

- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }

- (BOOL)shouldChangeToFormat:(AVAudioFormat *)format forBus:(AUAudioUnitBus *)bus {
    return SupportedFormat(format) && [super shouldChangeToFormat:format forBus:bus];
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (!MatchingFormats(_inputBus.format, _outputBus.format))
        return AssignError(error, 3, @"Control-boundary input/output must have the same actual Float32 planar rate and channels");
    try {
        _state->allocate(_outputBus.format.sampleRate, _outputBus.format.channelCount, self.maximumFramesToRender);
    } catch (const std::exception &) {
        _state->unprepare();
        return AssignError(error, 4, @"Could not prepare bounded audio render resources");
    }
    if (![super allocateRenderResourcesAndReturnError:error]) {
        _state->unprepare();
        return NO;
    }
    _state->activate();
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_state) _state->unprepare();
}

- (void)reset {
    [super reset];
    // Honour the public reset contract before the next processed sample.
    // Production transport must never explicitly call this for source pause,
    // resume or Deck retirement. Tests must observe that host count is stable.
    if (_state) _state->requestReset();
}

- (NSTimeInterval)latency {
    const double rate = _outputBus.format.sampleRate;
    return SupportedFormat(_outputBus.format) ? DelayForRate(rate) / rate : 0;
}

- (NSTimeInterval)tailTime { return self.latency; }

- (AUInternalRenderBlock)internalRenderBlock {
    RenderState *state = _state.get();
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount count, NSInteger bus, AudioBufferList *output,
                              const AURenderEvent *events, AURenderPullInputBlock __unsafe_unretained pull) {
        // No self/Objective-C access, allocation, locks, logging, timers or
        // callbacks into Swift occur in this block or RenderState::render.
        (void)events;
        return state->render(flags, timestamp, count, bus, output, pull);
    };
}

- (BOOL)announce:(uint32_t)command budget:(uint32_t)budget { return _state->announce(command, budget); }

- (BOOL)prepareRawCapture:(uint32_t)capacity error:(NSError **)error {
    if (_state->ready.load(std::memory_order_acquire))
        return AssignError(error, 5, @"Configure raw capture before render resources are allocated");
    // Bound samples plus timestamp/epoch metadata to 64 MiB. Allocation checks
    // again against the final negotiated channels. Production requests zero.
    if (capacity > maximumCaptureBytes / (sizeof(float) + sizeof(int64_t) + sizeof(uint64_t)))
        return AssignError(error, 6, @"Raw capture capacity is outside its bounded test-only limit");
    _state->requestedCaptureFrames = capacity;
    return YES;
}

- (AVAudioPCMBuffer *)copyRawAtSampleTime:(int64_t)start count:(uint32_t)count error:(NSError **)error {
    if (!_state->ready.load(std::memory_order_acquire) || _state->captureCapacity == 0
        || count == 0 || count > _state->captureCapacity || _state->activeRenderCalls.load() != 0
        || start > std::numeric_limits<int64_t>::max() - int64_t(count)) {
        AssignError(error, 7, @"Raw capture is unavailable or not at an offline/stopped copy boundary");
        return nil;
    }
    if (_state->resetRequests.load(std::memory_order_acquire) != _state->appliedResetRequests.load(std::memory_order_acquire)) {
        AssignError(error, 8, @"A pending host reset invalidates the previous raw-capture epoch");
        return nil;
    }
    if (_state->captureOverflow.load(std::memory_order_relaxed)
        || _state->captureTimestampFault.load(std::memory_order_relaxed)) {
        AssignError(error, 17, @"Raw output capture lost an unread frame or a valid actual output timestamp");
        return nil;
    }
    const uint64_t epoch = _state->generation.load(std::memory_order_acquire);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outputBus.format frameCapacity:count];
    if (!buffer || !buffer.floatChannelData) {
        AssignError(error, 9, @"Could not allocate a raw-output observation buffer");
        return nil;
    }
    buffer.frameLength = count;
    for (uint32_t frame = 0; frame < count; ++frame) {
        const int64_t stamp = start + frame;
        const auto slot = _state->captureSlot(stamp);
        if (_state->captureTimestamps[slot] != stamp || _state->captureGenerations[slot] != epoch) {
            AssignError(error, 10, @"Requested actual AU output timestamp is missing, overwritten or belongs to another stream epoch");
            return nil;
        }
        for (uint32_t channel = 0; channel < _state->channels; ++channel)
            buffer.floatChannelData[channel][frame] = _state->rawCapture[slot * _state->channels + channel];
    }
    _state->captureReadThrough = std::max(_state->captureReadThrough, start + count - 1);
    return buffer;
}

- (BOOL)copySnapshot:(KumoneControlBoundarySnapshot *)snapshot {
    if (!snapshot) return NO;
    *snapshot = {};
    snapshot->available = YES;
    snapshot->prepared = _state->ready.load(std::memory_order_acquire);
    snapshot->inputSampleRate = _state->inputRate.load(std::memory_order_relaxed);
    snapshot->outputSampleRate = _state->outputRate.load(std::memory_order_relaxed);
    snapshot->channelCount = _state->publishedChannels.load(std::memory_order_relaxed);
    snapshot->delayFrames = _state->publishedDelay.load(std::memory_order_relaxed);
    snapshot->envelopeFrames = _state->publishedEnvelope.load(std::memory_order_relaxed);
    snapshot->silenceDetectionFloor = qieting::BoundarySmoother::silenceDetectionFloor;
    snapshot->rawCaptureOverflow = _state->captureOverflow.load(std::memory_order_relaxed);
    snapshot->rawCaptureTimestampFault = _state->captureTimestampFault.load(std::memory_order_relaxed);
    snapshot->resourceGeneration = _state->generation.load(std::memory_order_acquire);
    snapshot->modifiedOutputFrames = _state->modifiedFrames.load(std::memory_order_relaxed);
    snapshot->silenceEntriesSmoothed = _state->silenceEntries.load(std::memory_order_relaxed);
    snapshot->silenceExitsSmoothed = _state->silenceExits.load(std::memory_order_relaxed);
    snapshot->inputFrames = _state->inputFrames.load(std::memory_order_relaxed);
    snapshot->outputFrames = _state->outputFrames.load(std::memory_order_relaxed);
    snapshot->transportCommands = _state->transportCommands.load(std::memory_order_relaxed);
    snapshot->hostResetRequests = _state->resetRequests.load(std::memory_order_acquire);
    snapshot->appliedHostResetRequests = _state->appliedResetRequests.load(std::memory_order_acquire);
    snapshot->lastGateBudgetFrames = _state->lastGateBudgetFrames.load(std::memory_order_relaxed);
    snapshot->componentFlags = _state->componentFlags;
    return YES;
}

- (void)setRegisteredComponentFlags:(uint32_t)flags { _state->componentFlags = flags; }
@end

namespace {
static AudioComponentDescription ComponentDescription() {
    const auto fourCC = [](char a, char b, char c, char d) -> OSType {
        return (uint32_t(uint8_t(a)) << 24) | (uint32_t(uint8_t(b)) << 16)
            | (uint32_t(uint8_t(c)) << 8) | uint32_t(uint8_t(d));
    };
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Effect;
    description.componentSubType = fourCC('q', 't', 'c', 'b');
    description.componentManufacturer = fourCC('Q', 'i', 'e', 'T');
    return description;
}

static QieTingControlBoundaryAudioUnit *BoundaryUnit(AVAudioUnitEffect *effect) {
    AUAudioUnit *unit = effect.auAudioUnit;
    return [unit isKindOfClass:QieTingControlBoundaryAudioUnit.class]
        ? static_cast<QieTingControlBoundaryAudioUnit *>(unit) : nil;
}
} // namespace

AVAudioUnitEffect *KumoneCreateControlBoundaryEffect(NSError **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:QieTingControlBoundaryAudioUnit.class
              asComponentDescription:ComponentDescription()
                                name:@"QieTing: Control Boundary" version:1];
    });
    const auto description = ComponentDescription();
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    AudioComponentDescription actual{};
    if (!component || AudioComponentGetDescription(component, &actual) != noErr) {
        AssignError(error, 11, @"The process-local control-boundary Audio Unit was not registered");
        return nil;
    }
    if (actual.componentFlags & kAudioComponentFlag_RequiresAsyncInstantiation) {
        AssignError(error, 12, @"This Audio Unit requires asynchronous instantiation; the synchronous output path is unavailable");
        return nil;
    }
    AVAudioUnitEffect *effect;
    @try {
        effect = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:description];
    } @catch (NSException *exception) {
        AssignError(error, 13, [NSString stringWithFormat:@"Could not construct the output Audio Unit: %@", exception.reason ?: exception.name]);
        return nil;
    }
    QieTingControlBoundaryAudioUnit *unit = BoundaryUnit(effect);
    if (!unit) {
        AssignError(error, 14, @"AVAudioUnitEffect did not expose the registered custom AU subclass");
        return nil;
    }
    [unit setRegisteredComponentFlags:actual.componentFlags];
    return effect;
}

BOOL KumoneArmControlBoundary(AVAudioUnitEffect *effect, uint32_t command, uint32_t gateBudgetFinalFrames) {
    QieTingControlBoundaryAudioUnit *unit = BoundaryUnit(effect);
    return unit ? [unit announce:command budget:gateBudgetFinalFrames] : NO;
}

BOOL KumonePrepareControlBoundaryRawCapture(AVAudioUnitEffect *effect, uint32_t capacityFrames, NSError **error) {
    QieTingControlBoundaryAudioUnit *unit = BoundaryUnit(effect);
    if (!unit) return AssignError(error, 15, @"Raw capture requires the actual registered output processor");
    return [unit prepareRawCapture:capacityFrames error:error];
}

AVAudioPCMBuffer *KumoneCopyControlBoundaryRawOutput(AVAudioUnitEffect *effect, int64_t startingAtSampleTime,
                                                   uint32_t frameCount, NSError **error) {
    QieTingControlBoundaryAudioUnit *unit = BoundaryUnit(effect);
    if (!unit) {
        AssignError(error, 16, @"Raw capture requires the actual registered output processor");
        return nil;
    }
    return [unit copyRawAtSampleTime:startingAtSampleTime count:frameCount error:error];
}

BOOL KumoneReadControlBoundarySnapshot(AVAudioUnitEffect *effect, KumoneControlBoundarySnapshot *snapshot) {
    if (snapshot) *snapshot = {};
    QieTingControlBoundaryAudioUnit *unit = BoundaryUnit(effect);
    return unit ? [unit copySnapshot:snapshot] : NO;
}
