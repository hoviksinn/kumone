import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

/// A physical-output-path measurement, independent of the engine's position
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

    func receive(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        // No engine call from a tap; only a tiny measurement is handed to the
        // worker. The lock is test-only, never a production transport clock.
        guard buffer.format.channelCount >= 2, let data = buffer.floatChannelData,
              buffer.frameLength > 8, buffer.format.sampleRate > 0 else { return }
        let count = Int(buffer.frameLength)
        func decode(_ frame: Int) -> Double? {
            let denominator = Double(data[1][frame])
            guard denominator > 0.005 else { return nil } // pre-roll/finished silence
            let seconds = (Double(data[0][frame]) / denominator - 1) / 0.04
            return seconds >= -0.02 && seconds <= 31 ? seconds : nil
        }
        guard let first = decode(4), let last = decode(count - 5),
              last >= first else { return }
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
                "maximumPCMSkipSeconds": maximumGap, "maximumPCMRepeatSeconds": maximumRepeat,
                "maximumSignal": maximumPeak]
    }
}

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
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
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
         "outputPCMFirstMediaSeconds": pcm?.first ?? -1,
         "outputPCMLastMediaSeconds": pcm?.last ?? -1,
         "outputPCMHostTime": pcm?.host ?? 0,
         "outputPCMReceivedAtHostTime": pcm?.receivedAt ?? 0]
    }

    /// Characterize the native clock before changing its mapping. Full,
    /// sample-only and host-only AVAudioTime conversions are measured against
    /// actual final-output PCM, not another instance of the same clock code.
    /// Diagnostic values are deliberately not repaired by tolerance changes.
    @Test func outputPCMCharacterizesLongAndRapidPauses() async throws {
        let outcome = await runWithWatchdog("encoded-output-media-clock", timeout: 100) {
            Result { try self.measureNativeClocks() }
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
    }

    private func measureNativeClocks() throws -> [String: Any] {
        let url = try encodedFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = PlaybackEngine()
        let capture = EncodedMediaCapture()
        engine.setOutputTimedSampleSinkForTesting { buffer, when in capture.receive(buffer, when: when) }
        defer { engine.stopAll(); engine.setOutputTimedSampleSinkForTesting(nil) }
        _ = try engine.loadFile(at: url, on: .a)
        engine.play(deck: .a, from: 0)
        func waitForOutput(after previous: UInt64 = 0, timeout: Double = 4) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
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
        for duration in [0.1, 1.0, 5.0, 10.0] {
            let before = engine.transportSnapshotForTesting(.a)
            let beforePCM = capture.latest
            engine.pause()
            let paused = engine.transportSnapshotForTesting(.a)
            let pausedPCM = capture.latest
            Thread.sleep(forTimeInterval: duration)
            let held = engine.transportSnapshotForTesting(.a)
            #expect(held.position == paused.position, "media time must remain frozen during a pause")
            let heldPCM = capture.latest
            engine.resume()
            let resumed = engine.transportSnapshotForTesting(.a)
            let resumedPCM = capture.latest
            let advanced = waitForOutput(after: heldPCM?.receivedAt ?? 0)
            #expect(advanced, "output must resume after holding for \(duration) seconds")
            Thread.sleep(forTimeInterval: 0.15)
            let after = engine.transportSnapshotForTesting(.a)
            cases.append(["requestedPauseSeconds": duration,
                "before": dictionary(before, pcm: beforePCM), "paused": dictionary(paused, pcm: pausedPCM),
                "held": dictionary(held, pcm: heldPCM), "resumed": dictionary(resumed, pcm: resumedPCM),
                "after": dictionary(after, pcm: capture.latest)])
        }
        for count in [10, 30] {
            let before = engine.transportSnapshotForTesting(.a)
            let beforePCM = capture.latest
            for _ in 0..<count { engine.pause(); engine.resume() }
            let resumed = engine.transportSnapshotForTesting(.a)
            let resumedPCM = capture.latest
            #expect(!resumed.paused, "serial command queue must preserve final resume intent")
            #expect(resumed.generation == before.generation, "pause/resume must not seek or reschedule")
            let advanced = waitForOutput(after: resumedPCM?.receivedAt ?? 0)
            #expect(advanced, "output must resume after \(count) rapid cycles")
            Thread.sleep(forTimeInterval: 0.15)
            let after = engine.transportSnapshotForTesting(.a)
            cases.append(["rapidPauseCycles": count, "before": dictionary(before, pcm: beforePCM),
                          "resumed": dictionary(resumed, pcm: resumedPCM), "after": dictionary(after, pcm: capture.latest)])
        }
        return ["scope": "real-time final mix output before physical device; stereo ratio encodes source media time",
                "available": true, "sourceSampleRate": DeckChain.format.sampleRate,
                "cases": cases, "pcm": capture.summary]
    }
}
