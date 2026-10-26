import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import KumoneCore

/// Test-owned, bounded storage for the EXISTING post-AU timed tap. The callback
/// only copies to preallocated memory and publishes immutable records. PCM is
/// read only after removing this consumer, never from the AU's raw-capture ring.
private final class LiveSegmentFinalCapture: @unchecked Sendable {
    struct Chunk {
        var offset = 0
        var frames = 0
        var sample: Int64 = 0
        var host: UInt64 = 0
        var rate: Double = 0
    }
    struct Frozen {
        let left: [Float]
        let right: [Float]
        let chunks: [Chunk]
        let faults: Int
    }
    // 60 MiB stereo PCM plus <1 MiB metadata. Covers >10 seconds even at
    // the processor's 768 kHz upper format bound; overflow still fails.
    private let capacity = 7_864_320
    private let chunkCapacity = 16_384
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let chunks: UnsafeMutablePointer<Chunk>
    private let frames = Atomic<Int>(0)
    private let count = Atomic<Int>(0)
    private let faults = Atomic<Int>(0)

    init() {
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        chunks = .allocate(capacity: chunkCapacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        chunks.initialize(repeating: Chunk(), count: chunkCapacity)
    }
    deinit {
        left.deinitialize(count: capacity); left.deallocate()
        right.deinitialize(count: capacity); right.deallocate()
        chunks.deinitialize(count: chunkCapacity); chunks.deallocate()
    }
    func receive(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let offset = frames.load(ordering: .relaxed)
        let index = count.load(ordering: .relaxed)
        let length = Int(buffer.frameLength)
        guard length > 0, buffer.format.channelCount == 2,
              buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
              let data = buffer.floatChannelData, when.isSampleTimeValid, when.isHostTimeValid,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              when.sampleRate == buffer.format.sampleRate,
              length <= capacity - offset, index < chunkCapacity else {
            _ = faults.wrappingAdd(1, ordering: .relaxed)
            return
        }
        left.advanced(by: offset).update(from: data[0], count: length)
        right.advanced(by: offset).update(from: data[1], count: length)
        chunks[index] = Chunk(offset: offset, frames: length, sample: when.sampleTime,
                              host: when.hostTime, rate: buffer.format.sampleRate)
        frames.store(offset + length, ordering: .releasing)
        count.store(index + 1, ordering: .releasing)
    }
    var publishedFrames: Int { frames.load(ordering: .acquiring) }
    /// Caller removes the consumer first. An already dispatched callback can
    /// still append: acquire the METADATA count, then copy only its immutable
    /// prefix. Reading the separately published frame count first could include
    /// PCM whose matching Chunk has not been published yet.
    func freezeAfterRemovingTap() -> Frozen {
        let lengthInChunks = count.load(ordering: .acquiring)
        let length = lengthInChunks == 0 ? 0
            : chunks[lengthInChunks - 1].offset + chunks[lengthInChunks - 1].frames
        return Frozen(left: Array(UnsafeBufferPointer(start: left, count: length)),
                      right: Array(UnsafeBufferPointer(start: right, count: length)),
                      chunks: Array(UnsafeBufferPointer(start: chunks, count: lengthInChunks)),
                      faults: faults.load(ordering: .relaxed))
    }
}

private final class LiveSegmentEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PlaybackEngineEvent] = []
    private var task: Task<Void, Never>?
    init(_ engine: PlaybackEngine) {
        let stream = engine.events
        task = Task(priority: .high) { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }
    deinit { task?.cancel() }
    private func append(_ event: PlaybackEngineEvent) {
        lock.lock(); defer { lock.unlock() }; values.append(event)
    }
    var snapshot: [PlaybackEngineEvent] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

// Inherit the existing native audio suite's serialization. A second live
// AVAudioEngine must not reconfigure CoreAudio while this one is being tapped.
extension PlaybackEngineSmokeTests {
@Suite("Actual post-AU segment control boundary", .serialized)
struct ControlBoundaryLiveSegmentTests {
    private let carrier: Float = 0.08
    private let volume: Float = 0.05
    private let sourceRate = DeckChain.format.sampleRate

    private func wait(_ seconds: Double, for condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    /// Synthetic SOURCE PCM only. Production player scheduling, native host
    /// starts, segment faders, serial effect and final timed tap all run live.
    /// No OfflineTransitionRenderer or TransitionSegmentRenderer is executed.
    private func buffer(seconds: Double, origin: Double) throws -> AVAudioPCMBuffer {
        let result = try #require(AVAudioPCMBuffer(pcmFormat: DeckChain.format,
            frameCapacity: AVAudioFrameCount((seconds * sourceRate).rounded())))
        result.frameLength = result.frameCapacity
        let data = try #require(result.floatChannelData)
        for frame in 0..<Int(result.frameLength) {
            let coordinate = origin + Double(frame) / sourceRate
            data[0][frame] = carrier * Float(1 + 0.04 * coordinate)
            data[1][frame] = carrier
        }
        return result
    }

    private func measure() throws -> [String: Any] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QieTingLiveSegmentFinal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, origin: Double) throws -> URL {
            let url = folder.appendingPathComponent(name).appendingPathExtension("caf")
            let output = try AVAudioFile(forWriting: url, settings: DeckChain.format.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: buffer(seconds: 12, origin: origin))
            return url
        }
        let outgoing = try file("outgoing", origin: 0)
        let incoming = try file("incoming", origin: 2)
        let planned = PlannedTransition(plan: .crossfade(duration: 4, outPoint: 2, inPoint: 0),
                                        style: TransitionStyle(outroEffect: .fade, stagedEQ: false))
        let signature = try #require(TransitionSegment.Signature(plan: planned.plan))
        let segment = TransitionSegment(buffer: try buffer(seconds: 5, origin: 1.5),
            signature: signature, duration: 5, outgoingStart: 1.5,
            handoffIn: 0.5, handoffOut: 0.5, midpointOffset: 2.5, incomingRideDB: 0,
            outgoing: [.init(offset: 0, source: 1.5), .init(offset: 5, source: 6.5)],
            incoming: [.init(offset: 0, source: 0), .init(offset: 0.5, source: 0),
                       .init(offset: 5, source: 4.5)])
        let engine = PlaybackEngine()
        let events = LiveSegmentEvents(engine)
        let capture = LiveSegmentFinalCapture()
        var tapRemoved = false
        engine.setMasterLimiter(false) // Same graph; exact low-level fixture avoids limiter dynamics.
        engine.outputVolume = volume
        engine.enableTransportCommandTraceForTesting()
        engine.setOutputTimedSampleSinkForTesting { buffer, when in capture.receive(buffer, when: when) }
        defer {
            if !tapRemoved { engine.setOutputTimedSampleSinkForTesting(nil) }
            engine.stopAll()
        }
        _ = try engine.loadFile(at: outgoing, on: .a)
        _ = try engine.loadFile(at: incoming, on: .b)
        engine.play(deck: .a, from: 0.5)
        engine.scheduleTransition(planned, from: .a, to: .b)
        engine.armTransitionSegment(segment)
        try #require(engine.hasArmedSegment && engine.lastSegmentDecline == nil,
                     "The production transition must accept the synthetic source segment")
        try #require(wait(5) {
            engine.segmentIsPlaying && !engine.transportSnapshotForTesting(.a).nodePlaying
                && !engine.transportSnapshotForTesting(.b).nodePlaying
        }, "The actual segment must exclusively carry final output after retiring the outgoing player")
        let identity = engine.segmentPauseIdentityForTesting(from: .a)
        let initial = engine.boundarySnapshotForTesting()
        try #require(initial.available && initial.prepared && initial.inputFrames > 0,
                     "A legacy/bypassed path cannot validate final segment output")
        Thread.sleep(forTimeInterval: 0.25)
        let beforeControl = capture.publishedFrames
        try #require(beforeControl > 0, "Actual post-AU timed output is mandatory")
        engine.pause()
        let frozen = engine.transportSnapshotForTesting(.a)
        #expect(frozen.paused && frozen.engineRunning && engine.segmentIsPlaying)
        Thread.sleep(forTimeInterval: 0.35)
        #expect(engine.position(of: .a) == frozen.position)
        #expect(engine.segmentPauseIdentityForTesting(from: .a).generation == identity.generation)
        let beforeResume = capture.publishedFrames
        engine.resume()
        let resumed = engine.transportSnapshotForTesting(.a)
        #expect(!resumed.paused && resumed.engineRunning)
        #expect(abs(resumed.position - frozen.position) <= 2 / sourceRate)
        try #require(wait(2) { capture.publishedFrames > beforeResume + 8192 },
                     "The real final-output tap must keep advancing through pause and resume")
        Thread.sleep(forTimeInterval: 0.25)
        let afterControl = capture.publishedFrames
        let final = engine.boundarySnapshotForTesting()
        #expect(engine.segmentIsPlaying)
        #expect(engine.segmentPauseIdentityForTesting(from: .a).generation == identity.generation)
        #expect(final.available && final.prepared)
        #expect(final.resourceGeneration == initial.resourceGeneration)
        #expect(final.hostResetRequests == initial.hostResetRequests)
        #expect(final.appliedHostResetRequests == initial.appliedHostResetRequests)
        #expect(final.silenceEntriesSmoothed == initial.silenceEntriesSmoothed + 1)
        #expect(final.silenceExitsSmoothed == initial.silenceExitsSmoothed + 1)
        #expect(final.modifiedOutputFrames > initial.modifiedOutputFrames)
        #expect(final.controlBudgetFinalFrames > 0)
        try #require(wait(9) { events.snapshot.contains {
            if case .transitionCompleted(from: .a, to: .b) = $0 { return true }; return false
        } }, "The actual production segment must hand back to the incoming player")
        Thread.sleep(forTimeInterval: 0.1)
        let received = events.snapshot
        let completions = received.filter {
            if case .transitionCompleted(from: .a, to: .b) = $0 { return true }; return false
        }.count
        #expect(completions == 1)
        #expect(received.contains {
            if case let .transitionMidpoint(from: .a, to: .b, via) = $0 { return via.path == .splicedSegment }
            return false
        })
        #expect(engine.transportSnapshotForTesting(.b).nodePlaying)
        let completedProcessor = engine.boundarySnapshotForTesting()
        #expect(completedProcessor.available && completedProcessor.prepared)
        #expect(completedProcessor.resourceGeneration == initial.resourceGeneration)
        #expect(completedProcessor.hostResetRequests == initial.hostResetRequests)
        #expect(completedProcessor.appliedHostResetRequests == initial.appliedHostResetRequests)
        #expect(completedProcessor.silenceEntriesSmoothed == final.silenceEntriesSmoothed)
        #expect(completedProcessor.silenceExitsSmoothed == final.silenceExitsSmoothed)
        #expect(completedProcessor.modifiedOutputFrames == final.modifiedOutputFrames,
                "Ordinary native segment handoff must not reset or re-arm the final envelope")
        let commands = engine.transportCommandTraceForTesting()
        #expect(commands.count == 2 && commands.allSatisfy(\.accepted))
        #expect(commands.map(\.command) == ["pause", "resume"])
        engine.setOutputTimedSampleSinkForTesting(nil)
        tapRemoved = true
        let pcm = capture.freezeAfterRemovingTap()
        try #require(pcm.faults == 0 && !pcm.chunks.isEmpty,
                     "Absent timestamps, wrong formats and capture overflow are hard failures")
        let rate = try #require(pcm.chunks.first?.rate)
        #expect(rate == final.outputSampleRate && final.inputSampleRate == rate)
        for index in pcm.chunks.indices {
            let current = pcm.chunks[index]
            #expect(current.rate == rate && current.host > 0)
            if index > 0 {
                let previous = pcm.chunks[index - 1]
                #expect(current.offset == previous.offset + previous.frames)
                #expect(current.sample == previous.sample + Int64(previous.frames),
                        "The final tap must deliver every actual output timestamp; missing PCM cannot pass")
                #expect(current.host > previous.host)
            }
        }
        // Include one already delivered pre-control chunk; all of this window
        // lies in the segment-only plateau, away from the head/tail faders.
        let preceding = try #require(pcm.chunks.last { $0.offset + $0.frames <= beforeControl })
        let start = preceding.offset
        try #require(afterControl > start && afterControl <= pcm.left.count)
        let left = Array(pcm.left[start..<afterControl])
        let right = Array(pcm.right[start..<afterControl])
        let floor: Float = 0.000_000_000_001
        let silent = right.map { abs($0) <= floor }
        var entries: [Int] = []
        var exits: [Int] = []
        for index in 1..<(right.count - 1) where !silent[index - 1] && silent[index] && silent[index + 1] {
            entries.append(index)
        }
        for index in 2..<right.count where silent[index - 2] && silent[index - 1] && !silent[index] {
            exits.append(index)
        }
        try #require(entries.count == 1 && exits.count == 1,
                     "The captured final segment must contain both actual control boundaries")
        let entry = entries[0], exit = exits[0], n = Int(final.envelopeFrames)
        try #require(n >= 2 && entry >= n && exit + n < right.count)
        var gains = Array(repeating: 1.0, count: right.count)
        for index in (entry + 1)..<exit { gains[index] = 0 }
        for j in 0..<n {
            gains[entry - (n - 1) + j] = j == n - 1 ? 0 : pow(cos(.pi * Double(j) / (2 * Double(n - 1))), 2)
            gains[exit - 1 + j] = j == 0 ? 0 : pow(sin(.pi * Double(j) / (2 * Double(n - 1))), 2)
        }
        let firstCoordinate = (Double(left[0]) / Double(right[0]) - 1) / 0.04
        try #require(firstCoordinate.isFinite && firstCoordinate > segment.spliceStart + segment.handoffIn)
        var sourceOrdinal = 0
        var decodedFrames = 0
        var maximumSourceErrorFrames = 0.0
        var maximumPCMError: Float = 0
        var maximumOvershoot: Float = 0
        let plateau = carrier * volume
        for frame in right.indices {
            try #require(left[frame].isFinite && right[frame].isFinite)
            // Exactly two endpoint source samples are unobservable at zero
            // gain: the last fade-out sample and first fade-in sample. Count
            // their positions, but never claim to have decoded their PCM.
            let carriesSource = frame <= entry || frame >= exit - 1
            let coordinate = firstCoordinate + Double(sourceOrdinal) / rate
            let expectedLeft = Float(Double(carrier) * (1 + 0.04 * coordinate) * Double(volume) * gains[frame])
            let expectedRight = Float(Double(plateau) * gains[frame])
            maximumPCMError = max(maximumPCMError, abs(left[frame] - expectedLeft), abs(right[frame] - expectedRight))
            maximumOvershoot = max(maximumOvershoot, abs(right[frame]) - plateau)
            if !silent[frame] {
                let decoded = (Double(left[frame]) / Double(right[frame]) - 1) / 0.04
                maximumSourceErrorFrames = max(maximumSourceErrorFrames, abs(decoded - coordinate) * sourceRate)
                decodedFrames += 1
            }
            if carriesSource { sourceOrdinal += 1 }
        }
        #expect(maximumPCMError < 0.000_01,
                "Actual live post-AU segment PCM must match the independent short envelope")
        #expect(maximumSourceErrorFrames <= 2,
                "Every decodable segment frame must retain its original source order across pause/resume")
        #expect(maximumOvershoot < 0.000_000_1)
        #expect(right.max() ?? 0 > plateau * 0.9 && decodedFrames > 4096)
        // The capture stayed on the actual final AU through both native
        // handoffs. Every fixture source has the SAME constant right carrier,
        // so linear production head/tail faders must retain it sample by
        // sample. This directly catches a final-output hole/doubling at a
        // handoff, independently of event delivery and of the middle oracle.
        // The changing left code is decoded strictly only in the segment-only
        // window above; mixed head/tail samples do not claim a unique raw owner.
        let firstSteady = try #require(pcm.right.firstIndex { abs($0 - plateau) < 0.000_01 })
        try #require(firstSteady < start && pcm.right.count > afterControl,
                     "Actual final PCM must cover the head, control window and completed tail")
        var handoffCarrierMaximumError: Float = 0
        var handoffSilentFrames = 0
        var headFinalFrames = 0
        var tailFinalFrames = 0
        for frame in firstSteady..<pcm.right.count {
            try #require(pcm.left[frame].isFinite && pcm.right[frame].isFinite)
            guard frame < start || frame >= afterControl else { continue }
            handoffCarrierMaximumError = max(handoffCarrierMaximumError, abs(pcm.right[frame] - plateau))
            if abs(pcm.right[frame]) <= floor { handoffSilentFrames += 1 }
            if frame < start { headFinalFrames += 1 } else { tailFinalFrames += 1 }
        }
        #expect(headFinalFrames > 4096 && tailFinalFrames > 4096)
        #expect(handoffSilentFrames == 0)
        #expect(handoffCarrierMaximumError < 0.000_01,
                "The real final-output carrier must survive both segment handoffs without holes, doubling or extra envelopes")
        let measuredSilentFrames = exit - entry - 1
        return ["name": "live-post-au-segment-pause-resume", "liveNativeGraph": true,
            "syntheticSegmentSource": true, "offlineMixRendererUsed": false,
            "actualPath": "splicedSegment", "completionCount": completions,
            "outputRate": rate, "sourceRate": sourceRate, "outputVolume": volume,
            "finalTapBuffers": pcm.chunks.count, "finalTapFrames": pcm.left.count,
            "analyzedFinalFrames": right.count, "decodedSourceFrames": decodedFrames,
            "zeroGainSourceEndpointsNotDecoded": 2,
            "maximumDecodedSourceErrorFrames": maximumSourceErrorFrames,
            "maximumFinalPCMEnvelopeError": maximumPCMError, "maximumOvershoot": maximumOvershoot,
            "headFinalFrames": headFinalFrames, "tailFinalFrames": tailFinalFrames,
            "headTailFinalCarrierMaximumError": handoffCarrierMaximumError,
            "headTailUnexpectedSilentFrames": handoffSilentFrames,
            "headTailMixedSourceFrameOwnershipProven": false,
            "finalSilentFramesBetweenEnvelopeEndpoints": measuredSilentFrames,
            "envelopeFrames": n, "delayFrames": final.delayFrames,
            "controlBudgetFinalFrames": final.controlBudgetFinalFrames,
            "controlBudgetSource": final.controlBudgetSource,
            "resourceGeneration": final.resourceGeneration, "hostResetRequests": final.hostResetRequests,
            "completedResourceGeneration": completedProcessor.resourceGeneration,
            "completedHostResetRequests": completedProcessor.hostResetRequests,
            "modifiedOutputFramesBefore": initial.modifiedOutputFrames,
            "modifiedOutputFramesAfter": final.modifiedOutputFrames,
            "frozenMediaSeconds": frozen.position, "resumedMediaSeconds": resumed.position,
            "scope": "Actual live segment scheduling and post-AU timed output. Both handoffs retain the constant final carrier within 1e-5; unique source-frame decoding is limited to the segment-only control window and nonzero gain. Zero-gain endpoint PCM and full raw FIFO order require the independent offline same-pull oracle. Not physical DAC/listening or universal nonzero replacement/wet-tail proof."]
    }

    @Test func aLiveSegmentPauseResumeRetainsDecodedSourceOrderAndSmoothsActualFinalPCM() async throws {
        let outcome = await runWithWatchdog("live-post-au-segment", timeout: 25) {
            Result { try self.measure() }
        }
        let result = try #require(outcome, "The mandatory native segment measurement must finish its watchdog")
        try ControlBoundaryEvidence.record(result.get())
    }
}
}
