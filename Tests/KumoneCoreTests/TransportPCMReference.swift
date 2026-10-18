import AVFoundation
import Foundation
@testable import KumoneCore

/// FIFO of uninterrupted production-DSP PCM, for SYNTHETIC non-silent test
/// fixtures. It never seeks or searches for a matching offset. Every rendered
/// non-silent frame consumes exactly the next golden frame, so a skipped or
/// repeated source frame makes the sample comparison fail.
///
/// Near-zero frames may be excluded ONLY in an explicitly issued pause or the
/// bounded DSP-refill window after resume; callers must assert the refill
/// silence count against measured AU latency. Ordinary playback excludes none.
final class TransportPCMReference {
    private var golden: [[Float]]
    private(set) var comparedFrames = 0
    private(set) var intentionalSilenceFrames = 0
    private(set) var maximumSampleError: Float = 0
    private(set) var maximumSignal: Float = 0

    init(engine: PlaybackEngine, quantum: AVAudioFrameCount, buffers: Int = 80) throws {
        var channels: [[Float]] = []
        for _ in 0..<buffers {
            let buffer = try engine.renderOfflineForTesting(quantum)
            guard let data = buffer.floatChannelData else { throw Self.error("Golden output must be float PCM") }
            if channels.isEmpty { channels = Array(repeating: [], count: Int(buffer.format.channelCount)) }
            for channel in channels.indices {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
        }
        golden = channels
    }

    @discardableResult
    func compare(_ buffer: AVAudioPCMBuffer, allowingIntentionalSilence: Bool = false) throws -> Int {
        guard let data = buffer.floatChannelData, Int(buffer.format.channelCount) == golden.count else {
            throw Self.error("Subject PCM format differs from golden output")
        }
        var excluded = 0
        for frame in 0..<Int(buffer.frameLength) {
            var peak: Float = 0
            for channel in golden.indices {
                guard data[channel][frame].isFinite else { throw Self.error("Nonfinite subject PCM") }
                peak = max(peak, abs(data[channel][frame]))
            }
            maximumSignal = max(maximumSignal, peak)
            if allowingIntentionalSilence && peak < 0.000_000_01 {
                excluded += 1
                intentionalSilenceFrames += 1
                continue
            }
            guard comparedFrames < (golden.first?.count ?? 0) else {
                throw Self.error("Golden output exhausted; no source frame may be silently omitted")
            }
            for channel in golden.indices {
                guard golden[channel][comparedFrames].isFinite else { throw Self.error("Nonfinite reference PCM") }
                maximumSampleError = max(maximumSampleError,
                    abs(data[channel][frame] - golden[channel][comparedFrames]))
            }
            comparedFrames += 1
        }
        return excluded
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "TransportPCMReference", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
