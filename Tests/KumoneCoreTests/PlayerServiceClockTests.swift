import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

@MainActor
private enum ServiceClockEvidence {
    static var cases: [[String: Any]] = []

    static func record(_ values: [String: Any]) throws {
        cases.append(values)
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let destination = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".build/service-clock-validation.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report: [String: Any] = [
            "scope": "Offline production PCM, PlayerService publisher and lyric cursor; no physical-output or listening claim",
            "completionScope": "Offline dataRendered source completion excludes downstream/device latency; real playback retains dataPlayedBack",
            "sampleRate": DeckChain.format.sampleRate,
            "commandTimestampUnit": "mach_absolute_time ticks; UI issued/confirmed bounds are systemUptime seconds",
            "cases": cases,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
    }
}

/// The real production engine, service sampler, progress publisher and lyric
/// cursor are exercised together. Offline rendering proves internal PCM/media
/// continuity; it does not prove physical-device latency or listening quality.
@Suite("Player service media clock", .serialized)
@MainActor
struct PlayerServiceClockTests {
    private let quantum: AVAudioFrameCount = 1024
    private let sampleRate = DeckChain.format.sampleRate

    private func fixture(duration: TimeInterval = 4) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QieTingServiceClock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chirp.caf")
        let format = DeckChain.format
        let count = AVAudioFrameCount(duration * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(count) {
                let t = Double(frame) / sampleRate
                buffer.floatChannelData![channel][frame] = Float(
                    0.16 * sin(2 * .pi * (191 * t + 43 * t * t) + Double(channel) * 0.2)
                    + 0.03 * sin(2 * .pi * (853 * t + 19 * t * t)))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func engine(_ url: URL) throws -> PlaybackEngine {
        let engine = PlaybackEngine()
        try engine.enableOfflineRenderingForTesting(maximumFrameCount: quantum)
        _ = try engine.loadFile(at: url, on: .a)
        engine.play(deck: .a, from: 0)
        #expect(engine.transportSnapshotForTesting(.a).nodePlaying)
        return engine
    }

    private func service(_ engine: PlaybackEngine) throws -> PlayerService {
        let track = try JSONDecoder().decode(Track.self, from: Data(
            #"{"id":12345,"name":"Clock fixture","dt":4000}"#.utf8))
        let lyrics = ParsedLyrics(lines: (0..<50).map {
            LyricLine(id: $0, time: Double($0) / 10, text: "Line \($0)",
                      words: [LyricWord(text: "Line \($0)", start: Double($0) / 10, duration: 0.1)])
        })
        return PlayerService(playbackEngineForTesting: engine, track: track, lyrics: lyrics)
    }

    private func samples(_ engine: PlaybackEngine) throws -> [Float] {
        let buffer = try engine.renderOfflineForTesting(quantum)
        let channels = try #require(buffer.floatChannelData)
        return (0..<Int(buffer.format.channelCount)).flatMap { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
        }
    }

    @discardableResult
    private func assertSameClock(_ player: PlayerService, engine: PlaybackEngine) async throws -> PlaybackTimeSample {
        let sample = try #require(await player.samplePlaybackTime())
        let engineSeconds = engine.position(of: .a)
        #expect(abs(engineSeconds - sample.seconds) <= 2 / sampleRate)
        #expect(player.progress == sample.seconds)
        #expect(player.livePlaybackTime == sample.seconds)
        #expect(player.lyricsCursor.mediaTime == sample.seconds)
        #expect(player.lyricsCursor.activeIndex == player.lyrics?.activeIndex(at: sample.seconds + 0.2))
        let wordSeconds = await player.livePlaybackTimeAsync()
        #expect(abs(wordSeconds - sample.seconds) <= 2 / sampleRate)
        return sample
    }

    @Test(arguments: [0.1, 1.0, 5.0, 10.0])
    func pausedWallTimeDoesNotBecomeServiceOrLyricTime(pauseSeconds: Double) async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subject = try engine(url)
        let reference = try engine(url)
        defer { subject.stopAll(); reference.stopAll() }
        let player = try service(subject)
        for _ in 0..<8 { _ = try samples(subject); _ = try samples(reference) }
        let before = try await assertSameClock(player, engine: subject)
        let pauseIssued = ProcessInfo.processInfo.systemUptime
        player.pause()
        let frozen = try await assertSameClock(player, engine: subject)
        let pauseConfirmed = ProcessInfo.processInfo.systemUptime
        let pausedTransport = subject.transportSnapshotForTesting(.a)
        #expect(!player.isPlaying)
        #expect(abs(before.seconds - frozen.seconds) <= 2 / sampleRate)
        try await Task.sleep(for: .seconds(pauseSeconds))
        let held = try await assertSameClock(player, engine: subject)
        #expect(held.seconds == frozen.seconds)
        let resumeIssued = ProcessInfo.processInfo.systemUptime
        player.togglePlayPause()
        let resumed = try await assertSameClock(player, engine: subject)
        let resumeConfirmed = ProcessInfo.processInfo.systemUptime
        let resumedTransport = subject.transportSnapshotForTesting(.a)
        #expect(player.isPlaying)
        #expect(abs(resumed.seconds - frozen.seconds) <= 2 / sampleRate)
        var maximumError: Float = 0
        var peak: Float = 0
        for _ in 0..<20 {
            let actual = try samples(subject)
            let expected = try samples(reference)
            #expect(actual.count == expected.count)
            peak = max(peak, actual.map(abs).max() ?? 0)
            maximumError = max(maximumError, zip(actual, expected).map { abs($0 - $1) }.max() ?? .infinity)
            _ = try await assertSameClock(player, engine: subject)
        }
        #expect(maximumError < 0.000_01)
        #expect(peak > 0.1, "matching silence must not validate transport continuity")
        try ServiceClockEvidence.record([
            "name": "pausedWallTime", "pauseSeconds": pauseSeconds,
            "pauseIssuedSeconds": pauseIssued, "pauseConfirmedSeconds": pauseConfirmed,
            "resumeIssuedSeconds": resumeIssued, "resumeConfirmedSeconds": resumeConfirmed,
            "pauseRequestedTicks": pausedTransport.lastPauseRequestedAt,
            "pauseExecutedTicks": pausedTransport.lastPauseExecutedAt,
            "pauseCompletedTicks": pausedTransport.lastPauseCompletedAt,
            "resumeRequestedTicks": resumedTransport.lastResumeRequestedAt,
            "resumeExecutedTicks": resumedTransport.lastResumeExecutedAt,
            "resumeCompletedTicks": resumedTransport.lastResumeCompletedAt,
            "pausedMediaSeconds": frozen.seconds, "resumedMediaSeconds": resumed.seconds,
            "finalEngineSeconds": subject.position(of: .a), "finalServiceSeconds": player.progress,
            "finalLyricsSeconds": player.lyricsCursor.mediaTime,
            "comparedFramesPerChannel": 20 * Int(quantum), "maximumPCMError": maximumError,
        ])
        print("SERVICE_CLOCK pauseSeconds=\(pauseSeconds) issued=\(pauseIssued) confirmed=\(pauseConfirmed) resumeIssued=\(resumeIssued) resumeConfirmed=\(resumeConfirmed) frozen=\(frozen.seconds) resumed=\(resumed.seconds) pcmError=\(maximumError) finalEngine=\(subject.position(of: .a)) finalService=\(player.progress) finalLyrics=\(player.lyricsCursor.mediaTime)")
    }

    @Test func pausedGraphDrainsDSPWhileEveryPublishedMediaClockStaysFrozen() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reference = try engine(url)
        let subject = try engine(url)
        defer { subject.stopAll(); reference.stopAll() }
        let golden = try TransportPCMReference(engine: reference, quantum: quantum)
        let player = try service(subject)
        for _ in 0..<8 { try golden.compare(subject.renderOfflineForTesting(quantum)) }
        _ = try await assertSameClock(player, engine: subject)
        player.pause()
        let frozen = try await assertSameClock(player, engine: subject)
        let paused = subject.transportSnapshotForTesting(.a)
        #expect(paused.paused && paused.engineRunning && !paused.nodePlaying)
        // Model the hardware IO that continues during a native source pause.
        // The production DSP's already-buffered output must be measured, not
        // silently muted or discarded to manufacture an immediate stop.
        var tailPeak: Float = 0
        var settledPeak: Float = 0
        for chunk in 0..<24 {
            let output = try subject.renderOfflineForTesting(quantum)
            try golden.compare(output, allowingIntentionalSilence: true)
            let channels = try #require(output.floatChannelData)
            let peak = (0..<Int(output.format.channelCount)).map { channel in
                (0..<Int(output.frameLength)).map { abs(channels[channel][$0]) }.max() ?? 0
            }.max() ?? 0
            tailPeak = max(tailPeak, peak)
            if chunk >= 20 { settledPeak = max(settledPeak, peak) }
            let held = try await assertSameClock(player, engine: subject)
            #expect(held.seconds == frozen.seconds)
            #expect(!player.isPlaying)
        }
        #expect(tailPeak > 0.01, "retain and observe the actual DSP tail")
        #expect(settledPeak < 0.000_001, "neutral DSP must settle to paused silence")
        player.togglePlayPause()
        _ = try await assertSameClock(player, engine: subject)
        var refillSilence = 0
        for _ in 0..<24 {
            refillSilence += try golden.compare(subject.renderOfflineForTesting(quantum),
                                                allowingIntentionalSilence: true)
            _ = try await assertSameClock(player, engine: subject)
        }
        #expect(golden.maximumSampleError < 0.000_01,
                "every audible tail/resume frame must match the next uninterrupted golden frame")
        #expect(refillSilence <= Int(ceil(paused.sourceProcessingLatency * sampleRate)) + 2 * Int(quantum),
                "resume silence must stay within the measured DSP pipeline bound")
        #expect(player.isPlaying)
        #expect(abs(player.progress - frozen.seconds - 24 * Double(quantum) / sampleRate) <= 2 / sampleRate,
                "paused IO frames must not become media time after resume")
        try ServiceClockEvidence.record([
            "name": "pausedDSPRendering", "pausedMediaSeconds": frozen.seconds,
            "pausedOutputFramesPerChannel": 24 * Int(quantum),
            "tailPeak": tailPeak, "settledPeak": settledPeak,
            "comparedSourceFrames": golden.comparedFrames, "maximumPCMError": golden.maximumSampleError,
            "intentionalSilenceFrames": golden.intentionalSilenceFrames,
            "refillSilenceFrames": refillSilence, "measuredProcessingLatencySeconds": paused.sourceProcessingLatency,
            "finalEngineSeconds": subject.position(of: .a), "finalServiceSeconds": player.progress,
            "finalLyricsSeconds": player.lyricsCursor.mediaTime,
        ])
    }

    @Test func thirtyRapidServiceTogglesPreservePCMAndEveryConsumer() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subject = try engine(url)
        let reference = try engine(url)
        defer { subject.stopAll(); reference.stopAll() }
        let player = try service(subject)
        for _ in 0..<8 { _ = try samples(subject); _ = try samples(reference) }
        let initial = try await assertSameClock(player, engine: subject)
        // No await between commands: the service and engine serial queues must
        // preserve issued order even before a preceding command executes.
        for _ in 0..<30 { player.togglePlayPause(); player.togglePlayPause() }
        let after = try await assertSameClock(player, engine: subject)
        #expect(player.isPlaying)
        #expect(abs(after.seconds - initial.seconds) <= 2 / sampleRate)
        var maximumError: Float = 0
        for _ in 0..<30 {
            maximumError = max(maximumError,
                zip(try samples(subject), try samples(reference)).map { abs($0 - $1) }.max() ?? .infinity)
            _ = try await assertSameClock(player, engine: subject)
        }
        #expect(maximumError < 0.000_01)
        #expect(after.timelineRevision >= initial.timelineRevision + 60)
        try ServiceClockEvidence.record([
            "name": "rapidServiceCommands", "cycles": 30, "commands": 60,
            "finalEngineSeconds": subject.position(of: .a), "finalServiceSeconds": player.progress,
            "finalLyricsSeconds": player.lyricsCursor.mediaTime,
            "comparedFramesPerChannel": 30 * Int(quantum), "maximumPCMError": maximumError,
        ])
        print("SERVICE_CLOCK rapidCycles=30 commands=60 pcmError=\(maximumError) engine=\(subject.position(of: .a)) service=\(player.progress) lyrics=\(player.lyricsCursor.mediaTime)")
    }

    @Test func seekAndScrubbingRetireOutstandingReadsOnTheSameTrack() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try engine(url)
        defer { engine.stopAll() }
        for _ in 0..<8 { _ = try samples(engine) }
        let player = try service(engine)
        // Split the SAME begin/read/accept sequence used by samplePlaybackTime.
        // Hold a real result at the exact acceptance boundary; no Task.yield or
        // scheduling luck decides whether the pre-seek sample is truly stale.
        let read = try #require(player.beginPlaybackTimeRead())
        let captured = await engine.positionAsync(of: read.deck)
        player.isScrubbing = true
        player.seek(to: 2)
        #expect(await player.samplePlaybackTime() == nil)
        #expect(player.acceptPlaybackTime(captured, for: read) == nil,
                "the captured pre-seek result must be rejected")
        #expect(player.progress == 2)
        #expect(player.lyricsCursor.mediaTime == 2)
        player.isScrubbing = false
        let current = try await assertSameClock(player, engine: engine)
        #expect(abs(current.seconds - 2) <= 2 / sampleRate)
        #expect(current.timelineRevision >= 3)
    }

    @Test func newerReadWinsEvenWhenAnOlderReadResumesLast() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try engine(url)
        defer { engine.stopAll() }
        for _ in 0..<8 { _ = try samples(engine) }
        let player = try service(engine)
        let olderRead = try #require(player.beginPlaybackTimeRead())
        let olderSeconds = await engine.positionAsync(of: olderRead.deck)
        for _ in 0..<4 { _ = try samples(engine) }
        _ = try await assertSameClock(player, engine: engine)
        // assertSameClock also exercises the word-timing reader, which accepts
        // another newer sample. Compare with the actual latest accepted read.
        let newer = try #require(player.latestPlaybackTimeSample)
        let accepted = try #require(player.acceptPlaybackTime(olderSeconds, for: olderRead))
        #expect(accepted == newer, "an older timer continuation publishes the newer accepted timestamp")
        #expect(player.latestPlaybackTimeSample == newer)
        #expect(player.progress == newer.seconds)
        #expect(player.lyricsCursor.mediaTime == newer.seconds)
    }

    @Test func sourceRenderCompletionPublishesTheEndpointWithoutAnotherTimerTick() async throws {
        let url = try fixture(duration: 0.3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try engine(url)
        defer { engine.stopAll() }
        let player = try service(engine)
        _ = try await player.samplePlaybackTime()
        for _ in 0..<40 {
            _ = try samples(engine)
            await Task.yield()
        }
        // Offline rendering uses the real node's dataRendered completion:
        // dataPlayedBack is defined only for a real audio device. Both take
        // the SAME engine event/service path; no synthetic EOF is injected.
        for _ in 0..<100 where player.isPlaying {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!player.isPlaying, "the engine must deliver its real source-render completion")
        #expect(player.progress == player.duration)
        #expect(player.lyricsCursor.mediaTime == player.duration)
        #expect(abs(player.duration - 0.3) <= 1 / sampleRate)
    }

    @Test func repeatOneRestartsTheSameProductionTimelineAndLyricCursor() async throws {
        let url = try fixture(duration: 0.3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try engine(url)
        defer { engine.stopAll() }
        let player = try service(engine)
        player.repeatMode = .one
        let original = engine.transportSnapshotForTesting(.a)
        var restarted = false
        for _ in 0..<120 {
            _ = try samples(engine)
            try await Task.sleep(for: .milliseconds(1))
            if engine.transportSnapshotForTesting(.a).generation > original.generation {
                restarted = true
                break
            }
        }
        #expect(restarted, "the real node completion must restart repeat-one")
        #expect(player.isPlaying)
        let sample = try await assertSameClock(player, engine: engine)
        #expect(sample.seconds < player.duration)
        #expect(player.lyricsCursor.mediaTime < player.duration)
        #expect(player.currentTrack?.id == 12345)
    }


    @Test func queuedAutoMixMidpointPreservesTheUsersLaterPause() async throws {
        let outgoing = try fixture(duration: 0.3)
        let incoming = try fixture(duration: 4)
        defer {
            try? FileManager.default.removeItem(at: outgoing.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: incoming.deletingLastPathComponent())
        }
        let subject = try engine(outgoing)
        defer { subject.stopAll() }
        _ = try subject.loadFile(at: incoming, on: .b)
        let first = try JSONDecoder().decode(Track.self, from: Data(
            #"{"id":12345,"name":"Outgoing","dt":300}"#.utf8))
        let next = try JSONDecoder().decode(Track.self, from: Data(
            #"{"id":54321,"name":"Incoming","dt":4000}"#.utf8))
        let player = PlayerService(playbackEngineForTesting: subject, track: first,
                                   lyrics: ParsedLyrics(lines: []),
                                   pendingTransitionTrackForTesting: next)
        subject.scheduleTransition(.plain(.gapless), from: .a, to: .b)
        // Keep the main actor occupied while the genuine source completion
        // queues its midpoint. Its event consumer cannot adopt metadata yet.
        for _ in 0..<80 {
            _ = try samples(subject)
            if !subject.hasPendingTransition { break }
        }
        #expect(!subject.hasPendingTransition, "the real render callback must finish the handover")
        #expect(player.currentTrack?.id == first.id)
        player.pause()
        for _ in 0..<100 where player.currentTrack?.id != next.id {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(player.currentTrack?.id == next.id, "consume the real queued midpoint")
        #expect(!player.isPlaying, "metadata adoption must not undo a newer pause intent")
        let held = subject.transportSnapshotForTesting(.b)
        #expect(held.paused && !held.nodePlaying)
        let frozen = try #require(await player.samplePlaybackTime())
        #expect(player.progress == frozen.seconds)
        #expect(player.lyricsCursor.mediaTime == frozen.seconds)
        player.togglePlayPause()
        _ = try await player.samplePlaybackTime()
        let resumed = subject.transportSnapshotForTesting(.b)
        #expect(player.isPlaying && resumed.nodePlaying && !resumed.paused)
        #expect(resumed.generation == held.generation, "resume the same incoming PCM schedule")
        #expect(player.currentTrack?.id == next.id)
    }

    @Test func completionDeliveredAfterPauseDoesNotAdvanceOrResumeADrainedNode() async throws {
        let url = try fixture(duration: 0.3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try engine(url)
        defer { engine.stopAll() }
        let player = try service(engine)
        player.repeatMode = .one
        let original = engine.transportSnapshotForTesting(.a)
        // Stay on this main-actor turn while output drains. The real completion
        // can enter the engine's stream, but its main-actor consumer cannot yet
        // run. Pause before yielding: this deterministically tests delivery of
        // a genuine completion after the user's pause intent.
        for _ in 0..<40 { _ = try samples(engine) }
        player.pause()
        for _ in 0..<100 where player.progress != player.duration {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!player.isPlaying, "a delayed end must not undo the user's pause or trigger repeat-one")
        #expect(player.progress == player.duration)
        #expect(player.lyricsCursor.mediaTime == player.duration)
        let drained = engine.transportSnapshotForTesting(.a)
        #expect(drained.generation == original.generation, "a paused user must not be automatically restarted")
        player.togglePlayPause()
        _ = try await player.samplePlaybackTime()
        let restarted = engine.transportSnapshotForTesting(.a)
        #expect(player.isPlaying)
        #expect(restarted.generation > drained.generation,
                "play after real drain follows the existing replay path, rather than resuming an exhausted source")
    }

}
