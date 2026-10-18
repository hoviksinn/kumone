import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

/// A small artifact supplements assertions with measurements from the actual
/// CI run. No audio content or user data is written to disk.
private enum TransportEvidence {
    static let lock = NSLock()
    static var cases: [[String: Any]] = []

    static func record(_ measurements: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        cases.append(measurements)
        let report: [String: Any] = [
            "scope": "Deterministic offline production DSP; physical output and listening are not verified",
            "sampleRate": DeckChain.format.sampleRate,
            "cases": cases,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".build/transport-validation.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        print("TRANSPORT_PCM \(String(data: try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]), encoding: .utf8)!)")
    }
}

/// Device-independent regressions: pull deterministic PCM through the *actual*
/// PlaybackEngine graph, then compare every sample with uninterrupted playback.
/// Unlike the real-time smoke suite, these tests never skip for a silent CI
/// audio device. They do not establish the behavior of a physical DAC/driver.
@Suite("Playback transport PCM continuity", .serialized)
struct PlaybackTransportContinuityTests {
    private static let quantum: AVAudioFrameCount = 1024
    private static let sampleRate = DeckChain.format.sampleRate

    /// A chirp plus a second, independent chirp. A periodic 440 Hz sine could
    /// falsely accept a skip/repeat of a whole number of periods.
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QieTingTransport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("nonrepeating.caf")
        let format = DeckChain.format
        let frameCount = AVAudioFrameCount(Self.sampleRate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / Self.sampleRate
                buffer.floatChannelData![channel][frame] = Float(
                    0.18 * sin(2 * .pi * (173 * t + 61 * t * t) + Double(channel) * 0.3)
                    + 0.035 * sin(2 * .pi * (919 * t + 11 * t * t)))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func engine(playing url: URL, from seconds: TimeInterval = 0, bothDecks: Bool = false) throws -> PlaybackEngine {
        let engine = PlaybackEngine()
        try engine.enableOfflineRenderingForTesting(maximumFrameCount: Self.quantum)
        _ = try engine.loadFile(at: url, on: .a)
        engine.play(deck: .a, from: seconds)
        if bothDecks {
            _ = try engine.loadFile(at: url, on: .b, trimDB: -6)
            engine.play(deck: .b, from: 0)
        }
        #expect(engine.transportSnapshotForTesting(.a).nodePlaying)
        return engine
    }

    private func samples(_ engine: PlaybackEngine) throws -> [Float] {
        let buffer = try engine.renderOfflineForTesting(Self.quantum)
        let channels = try #require(buffer.floatChannelData)
        return (0..<Int(buffer.format.channelCount)).flatMap { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
        }
    }

    @discardableResult
    private func expectSamePCM(_ actual: [Float], _ reference: [Float], context: String) -> Float {
        #expect(actual.count == reference.count, "\(context): no frames lost or inserted")
        let peakDifference = zip(actual, reference).map { abs($0 - $1) }.max() ?? .infinity
        #expect(peakDifference < 0.000_01,
                "\(context): sample difference \(peakDifference); skip/repeat/silence is not allowed")
        return peakDifference
    }

    @Test(arguments: [false, true])
    func repeatedPauseResumePreservesEveryPCMFrame(bothDecks: Bool) throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reference = try engine(playing: url, bothDecks: bothDecks)
        let subject = try engine(playing: url, bothDecks: bothDecks)
        defer { reference.stopAll(); subject.stopAll() }
        let original = subject.transportSnapshotForTesting(.a)
        var maximumSignal: Float = 0
        var maximumSampleError: Float = 0
        var maximumClockErrorFrames = 0.0
        for chunk in 0..<48 {
            if [7, 19, 33].contains(chunk) {
                subject.pause()
                let paused = subject.transportSnapshotForTesting(.a)
                #expect(paused.paused && paused.engineRunning)
                #expect(!paused.nodePlaying, "native source pauses while the DSP graph remains live")
                Thread.sleep(forTimeInterval: 0.025)
                let stillPaused = subject.transportSnapshotForTesting(.a)
                #expect(stillPaused.position == paused.position)
                subject.resume()
                let resumed = subject.transportSnapshotForTesting(.a)
                #expect(!resumed.paused && resumed.engineRunning && resumed.nodePlaying)
                #expect(!resumed.hasPendingPause)
                #expect(resumed.generation == original.generation)
                #expect(resumed.startOffset == original.startOffset)
                #expect(abs(resumed.position - paused.position) <= 2 / Self.sampleRate)
            }
            let expected = try samples(reference)
            let actual = try samples(subject)
            maximumSignal = max(maximumSignal, actual.map(abs).max() ?? 0)
            maximumSampleError = max(maximumSampleError,
                expectSamePCM(actual, expected, context: "chunk \(chunk), bothDecks=\(bothDecks)"))
            let actualPosition = subject.position(of: .a)
            let expectedPosition = reference.position(of: .a)
            maximumClockErrorFrames = max(maximumClockErrorFrames,
                abs(actualPosition - expectedPosition) * Self.sampleRate)
            #expect(abs(actualPosition - expectedPosition) <= 2 / Self.sampleRate,
                    "clock must agree in both directions, including after multiple pauses")
        }
        #expect(maximumSignal > 0.1, "a silent capture must never pass a PCM comparison")
        let futureMediaTime = subject.position(of: .a) + 0.125
        let roundTrip = try #require(subject.roundTripMediaTimeForTesting(on: .a, mediaTime: futureMediaTime))
        #expect(abs(roundTrip - futureMediaTime) <= 2 / Self.sampleRate,
            "AutoMix's native inverse must retain the same media coordinates after repeated pauses")
        try TransportEvidence.record([
            "name": "repeatedPauseResume", "decks": bothDecks ? 2 : 1, "pauseCycles": 3,
            "comparedFramesPerChannel": 48 * Int(Self.quantum), "maximumSignal": maximumSignal,
            "maximumSampleError": maximumSampleError, "maximumClockErrorFrames": maximumClockErrorFrames,
            "nativeInverseRoundTripErrorFrames": abs(roundTrip - futureMediaTime) * Self.sampleRate,
        ])
    }

    @Test func rapidAndDuplicateCommandsDoNotRestartOrReschedule() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reference = try engine(playing: url)
        let subject = try engine(playing: url)
        defer { reference.stopAll(); subject.stopAll() }
        for _ in 0..<8 { _ = try samples(reference); _ = try samples(subject) }
        let before = subject.transportSnapshotForTesting(.a)
        subject.enableTransportCommandTraceForTesting()
        // The public asynchronous command queue is exercised, including commands
        // queued before the preceding command has finished.
        for _ in 0..<24 {
            subject.pause(); subject.pause(); subject.resume(); subject.resume()
        }
        let after = subject.transportSnapshotForTesting(.a)
        #expect(!after.paused && after.engineRunning && after.nodePlaying)
        #expect(after.generation == before.generation)
        #expect(after.startOffset == before.startOffset)
        #expect(!after.hasPendingPause && after.pauseSkew == 0)
        #expect(abs(after.position - before.position) <= 2 / Self.sampleRate)
        let commands = subject.transportCommandTraceForTesting()
        #expect(commands.count == 96)
        for (index, command) in commands.enumerated() {
            #expect(command.sequence == UInt64(index + 1))
            #expect(command.command == (index % 4 < 2 ? "pause" : "resume"))
            #expect(command.accepted == (index % 2 == 0), "duplicate commands must be harmless no-ops")
            #expect(command.requestedAt <= command.executedAt && command.executedAt <= command.completedAt)
            if index > 0 { #expect(commands[index - 1].completedAt <= command.executedAt) }
        }
        var maximumSampleError: Float = 0
        for chunk in 0..<24 {
            maximumSampleError = max(maximumSampleError,
                expectSamePCM(try samples(subject), try samples(reference), context: "rapid resume chunk \(chunk)"))
        }
        try TransportEvidence.record([
            "name": "rapidAndDuplicateCommands", "pauseCycles": 24, "commands": 96,
            "comparedFramesPerChannel": 24 * Int(Self.quantum), "maximumSampleError": maximumSampleError,
            "immediateClockErrorFrames": abs(after.position - before.position) * Self.sampleRate,
            "executedCommandRecords": commands.map(\.evidence),
        ])
    }

    @Test func seekWhilePausedStartsANewAnchorWithoutPayingOldPauseTime() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subject = try engine(playing: url)
        let reference = try engine(playing: url)
        defer { subject.stopAll(); reference.stopAll() }
        for _ in 0..<8 { _ = try samples(subject); _ = try samples(reference) }
        let before = subject.transportSnapshotForTesting(.a)
        subject.pause()
        subject.seek(deck: .a, to: 1.75)
        reference.seek(deck: .a, to: 1.75)
        let seeked = subject.transportSnapshotForTesting(.a)
        #expect(seeked.paused && seeked.generation > before.generation)
        #expect(abs(seeked.position - 1.75) <= 1 / Self.sampleRate)
        Thread.sleep(forTimeInterval: 0.025)
        subject.resume()
        var maximumSampleError: Float = 0
        var maximumSignal: Float = 0
        for chunk in 0..<16 {
            let actual = try samples(subject)
            let expected = try samples(reference)
            maximumSignal = max(maximumSignal, actual.map(abs).max() ?? 0)
            maximumSampleError = max(maximumSampleError,
                expectSamePCM(actual, expected, context: "paused vs ordinary seek chunk \(chunk)"))
        }
        let resumed = subject.transportSnapshotForTesting(.a)
        let uninterrupted = reference.transportSnapshotForTesting(.a)
        // lastRenderTime belongs to the upstream source node. An offline DSP
        // graph can pull/cache ahead of its output, so output-frame count is
        // not a valid absolute clock for that node. Compare the SAME graph's
        // new schedule at the seek target, with a stricter two-frame bound.
        #expect(abs(resumed.position - uninterrupted.position) <= 2 / Self.sampleRate,
                "paused seek must match a fresh source anchor, without pause-time debt or extra frames")
        #expect(!resumed.hasPendingPause && resumed.pauseSkew == 0)
        #expect(!resumed.hasPendingFaderFlush && !uninterrupted.hasPendingFaderFlush,
                "both real seek flush controllers must have completed")
        #expect(abs(resumed.fader - 1) < 0.000_01 && abs(uninterrupted.fader - 1) < 0.000_01)
        // Match an ordinary, unpaused seek with the SAME pre-seek history,
        // flush and native gain smoothing. Comparing to a never-muted start
        // would incorrectly count the normal seek gain ramp as discontinuity.
        for chunk in 0..<8 {
            let actual = try samples(subject)
            let expected = try samples(reference)
            maximumSignal = max(maximumSignal, actual.map(abs).max() ?? 0)
            maximumSampleError = max(maximumSampleError,
                expectSamePCM(actual, expected, context: "post-seek flush chunk \(chunk)"))
        }
        #expect(maximumSignal > 0.1, "matching silent captures must not pass seek PCM validation")
        try TransportEvidence.record([
            "name": "explicitSeekWhilePaused", "seekSeconds": 1.75,
            "reference": "same pre-seek history and ordinary seek, without global pause",
            "renderedFrames": 16 * Int(Self.quantum),
            "referencePositionSeconds": uninterrupted.position, "actualPositionSeconds": resumed.position,
            "subjectRawPlayerFrames": resumed.rawPlayerFrames ?? -1,
            "referenceRawPlayerFrames": uninterrupted.rawPlayerFrames ?? -1,
            "subjectManualOutputFrames": resumed.manualOutputFrames ?? -1,
            "referenceManualOutputFrames": uninterrupted.manualOutputFrames ?? -1,
            "clockErrorFrames": abs(resumed.position - uninterrupted.position) * Self.sampleRate,
            "positionFromOutputFramesSeconds": 1.75 + 16 * Double(Self.quantum) / Self.sampleRate,
            "referenceSourceLeadFrames": (uninterrupted.position - 1.75) * Self.sampleRate - 16 * Double(Self.quantum),
            "comparedFramesPerChannel": 24 * Int(Self.quantum),
            "maximumSampleError": maximumSampleError, "maximumSignal": maximumSignal,
            "subjectFlushPending": resumed.hasPendingFaderFlush,
            "referenceFlushPending": uninterrupted.hasPendingFaderFlush,
        ])
    }

    @Test func explicitPlayFromAPausedSessionResumesTheOtherSurvivingDeck() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subject = try engine(playing: url, bothDecks: true)
        let reference = try engine(playing: url, bothDecks: true)
        defer { subject.stopAll(); reference.stopAll() }
        for _ in 0..<8 { _ = try samples(subject); _ = try samples(reference) }
        let originalB = subject.transportSnapshotForTesting(.b)
        subject.pause()
        #expect(!subject.transportSnapshotForTesting(.b).nodePlaying)
        subject.play(deck: .a, from: 1.75)
        reference.play(deck: .a, from: 1.75)
        let resumedB = subject.transportSnapshotForTesting(.b)
        #expect(resumedB.nodePlaying && !resumedB.paused)
        #expect(resumedB.generation == originalB.generation, "surviving deck must not be rescheduled")
        #expect(resumedB.startOffset == originalB.startOffset)
        var maximumError: Float = 0
        for chunk in 0..<24 {
            maximumError = max(maximumError,
                expectSamePCM(try samples(subject), try samples(reference), context: "explicit-play survivor chunk \(chunk)"))
            #expect(abs(subject.position(of: .b) - reference.position(of: .b)) <= 2 / Self.sampleRate)
        }
        try TransportEvidence.record(["name": "explicitPlayResumesSurvivingDeck", "decks": 2,
            "maximumSampleError": maximumError, "comparedFramesPerChannel": 24 * Int(Self.quantum)])
    }

    @Test func aDeckStoppedDuringGlobalPauseIsNotResurrected() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subject = try engine(playing: url, bothDecks: true)
        let reference = try engine(playing: url, bothDecks: true)
        defer { subject.stopAll(); reference.stopAll() }
        for _ in 0..<8 { _ = try samples(subject); _ = try samples(reference) }
        let originalA = subject.transportSnapshotForTesting(.a)
        subject.pause()
        subject.stop(deck: .b)
        subject.resume()
        reference.stop(deck: .b)
        let stopped = subject.transportSnapshotForTesting(.b)
        #expect(!stopped.nodePlaying && stopped.position == 0)
        #expect(subject.transportSnapshotForTesting(.a).generation == originalA.generation)
        var maximumError: Float = 0
        for chunk in 0..<16 {
            maximumError = max(maximumError,
                expectSamePCM(try samples(subject), try samples(reference), context: "stopped deck chunk \(chunk)"))
        }
        #expect(!subject.transportSnapshotForTesting(.b).nodePlaying)
        try TransportEvidence.record(["name": "stoppedDeckIsNotResurrected", "maximumSampleError": maximumError,
            "comparedFramesPerChannel": 16 * Int(Self.quantum)])
    }

    @Test(arguments: [0.1, 1.0, 5.0, 10.0])
    func pauseBeforeTheFirstRenderKeepsTheScheduleMediaOrigin(heldSeconds: Double) throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subject = try engine(playing: url)
        let reference = try engine(playing: url)
        defer { subject.stopAll(); reference.stopAll() }
        // No offline frame has been pulled, and no native clock has rendered.
        subject.pause()
        let paused = subject.transportSnapshotForTesting(.a)
        #expect(paused.position == 0)
        Thread.sleep(forTimeInterval: heldSeconds)
        #expect(subject.transportSnapshotForTesting(.a).position == 0)
        subject.resume()
        var maximumError: Float = 0
        for chunk in 0..<24 {
            maximumError = max(maximumError,
                expectSamePCM(try samples(subject), try samples(reference), context: "first-render pause chunk \(chunk)"))
            #expect(abs(subject.position(of: .a) - reference.position(of: .a)) <= 2 / Self.sampleRate)
        }
        try TransportEvidence.record(["name": "pauseBeforeFirstRender", "heldSeconds": heldSeconds,
            "maximumSampleError": maximumError, "comparedFramesPerChannel": 24 * Int(Self.quantum)])
    }

    @Test(arguments: [false, true])
    func aRunningGraphDrainsPausedDSPWithoutLosingSourcePCM(bothDecks: Bool) throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reference = try engine(playing: url, bothDecks: bothDecks)
        let subject = try engine(playing: url, bothDecks: bothDecks)
        defer { reference.stopAll(); subject.stopAll() }
        let golden = try TransportPCMReference(engine: reference, quantum: Self.quantum)
        for _ in 0..<8 { try golden.compare(subject.renderOfflineForTesting(Self.quantum)) }
        subject.pause()
        let paused = subject.transportSnapshotForTesting(.a)
        #expect(paused.paused && paused.engineRunning && !paused.nodePlaying)
        let sourceFramesBeforeDrain = golden.comparedFrames
        for _ in 0..<12 {
            try golden.compare(subject.renderOfflineForTesting(Self.quantum), allowingIntentionalSilence: true)
            #expect(subject.position(of: .a) == paused.position,
                "rendering the paused DSP tail and silence must not advance source media time")
        }
        let tailFrames = golden.comparedFrames - sourceFramesBeforeDrain
        let latencyBound = max(Int(ceil(paused.sourceProcessingLatency * Self.sampleRate)),
            Int(paused.actualSourceRenderLeadFrames ?? 0)) + 2 * Int(Self.quantum)
        #expect(tailFrames <= latencyBound, "the natural DSP tail is bounded by measured AU latency")
        subject.resume()
        let resumed = subject.transportSnapshotForTesting(.a)
        #expect(resumed.generation == paused.generation && resumed.startOffset == paused.startOffset)
        #expect(abs(resumed.position - paused.position) <= 2 / Self.sampleRate)
        let refillBuffers = Int(ceil(Double(latencyBound) / Double(Self.quantum)))
        var refillSilenceFrames = 0
        for chunk in 0..<24 {
            refillSilenceFrames += try golden.compare(subject.renderOfflineForTesting(Self.quantum),
                allowingIntentionalSilence: chunk < refillBuffers)
        }
        #expect(refillSilenceFrames <= latencyBound,
            "only measured DSP refill latency may insert silence after native source resume")
        #expect(golden.maximumSampleError < 0.000_01,
            "every non-silent source frame must match the next uninterrupted golden frame; no skip or repeat")
        #expect(golden.maximumSignal > 0.1 && golden.comparedFrames > 24 * Int(Self.quantum))
        try TransportEvidence.record(["name": "pausedDSPDrainAndRefill", "decks": bothDecks ? 2 : 1,
            "pausedRenderedFrames": 12 * Int(Self.quantum), "naturalDSPTailFrames": tailFrames,
            "resumeDSPRefillSilenceFrames": refillSilenceFrames, "measuredAULatencySeconds": paused.sourceProcessingLatency,
            "actualSourceRenderLeadFrames": paused.actualSourceRenderLeadFrames ?? -1,
            "latencyBoundFrames": latencyBound, "comparedSourceFrames": golden.comparedFrames,
            "maximumSampleError": golden.maximumSampleError, "maximumSignal": golden.maximumSignal])
    }

}
