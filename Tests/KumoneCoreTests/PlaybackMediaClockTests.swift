import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

extension PlaybackEngine.TransportCommandRecord {
    var evidence: [String: Any] {
        ["sequence": sequence, "command": command,
         "requestedAtHostTime": requestedAt, "executedAtHostTime": executedAt,
         "completedAtHostTime": completedAt, "accepted": accepted,
         "pausedAfter": pausedAfter, "engineRunningAfter": engineRunningAfter,
         "deckAPlayingAfter": deckAPlayingAfter, "deckBPlayingAfter": deckBPlayingAfter,
         "segmentPlayingAfter": segmentPlayingAfter]
    }
}

extension PlaybackEngine.TransportResumeAnchorRecord {
    var evidence: [String: Any] {
        ["deck": deck, "choice": choice, "observedAtHostTime": observedAt,
         "sourceSampleTime": sourceSampleTime ?? -1,
         "sourceRenderFrameCount": sourceFrameCount ?? 0,
         "sourceRenderEnd": sourceRenderEnd ?? -1,
         "sourceHostTime": sourceHostTime ?? 0,
         "nodeSampleTime": nodeSampleTime ?? -1,
         "nodeHostTime": nodeHostTime ?? 0,
         "manualOutputFrames": manualOutputFrames ?? -1,
         "selectedSampleTime": selectedSampleTime ?? -1]
    }
}

private final class ClockMeasurementCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
    func sleep(_ seconds: Double) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            try check()
            Thread.sleep(forTimeInterval: max(0, min(0.05, end - ProcessInfo.processInfo.systemUptime)))
        }
    }
}

/// An output-path measurement, independent of the engine's position
/// arithmetic. The left/right PCM ratio encodes source media time. The final
/// mix tap is after production DSP and before the device; it cannot prove a
/// speaker, Bluetooth device or DAC is heard correctly.
private final class EncodedMediaCapture: @unchecked Sendable {
    struct Measurement {
        var first: Double
        var last: Double
        var frames: Int
        var sampleRate: Double
        var host: UInt64
        var receivedAt: UInt64
    }
    private let lock = NSLock()
    private var latestValue: Measurement?
    private var maximumGap = 0.0
    private var maximumRepeat = 0.0
    private var validFrames = 0
    private var bufferCount = 0
    private var maximumPeak: Float = 0
    private var totalFrames = 0
    private var rejectedBuffers = 0

    func receive(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        totalFrames += Int(buffer.frameLength)
        lock.unlock()
        // No engine call from a tap; only a tiny measurement is handed to the
        // worker. The lock is test-only, never a production transport clock.
        guard buffer.format.channelCount >= 2, let data = buffer.floatChannelData,
              buffer.frameLength > 8, buffer.format.sampleRate > 0 else {
            lock.lock(); rejectedBuffers += 1; lock.unlock()
            return
        }
        let count = Int(buffer.frameLength)
        func decode(_ frame: Int) -> Double? {
            let denominator = Double(data[1][frame])
            guard denominator > 0.005 else { return nil } // pre-roll/finished silence
            let seconds = (Double(data[0][frame]) / denominator - 1) / 0.04
            return seconds >= -0.02 && seconds <= 31 ? seconds : nil
        }
        guard let first = decode(4), let last = decode(count - 5),
              last >= first else {
            lock.lock(); rejectedBuffers += 1; lock.unlock()
            return
        }
        let measurement = Measurement(first: first - 4 / buffer.format.sampleRate,
            last: last + 4 / buffer.format.sampleRate,
            frames: count, sampleRate: buffer.format.sampleRate,
            host: when.isHostTimeValid ? when.hostTime : 0,
            receivedAt: mach_absolute_time())
        lock.lock()
        if let previous = latestValue {
            let expectedFirst = previous.last + 1 / buffer.format.sampleRate
            maximumGap = max(maximumGap, measurement.first - expectedFirst)
            maximumRepeat = max(maximumRepeat, expectedFirst - measurement.first)
        }
        latestValue = measurement
        validFrames += count
        bufferCount += 1
        maximumPeak = max(maximumPeak, abs(data[0][count / 2]))
        lock.unlock()
    }

    var latest: Measurement? { lock.lock(); defer { lock.unlock() }; return latestValue }
    var summary: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["validOutputFrames": validFrames, "validOutputBuffers": bufferCount,
                "totalOutputFrames": totalFrames, "rejectedOutputBuffers": rejectedBuffers,
                "sampleRate": latestValue?.sampleRate ?? 0,
                "maximumTapDeliveryGapSeconds": maximumGap, "maximumTapDeliveryRepeatSeconds": maximumRepeat,
                "boundary": "AVAudioNode tap aggregation may discard pending tap delivery at engine restart; use renderQuanta for source continuity",
                "maximumSignal": maximumPeak]
    }
}

// Native-output tests share CoreAudio with the existing transport/transition
// suite. Inherit its serialization so a diagnostic does not reconfigure a
// second real-time graph while another live-output regression is running.
extension PlaybackEngineSmokeTests {
@Suite("Actual PCM and media clocks", .serialized)
struct PlaybackMediaClockTests {
    /// Monotonic, non-periodic stereo PCM: channel R is a reference level,
    /// channel L / R = 1 + .04 * mediaSeconds. This gives an absolute source
    /// time without trusting reportedPosition, host time or a periodic sine.
    /// The level is deliberately below the limiter's threshold.
    private func encodedFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QieTingClock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("encoded-media-time.caf")
        let format = DeckChain.format
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw NSError(domain: "PlaybackMediaClock", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate encoded fixture PCM"])
        }
        var offset = 0
        let total = Int(30 * format.sampleRate)
        while offset < total {
            let count = min(4096, total - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                let seconds = Double(offset + frame) / format.sampleRate
                buffer.floatChannelData![0][frame] = Float(0.05 * (1 + 0.04 * seconds))
                buffer.floatChannelData![1][frame] = 0.05
            }
            try file.write(from: buffer)
            offset += count
        }
        return url
    }

    private func dictionary(_ snapshot: PlaybackEngine.TransportSnapshot,
                            pcm: EncodedMediaCapture.Measurement?) -> [String: Any] {
        ["reportedMediaSeconds": snapshot.position, "pauseSkewSeconds": snapshot.pauseSkew,
         "rawPlayerFrames": snapshot.rawPlayerFrames ?? -1,
         "nodeRenderFrames": snapshot.nodeRenderFrames ?? -1,
         "sampleOnlyPlayerFrames": snapshot.sampleOnlyPlayerFrames ?? -1,
         "hostOnlyPlayerFrames": snapshot.hostOnlyPlayerFrames ?? -1,
         "renderHostTime": snapshot.renderHostTime ?? 0,
         "observedAtHostTime": snapshot.observedAtHostTime,
         "resumeClockPending": snapshot.resumeClockPending,
         "paused": snapshot.paused, "generation": snapshot.generation,
         "lastPauseRequestedAt": snapshot.lastPauseRequestedAt,
         "lastPauseExecutedAt": snapshot.lastPauseExecutedAt,
         "lastPauseCompletedAt": snapshot.lastPauseCompletedAt,
         "lastResumeRequestedAt": snapshot.lastResumeRequestedAt,
         "lastResumeExecutedAt": snapshot.lastResumeExecutedAt,
         "lastResumeCompletedAt": snapshot.lastResumeCompletedAt,
         "renderedSourceAUFramesIncludingSilence": snapshot.renderedSourceFrames,
         "nativeClockBiasFrames": snapshot.nativeClockBiasFrames,
         "sourceProcessingLatencySeconds": snapshot.sourceProcessingLatency,
         "sourceOutputPresentationLatencySeconds": snapshot.sourceOutputPresentationLatency,
         "actualSourceRenderLeadFrames": snapshot.actualSourceRenderLeadFrames ?? -1,
         "outputPCMFirstMediaSeconds": pcm?.first ?? -1,
         "outputPCMLastMediaSeconds": pcm?.last ?? -1,
         "outputPCMSampleRate": pcm?.sampleRate ?? 0,
         "outputPCMHostTime": pcm?.host ?? 0,
         "outputPCMReceivedAtHostTime": pcm?.receivedAt ?? 0]
    }

    /// Compare real render-source PCM with native clocks and retain final-mix
    /// tap evidence separately: tap delivery gaps are not physical lost audio.
    @Test func outputPCMCharacterizesLongAndRapidPauses() async throws {
        let cancellation = ClockMeasurementCancellation()
        defer { cancellation.cancel() }
        let outcome = await runWithWatchdog("encoded-output-media-clock", timeout: 100) {
            Result { try self.measureNativeClocks(cancellation: cancellation) }
        }
        let result = try #require(outcome, "media clock measurement must finish within its watchdog")
        let report = try result.get()
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: root).appendingPathComponent(".build/media-clock-diagnostic.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let compact = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("TRANSPORT_CLOCK_DIAGNOSTIC \(String(decoding: compact, as: UTF8.self))")
        let failures = report["validationFailures"] as? [String] ?? []
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    private func measureNativeClocks(cancellation: ClockMeasurementCancellation) throws -> [String: Any] {
        let url = try encodedFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlaybackEngine()
        let capture = EncodedMediaCapture()
        let renderCapture = try engine.captureRenderQuantaForTesting(on: .a)
        engine.enableTransportCommandTraceForTesting()
        engine.setOutputTimedSampleSinkForTesting { buffer, when in capture.receive(buffer, when: when) }
        defer { engine.stopAll(); engine.setOutputTimedSampleSinkForTesting(nil) }
        _ = try engine.loadFile(at: url, on: .a)
        engine.play(deck: .a, from: 0)
        func waitForOutput(after previous: UInt64 = 0, timeout: Double = 4) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if (try? cancellation.check()) == nil { return false }
                if let current = capture.latest, current.receivedAt > previous { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return false
        }
        guard waitForOutput() else {
            print("TRANSPORT_CLOCK_NOT_RUN: no encoded advancing real-time output; offline PCM tests remain required")
            return ["scope": "real-time final mix output before physical device", "available": false,
                    "reason": "no advancing stereo final-output tap"]
        }
        var cases: [[String: Any]] = []
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        func persistCheckpoint() {
            let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"] ?? FileManager.default.currentDirectoryPath
            let destination = URL(fileURLWithPath: root).appendingPathComponent(".build/media-clock-diagnostic.json")
            let partial: [String: Any] = ["available": true, "incomplete": true,
                "scope": "partial live render observation; test has not completed validation",
                "cases": cases, "pcm": capture.summary,
                "nativeResumeAnchors": engine.transportResumeAnchorTraceForTesting().map(\.evidence),
                "validationFailures": failures]
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: partial, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination, options: .atomic)
            } catch { failures.append("Could not persist partial audio clock evidence: \(error)") }
        }
        var initialSourceClockOffset: Double?
        func validateFrozenSourceClock(_ snapshot: PlaybackEngine.TransportSnapshot) {
            let records = renderCapture.records
            guard let last = records.last(where: { $0.validStereo && $0.rightFirst > 0.005 }) else {
                check(false, "native render quanta must contain the encoded non-silent source")
                return
            }
            let first = (Double(last.leftFirst) / Double(last.rightFirst) - 1) / 0.04
            let offset = snapshot.position - first
            // Pausing freezes the source while already-rendered DSP tail can
            // continue downstream. Thus an immediate paused checkpoint and a
            // fully-drained checkpoint cannot share one constant lead. Bound
            // their actual media difference by the measured processing delay
            // and render quanta; keep the signed baseline change as evidence.
            // This is a pipeline-range check, not sample-perfect DAC alignment.
            let quantum = Double(last.frames + 2) / renderCapture.sampleRate
            let lowerBound = -quantum
            let upperBound = snapshot.sourceProcessingLatency + 2 * quantum
            check(offset >= lowerBound && offset <= upperBound,
                "native/PCM boundary lead \(offset)s outside measured pipeline [\(lowerBound), \(upperBound)]s")
            if initialSourceClockOffset == nil { initialSourceClockOffset = offset }
            cases.append(["frozenSourceClockPosition": snapshot.position,
                "decodedRenderSourcePosition": first, "sourceClockOffsetSeconds": offset,
                "changeFromFirstBoundarySeconds": offset - (initialSourceClockOffset ?? offset),
                "minimumPipelineLeadSeconds": lowerBound, "maximumPipelineLeadSeconds": upperBound,
                "comparisonPhase": "paused-boundary-with-draining-DSP-tail",
                "sourceProcessingLatencySeconds": snapshot.sourceProcessingLatency,
                "sourceOutputPresentationLatencySeconds": snapshot.sourceOutputPresentationLatency,
                "absoluteDACAlignmentVerified": false,
                "renderQuantumFrames": last.frames, "renderQuantumHostTime": last.hostTime])
            print("TRANSPORT_CLOCK_CHECKPOINT source=\(snapshot.position) decoded=\(first) signedLead=\(offset) sourceFrames=\(snapshot.renderedSourceFrames) nativeBiasFrames=\(snapshot.nativeClockBiasFrames)")
            persistCheckpoint()
        }
        for duration in [0.1, 1.0, 5.0, 10.0] {
            try cancellation.check()
            let before = engine.transportSnapshotForTesting(.a)
            let beforePCM = capture.latest
            engine.pause()
            let paused = engine.transportSnapshotForTesting(.a)
            validateFrozenSourceClock(paused)
            let pausedPCM = capture.latest
            try cancellation.sleep(duration)
            let held = engine.transportSnapshotForTesting(.a)
            check(held.position == paused.position, "media time advanced during \(duration)s native pause")
            let heldPCM = capture.latest
            engine.resume()
            let resumed = engine.transportSnapshotForTesting(.a)
            let resumedPCM = capture.latest
            let advanced = waitForOutput(after: heldPCM?.receivedAt ?? 0)
            guard advanced else {
                throw NSError(domain: "PlaybackMediaClock", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Output did not resume after \(duration)s pause"])
            }
            try cancellation.sleep(0.15)
            let after = engine.transportSnapshotForTesting(.a)
            cases.append(["requestedPauseSeconds": duration,
                "before": dictionary(before, pcm: beforePCM), "paused": dictionary(paused, pcm: pausedPCM),
                "held": dictionary(held, pcm: heldPCM), "resumed": dictionary(resumed, pcm: resumedPCM),
                "after": dictionary(after, pcm: capture.latest)])
        }
        for count in [10, 30] {
            let before = engine.transportSnapshotForTesting(.a)
            let beforePCM = capture.latest
            for _ in 0..<count {
                try cancellation.check()
                engine.pause(); engine.resume()
            }
            let resumed = engine.transportSnapshotForTesting(.a)
            let resumedPCM = capture.latest
            check(!resumed.paused, "rapid commands lost final resume intent")
            check(resumed.generation == before.generation, "pause/resume changed source schedule generation")
            let advanced = waitForOutput(after: resumedPCM?.receivedAt ?? 0)
            guard advanced else {
                throw NSError(domain: "PlaybackMediaClock", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Output did not resume after \(count) rapid cycles"])
            }
            try cancellation.sleep(0.15)
            let after = engine.transportSnapshotForTesting(.a)
            cases.append(["rapidPauseCycles": count, "before": dictionary(before, pcm: beforePCM),
                          "resumed": dictionary(resumed, pcm: resumedPCM), "after": dictionary(after, pcm: capture.latest)])
            engine.pause()
            validateFrozenSourceClock(engine.transportSnapshotForTesting(.a))
            engine.resume()
        }
        engine.pause()
        let finalSnapshot = engine.transportSnapshotForTesting(.a)
        validateFrozenSourceClock(finalSnapshot)
        let commands = engine.transportCommandTraceForTesting()
        let quantumReport = validateRenderQuanta(renderCapture, commands: commands, latency: finalSnapshot.sourceProcessingLatency, failures: &failures)
        for (index, command) in commands.enumerated() {
            check(command.sequence == UInt64(index + 1), "transport command sequence is not FIFO")
            check(command.requestedAt <= command.executedAt && command.executedAt <= command.completedAt, "command timestamps are unordered")
            if index > 0 { check(commands[index - 1].completedAt <= command.executedAt, "transport commands overlapped") }
        }
        return ["scope": "real-time final mix output before physical device; stereo ratio encodes source media time",
                "available": true, "sourceSampleRate": DeckChain.format.sampleRate,
                "cases": cases, "pcm": capture.summary, "renderQuanta": quantumReport,
                "executedCommandRecords": commands.map(\.evidence),
                "nativeResumeAnchors": engine.transportResumeAnchorTraceForTesting().map(\.evidence),
                "validationFailures": failures]
    }

    private func validateRenderQuanta(_ capture: PlaybackEngine.RenderQuantumCaptureForTesting,
        commands: [PlaybackEngine.TransportCommandRecord], latency: Double,
        failures: inout [String]) -> [String: Any] {
        let records = capture.records
        var pauseWindows: [(UInt64, UInt64)] = []
        var pauseBegan: UInt64?
        for command in commands where command.accepted {
            if command.command == "pause" { pauseBegan = command.executedAt }
            if command.command == "resume", let start = pauseBegan {
                pauseWindows.append((start, command.completedAt))
                pauseBegan = nil
            }
        }
        if let pauseBegan { pauseWindows.append((pauseBegan, .max)) }
        func intentionalPause(_ record: PlaybackEngine.RenderQuantumCaptureForTesting.Record) -> Bool {
            pauseWindows.contains { record.receivedAt >= $0.0 && record.receivedAt <= $0.1 }
        }
        var previousLast: Double?
        var validFrames = 0
        var invalidBuffers = 0
        var invalidTimestamps = 0
        var renderErrors = 0
        var silenceFlaggedBuffers = 0
        var pausedSilenceFrames = 0
        var resumeSilenceFrames = 0
        var currentRefillSilence = 0
        var maximumRefillSilence = 0
        var maximumGap = 0.0
        var maximumRepeat = 0.0
        var maximumDurationErrorFrames = 0.0
        var largestQuantum: UInt32 = 0
        var failedRecords: [[String: Any]] = []
        func evidence(_ record: PlaybackEngine.RenderQuantumCaptureForTesting.Record, reason: String) -> [String: Any] {
            ["reason": reason, "frames": record.frames, "firstActiveFrame": record.firstActiveFrame,
             "activeFrames": record.activeFrames, "sampleTime": record.sampleTime,
             "hostTime": record.hostTime, "receivedAtHostTime": record.receivedAt,
             "leftFirst": record.leftFirst, "rightFirst": record.rightFirst,
             "leftLast": record.leftLast, "rightLast": record.rightLast,
             "outputIsSilence": record.outputIsSilence, "validStereo": record.validStereo,
             "renderError": record.renderError]
        }
        for record in records {
            largestQuantum = max(largestQuantum, record.frames)
            if !record.validSampleTime || !record.validHostTime { invalidTimestamps += 1 }
            if record.renderError { renderErrors += 1 }
            if record.outputIsSilence { silenceFlaggedBuffers += 1 }
            guard record.validStereo else {
                invalidBuffers += 1
                if failedRecords.count < 12 { failedRecords.append(evidence(record, reason: "missing stereo PCM")) }
                continue
            }
            let silent = Int(record.frames - record.activeFrames)
            if intentionalPause(record) {
                pausedSilenceFrames += silent
                currentRefillSilence = 0
            } else if previousLast != nil {
                resumeSilenceFrames += silent
                currentRefillSilence += Int(record.firstActiveFrame)
                if record.activeFrames == 0 {
                    // firstActiveFrame already contains the whole zero block.
                    maximumRefillSilence = max(maximumRefillSilence, currentRefillSilence)
                } else {
                    maximumRefillSilence = max(maximumRefillSilence, currentRefillSilence)
                    currentRefillSilence = Int(record.frames - record.firstActiveFrame - record.activeFrames)
                }
            }
            guard record.activeFrames > 0 else { continue }
            guard record.rightFirst > 0.005, record.rightLast > 0.005 else {
                invalidBuffers += 1
                if failedRecords.count < 12 { failedRecords.append(evidence(record, reason: "nonzero boundary failed decoding")) }
                continue
            }
            let first = (Double(record.leftFirst) / Double(record.rightFirst) - 1) / 0.04
            let last = (Double(record.leftLast) / Double(record.rightLast) - 1) / 0.04
            guard first.isFinite, last.isFinite, last >= first else {
                invalidBuffers += 1
                if failedRecords.count < 12 { failedRecords.append(evidence(record, reason: "nonfinite or reversed source labels")) }
                continue
            }
            let durationError = abs((last - first) * capture.sampleRate - Double(record.activeFrames - 1))
            maximumDurationErrorFrames = max(maximumDurationErrorFrames, durationError)
            var gap = 0.0
            if let previousLast {
                gap = first - previousLast - 1 / capture.sampleRate
                maximumGap = max(maximumGap, gap)
                maximumRepeat = max(maximumRepeat, -gap)
            }
            if (durationError > 2 || abs(gap) * capture.sampleRate > 2), failedRecords.count < 12 {
                var raw = evidence(record, reason: "source frame span or boundary discontinuity")
                raw["decodedFirstSeconds"] = first
                raw["decodedLastSeconds"] = last
                raw["previousDecodedLastSeconds"] = previousLast ?? -1
                raw["gapFrames"] = gap * capture.sampleRate
                raw["durationErrorFrames"] = durationError
                failedRecords.append(raw)
            }
            previousLast = last
            validFrames += Int(record.activeFrames)
        }
        let refillBound = Int(ceil(latency * capture.sampleRate)) + 2 * Int(largestQuantum)
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        check(capture.overflowCount == 0, "render observer overflowed")
        check(invalidTimestamps == 0 && renderErrors == 0, "render evidence has invalid timestamps or render errors")
        check(validFrames > 4096, "insufficient non-silent render PCM to prove continuity")
        check(invalidBuffers == 0, "\(invalidBuffers) non-silent render records failed decoding")
        check(maximumDurationErrorFrames <= 2, "rendered block source span error \(maximumDurationErrorFrames) frames")
        check(maximumGap * capture.sampleRate <= 2, "source skipped \(maximumGap * capture.sampleRate) frames")
        check(maximumRepeat * capture.sampleRate <= 2, "source repeated \(maximumRepeat * capture.sampleRate) frames")
        check(maximumRefillSilence <= refillBound, "resume silence \(maximumRefillSilence) exceeds measured DSP latency bound \(refillBound)")
        return ["scope": "existing deck delay AudioUnit post-render; before mixer/device, not DAC",
            "sampleRate": capture.sampleRate, "totalBuffers": records.count,
            "validSourceFrames": validFrames, "invalidBuffers": invalidBuffers,
            "invalidTimestamps": invalidTimestamps, "renderErrors": renderErrors,
            "silenceFlaggedBuffers": silenceFlaggedBuffers, "overflowRecords": capture.overflowCount,
            "intentionalPausedSilenceFrames": pausedSilenceFrames,
            "postResumeDSPRefillSilenceFrames": resumeSilenceFrames,
            "maximumConsecutiveDSPRefillSilenceFrames": maximumRefillSilence,
            "DSPRefillLatencyBoundFrames": refillBound, "measuredAULatencySeconds": latency,
            "maximumSourceGapFrames": maximumGap * capture.sampleRate,
            "maximumSourceRepeatFrames": maximumRepeat * capture.sampleRate,
            "maximumBlockDurationErrorFrames": maximumDurationErrorFrames,
            "failedRenderRecords": failedRecords]
    }
}
}
