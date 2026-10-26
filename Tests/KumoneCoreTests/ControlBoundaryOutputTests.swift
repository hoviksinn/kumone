import AVFoundation
import AudioToolbox
import Foundation
import Testing
import KumoneObjC
@testable import KumoneCore

/// The standalone graph uses the SAME registered production AU in series.
/// It isolates output processing from Deck TimePitch/AutoMix timing; the
/// engine/service tests below independently retain the accepted media clock.
private final class DirectControlBoundaryGraph {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let effect: AVAudioUnitEffect?
    let format: AVAudioFormat
    let quantum: AVAudioFrameCount = 256

    init(rate: Double, processed: Bool, existingEffect: AVAudioUnitEffect? = nil) throws {
        format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        if processed {
            var error: NSError?
            effect = try #require(existingEffect ?? KumoneCreateControlBoundaryEffect(&error),
                                  "The actual registered custom AU must instantiate: \(String(describing: error))")
        } else { effect = nil }
        engine.attach(player)
        if let effect {
            var error: NSError?
            let prepared = KumonePrepareControlBoundaryRawCapture(effect, 131_072, &error)
            try #require(prepared, "Prepare actual raw instrumentation: \(String(describing: error))")
            engine.attach(effect)
            engine.connect(player, to: effect, format: format)
            engine.connect(effect, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = 1
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: quantum)
        engine.prepare()
        try engine.start()
    }

    func schedule(_ channels: [[Float]]) throws {
        try #require(channels.count == 2 && channels[0].count == channels[1].count)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in channels[channel].indices { data[channel][frame] = channels[channel][frame] }
        }
        player.scheduleBuffer(buffer)
        player.play()
    }

    func pull() throws -> PlaybackEngine.BoundaryRenderEvidence {
        let start = engine.manualRenderingSampleTime
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: quantum))
        let status = try engine.renderOffline(quantum, to: buffer)
        try #require(status == .success && buffer.frameLength == quantum)
        guard let effect else {
            return PlaybackEngine.BoundaryRenderEvidence(finalOutput: buffer, rawOutput: buffer,
                                                         renderStartSampleTime: start)
        }
        var error: NSError?
        let raw = try #require(KumoneCopyControlBoundaryRawOutput(effect, start, quantum, &error),
                               "Raw timestamps must match this real final pull: \(String(describing: error))")
        #expect(raw.frameLength == buffer.frameLength && raw.format == buffer.format)
        return PlaybackEngine.BoundaryRenderEvidence(finalOutput: buffer, rawOutput: raw,
                                                     renderStartSampleTime: start)
    }

    func snapshot() throws -> KumoneControlBoundarySnapshot {
        let unit = try #require(effect)
        var value = KumoneControlBoundarySnapshot()
        try #require(KumoneReadControlBoundarySnapshot(unit, &value))
        return value
    }

    deinit { engine.stop() }
}

@Suite("Inline output control boundary production regression", .serialized)
struct ControlBoundaryOutputTests {
    private let quantum: AVAudioFrameCount = 1024
    private let sourceClockRate = DeckChain.format.sampleRate

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QieTingInlineOutput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture(in directory: URL, rate: Double, amplitude: Float = 0.3,
                         duration: Double = 8, naturalRest: Range<Double>? = nil, chirp: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent("signal-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let count = AVAudioFrameCount(rate * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Int(count) {
                let t = Double(frame) / rate
                if naturalRest?.contains(t) == true {
                    samples[channel][frame] = 0
                } else if chirp {
                    samples[channel][frame] = amplitude * Float(
                        sin(2 * .pi * (173 * t + 61 * t * t) + Double(channel) * 0.3)
                        + 0.15 * sin(2 * .pi * (919 * t + 11 * t * t)))
                } else {
                    samples[channel][frame] = amplitude * Float(sin(2 * .pi * 211.3 * t + 0.71 + Double(channel) * 0.13))
                }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func engine(_ url: URL, sourceRate: Double, outputRate: Double,
                        bothDecks: Bool = false) throws -> PlaybackEngine {
        let engine = PlaybackEngine()
        try engine.enableBoundaryRawCaptureForTesting(capacityFrames: 262_144)
        try engine.enableOfflineRenderingForTesting(maximumFrameCount: quantum, outputSampleRate: outputRate)
        _ = try engine.loadFile(at: url, on: .a)
        engine.play(deck: .a, from: 0)
        if bothDecks {
            _ = try engine.loadFile(at: url, on: .b, trimDB: -6)
            engine.play(deck: .b, from: 0)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let a = engine.transportSnapshotForTesting(.a)
            let b = engine.transportSnapshotForTesting(.b)
            let sourceReady = sourceRate == sourceClockRate || a.queuedSourceBufferCount >= 8
            let secondReady = !bothDecks || (b.nodePlaying && (sourceRate == sourceClockRate || b.queuedSourceBufferCount >= 8))
            if a.nodePlaying && sourceReady && secondReady { return engine }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < deadline
        Issue.record("Actual production source feeder did not become ready")
        throw NSError(domain: "ControlBoundaryFixture", code: 1)
    }

    private func requireProcessor(_ engine: PlaybackEngine, outputRate: Double) throws -> PlaybackEngine.BoundarySnapshot {
        let value = engine.boundarySnapshotForTesting()
        try #require(value.available && value.prepared,
                     "A bypassed or unavailable output processor cannot pass its regression")
        #expect(value.inputSampleRate == outputRate && value.outputSampleRate == outputRate)
        #expect(value.channelCount == 2)
        #expect(value.delayFrames > 0 && value.envelopeFrames >= 2)
        #expect(value.silenceDetectionFloor == Double(Float(0.000_000_000_001)))
        #expect(!value.rawCaptureOverflow && !value.rawCaptureTimestampFault)
        return value
    }

    private func metadata(_ snapshot: PlaybackEngine.BoundarySnapshot) -> [String: Any] {
        ["inputRate": snapshot.inputSampleRate, "outputRate": snapshot.outputSampleRate,
         "delayFrames": snapshot.delayFrames, "delaySeconds": Double(snapshot.delayFrames) / snapshot.outputSampleRate,
         "envelopeFrames": snapshot.envelopeFrames, "resourceGeneration": snapshot.resourceGeneration,
         "modifiedOutputFrames": snapshot.modifiedOutputFrames, "rawCaptureOverflow": snapshot.rawCaptureOverflow,
         "rawCaptureTimestampFault": snapshot.rawCaptureTimestampFault,
         "controlBudgetFinalFrames": snapshot.controlBudgetFinalFrames, "controlBudgetSource": snapshot.controlBudgetSource,
         "hostResetRequests": snapshot.hostResetRequests, "appliedHostResetRequests": snapshot.appliedHostResetRequests]
    }

    @Test func registeredUnitProcessesBothEdgesInActualEngineOutput() throws {
        let graph = try DirectControlBoundaryGraph(rate: 44_100, processed: true)
        let unit = try #require(graph.effect)
        try graph.schedule([Array(repeating: 0.4, count: 32_768), Array(repeating: -0.23, count: 32_768)])
        var trace = ControlBoundaryPCMTrace()
        for index in 0..<32 {
            let pair = try graph.pull()
            if index == 31 { try trace.append(pair) }
        }
        let before = try graph.snapshot()
        try #require(before.available && before.prepared)
        try #require(KumoneArmControlBoundary(unit, 1, 4096))
        graph.player.pause()
        for _ in 0..<32 { try trace.append(graph.pull()) }
        try #require(KumoneArmControlBoundary(unit, 2, 4096))
        graph.player.play()
        for _ in 0..<32 { try trace.append(graph.pull()) }
        let after = try graph.snapshot()
        let result = try ControlBoundaryPCMOracle.analyze(trace, envelopeFrames: Int(after.envelopeFrames),
                                                        floor: Float(after.silenceDetectionFloor))
        #expect(result.entries.count == 1 && result.exits.count == 1)
        #expect(result.maximumDifference > 0.1 && result.modifiedFrames > 0)
        #expect(result.finalMaximumStep < result.rawMaximumStep * 0.1)
        #expect(after.resourceGeneration == before.resourceGeneration)
        #expect(after.hostResetRequests == before.hostResetRequests)
        #expect(after.appliedHostResetRequests == before.appliedHostResetRequests)
        #expect(after.transportCommands == before.transportCommands + 2)
        #expect(!after.rawCaptureOverflow && !after.rawCaptureTimestampFault)
        try ControlBoundaryEvidence.record(["name": "registered-inline-au-actual-engine-edges",
            "analysis": result.json, "reportedDelayFrames": after.delayFrames,
            "latencySeconds": unit.auAudioUnit.latency,
            "auClass": String(describing: type(of: unit.auAudioUnit))])
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func actualEngineImpulseMeasuresOutputLatencyAndRetainsTheDelayedTail(outputRate: Double) throws {
        let baseline = try DirectControlBoundaryGraph(rate: outputRate, processed: false)
        let processed = try DirectControlBoundaryGraph(rate: outputRate, processed: true)
        var input = Array(repeating: Array(repeating: Float(0), count: 8192), count: 2)
        input[0][512] = 0.4
        input[1][512] = -0.2
        // A second impulse at the final source frame exercises actual EOF
        // drainage; an early impulse alone cannot prove the delayed tail.
        input[0][8191] = 0.3
        input[1][8191] = -0.1
        try baseline.schedule(input)
        try processed.schedule(input)
        var expected = ControlBoundaryPCMTrace()
        var actual = ControlBoundaryPCMTrace()
        let prepared = try processed.snapshot()
        let pulls = (8192 + Int(prepared.delayFrames) + Int(processed.quantum) - 1) / Int(processed.quantum)
        for _ in 0..<pulls {
            try expected.append(baseline.pull())
            try actual.append(processed.pull())
        }
        let snapshot = try processed.snapshot()
        try #require(snapshot.available && snapshot.prepared)
        #expect(snapshot.inputSampleRate == outputRate && snapshot.outputSampleRate == outputRate)
        #expect(snapshot.envelopeFrames == UInt32(ceil(outputRate * 0.002)))
        #expect(snapshot.delayFrames == snapshot.envelopeFrames + 2)
        let unit = try #require(processed.effect)
        #expect(abs(unit.auAudioUnit.latency - Double(snapshot.delayFrames) / outputRate) < 1 / outputRate)
        let baselineImpulse = try #require(expected.final[0].firstIndex { abs($0) > 0.1 })
        let processedImpulse = try #require(actual.final[0].firstIndex { abs($0) > 0.1 })
        let observedEngineDelay = processedImpulse - baselineImpulse
        // The host may compensate declared AU latency. Record actual graph
        // behavior separately from the kernel's fixed FIFO declaration.
        #expect(observedEngineDelay >= 0 && observedEngineDelay <= Int(snapshot.delayFrames))
        let expectedTailFrame = 8191 + observedEngineDelay
        #expect(expectedTailFrame < actual.frames)
        #expect(abs(actual.final[0][expectedTailFrame] - 0.3) < 0.000_01,
                "The final source impulse must survive actual EOF and the AU's delayed drain")
        #expect(abs(actual.final[1][expectedTailFrame] + 0.1) < 0.000_01)
        #expect(actual.final.allSatisfy { $0.suffix(from: expectedTailFrame + 1).allSatisfy { abs($0) < 0.000_01 } })
        var rawFinalError: Float = 0
        for channel in 0..<2 {
            for frame in 0..<actual.frames {
                rawFinalError = max(rawFinalError, abs(actual.raw[channel][frame] - actual.final[channel][frame]))
            }
        }
        #expect(rawFinalError < 0.000_01)
        #expect(snapshot.modifiedOutputFrames == 0)
        #expect(!snapshot.rawCaptureOverflow && !snapshot.rawCaptureTimestampFault)
        #expect(abs(actual.final[0][processedImpulse] - 0.4) < 0.000_01,
                "Input-silence flags must not suppress the real delayed impulse")
        try ControlBoundaryEvidence.record(["name": "actual-engine-impulse", "outputRate": outputRate,
            "baselineImpulseFrame": baselineImpulse, "processedImpulseFrame": processedImpulse,
            "observedAdditionalEngineDelayFrames": observedEngineDelay,
            "actualFinalSourceImpulseFrame": expectedTailFrame, "renderedPastSourceEOFFrames": actual.frames - 8192,
            "kernelDeclaredDelayFrames": snapshot.delayFrames, "unarmedRawFinalError": rawFinalError,
            "scope": "Real AVAudioEngine output plus AU metadata; kernel exact frame delay is verified independently"])
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0], [44_100.0, 48_000.0, 96_000.0])
    func productionRateMatrixRetainsRawMediaAndSmoothsBothFinalEdges(sourceRate: Double, outputRate: Double) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for amplitude: Float in [0.08, 0.55] {
            let url = try fixture(in: directory, rate: sourceRate, amplitude: amplitude)
            let reference = try engine(url, sourceRate: sourceRate, outputRate: outputRate)
            let subject = try engine(url, sourceRate: sourceRate, outputRate: outputRate)
            defer { reference.stopAll(); subject.stopAll() }
            let golden = try TransportPCMReference(engine: reference, quantum: quantum, buffers: 160,
                                                  observation: .rawBeforeBoundaryEnvelope)
            var trace = ControlBoundaryPCMTrace()
            for index in 0..<32 {
                let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
                try golden.compare(pair.rawOutput)
                if index == 31 { try trace.append(pair) }
            }
            let initial = try requireProcessor(subject, outputRate: outputRate)
            subject.pause()
            let paused = subject.transportSnapshotForTesting(.a)
            #expect(paused.paused && paused.engineRunning && !paused.nodePlaying)
            for _ in 0..<24 {
                let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
                try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
                try trace.append(pair)
                #expect(subject.position(of: .a) == paused.position)
            }
            subject.resume()
            let resumed = subject.transportSnapshotForTesting(.a)
            #expect(resumed.generation == paused.generation && resumed.startOffset == paused.startOffset)
            #expect(abs(resumed.position - paused.position) <= 2 / sourceClockRate)
            var refillSilence = 0
            for _ in 0..<32 {
                let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
                refillSilence += try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
                try trace.append(pair)
            }
            let final = try requireProcessor(subject, outputRate: outputRate)
            let analysis = try ControlBoundaryPCMOracle.analyze(trace, envelopeFrames: Int(final.envelopeFrames),
                                                              floor: Float(final.silenceDetectionFloor))
            #expect(analysis.entries.count == 1 && analysis.exits.count == 1)
            #expect(analysis.modifiedFrames > 0 && analysis.maximumDifference > amplitude * 0.01)
            #expect(analysis.finalMaximumStep <= analysis.rawMaximumStep + 0.000_01)
            #expect(golden.maximumSampleError < 0.000_01 && golden.maximumSignal > amplitude * 0.4)
            #expect(final.controlBudgetFinalFrames > 0)
            #expect(refillSilence <= Int(final.controlBudgetFinalFrames) + Int(final.delayFrames))
            #expect(final.resourceGeneration == initial.resourceGeneration && final.hostResetRequests == initial.hostResetRequests)
            #expect(final.appliedHostResetRequests == initial.appliedHostResetRequests)
            try ControlBoundaryEvidence.record(["name": "production-rate-matrix", "sourceRate": sourceRate,
                "sourceAmplitude": amplitude, "processor": metadata(final), "analysis": analysis.json,
                "rawContentMaximumError": golden.maximumSampleError, "comparedRawFrames": golden.comparedFrames,
                "resumeRefillSilenceFrames": refillSilence, "pausedMediaSeconds": paused.position,
                "resumedMediaSeconds": resumed.position])
        }
    }

    @Test(arguments: [0.1, 1.0, 5.0, 10.0])
    func longRenderedPausesDoNotConsumeSourceFramesOrResetTheProcessor(seconds: Double) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory, rate: sourceClockRate, chirp: true)
        let reference = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        let subject = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        defer { reference.stopAll(); subject.stopAll() }
        let golden = try TransportPCMReference(engine: reference, quantum: quantum, buffers: 160,
                                              observation: .rawBeforeBoundaryEnvelope)
        var trace = ControlBoundaryPCMTrace()
        for index in 0..<16 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput)
            if index == 15 { try trace.append(pair) }
        }
        let initial = try requireProcessor(subject, outputRate: sourceClockRate)
        subject.pause()
        let frozen = subject.transportSnapshotForTesting(.a)
        var remaining = AVAudioFramePosition(ceil(seconds * sourceClockRate))
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(quantum)))
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(count)
            try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
            #expect(subject.position(of: .a) == frozen.position)
            remaining -= AVAudioFramePosition(count)
        }
        subject.resume()
        let resumed = subject.transportSnapshotForTesting(.a)
        #expect(resumed.generation == frozen.generation && resumed.startOffset == frozen.startOffset)
        #expect(abs(resumed.position - frozen.position) <= 2 / sourceClockRate)
        var resumeRefillSilenceFrames = 0
        for _ in 0..<24 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            resumeRefillSilenceFrames += try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
        }
        let final = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(resumeRefillSilenceFrames <= Int(final.controlBudgetFinalFrames) + Int(final.delayFrames),
                "Actual native-start recovery must not hide excess silence in the strict media oracle")
        let analysis = try ControlBoundaryPCMOracle.analyze(trace, envelopeFrames: Int(final.envelopeFrames),
                                                          floor: Float(final.silenceDetectionFloor))
        #expect(analysis.entries.count == 1 && analysis.exits.count == 1)
        #expect(analysis.modifiedFrames > 0)
        #expect(golden.maximumSampleError < 0.000_01 && golden.maximumSignal > 0.1)
        #expect(final.resourceGeneration == initial.resourceGeneration && final.hostResetRequests == initial.hostResetRequests)
        #expect(final.appliedHostResetRequests == initial.appliedHostResetRequests)
        try ControlBoundaryEvidence.record(["name": "rendered-long-pause", "pauseOutputSeconds": seconds, "resumeRefillSilenceFrames": resumeRefillSilenceFrames,
            "rawContentMaximumError": golden.maximumSampleError, "comparedRawFrames": golden.comparedFrames,
            "analysis": analysis.json, "processor": metadata(final), "frozenMediaSeconds": frozen.position])
    }

    @Test func thirtyRenderedPauseCyclesPreserveEveryRawFrameAndControlOrder() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory, rate: sourceClockRate, duration: 16, chirp: true)
        let reference = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        let subject = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        defer { reference.stopAll(); subject.stopAll() }
        subject.enableTransportCommandTraceForTesting(maximumRecords: 128)
        let golden = try TransportPCMReference(engine: reference, quantum: quantum, buffers: 600,
                                              observation: .rawBeforeBoundaryEnvelope)
        for _ in 0..<16 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput)
        }
        let initial = try requireProcessor(subject, outputRate: sourceClockRate)
        var confirmedEntries = 0
        var confirmedExits = 0
        var maximumEnvelopeError: Float = 0
        for cycle in 0..<30 {
            var trace = ControlBoundaryPCMTrace()
            let lead = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(lead.rawOutput)
            try trace.append(lead)
            subject.pause()
            let frozen = subject.transportSnapshotForTesting(.a)
            #expect(frozen.paused && !frozen.nodePlaying)
            // Some controls finish before DSP reaches silence; they must not
            // manufacture a fade or a synthetic source discontinuity.
            let pausedBuffers = [1, 4, 12][cycle % 3]
            for _ in 0..<pausedBuffers {
                let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
                try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
                try trace.append(pair)
                #expect(subject.position(of: .a) == frozen.position)
            }
            subject.resume()
            let resumed = subject.transportSnapshotForTesting(.a)
            #expect(resumed.generation == frozen.generation && resumed.startOffset == frozen.startOffset)
            #expect(abs(resumed.position - frozen.position) <= 2 / sourceClockRate)
            for _ in 0..<8 {
                let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
                try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
                try trace.append(pair)
            }
            let current = try requireProcessor(subject, outputRate: sourceClockRate)
            let analysis = try ControlBoundaryPCMOracle.analyze(trace, envelopeFrames: Int(current.envelopeFrames),
                                                              floor: Float(current.silenceDetectionFloor))
            confirmedEntries += analysis.entries.count
            confirmedExits += analysis.exits.count
            maximumEnvelopeError = max(maximumEnvelopeError, analysis.envelopeError)
        }
        let records = subject.transportCommandTraceForTesting()
        #expect(records.count == 60 && records.allSatisfy(\.accepted))
        #expect(records.enumerated().allSatisfy { $0.element.command == ($0.offset.isMultiple(of: 2) ? "pause" : "resume") })
        #expect(confirmedEntries > 0 && confirmedEntries == confirmedExits)
        #expect(maximumEnvelopeError < 0.000_01)
        #expect(golden.maximumSampleError < 0.000_01 && golden.maximumSignal > 0.1)
        let final = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(final.resourceGeneration == initial.resourceGeneration && final.hostResetRequests == initial.hostResetRequests)
        #expect(final.appliedHostResetRequests == initial.appliedHostResetRequests)
        try ControlBoundaryEvidence.record(["name": "thirty-rendered-control-cycles", "executedCommands": records.count,
            "actualSilenceEntries": confirmedEntries, "actualSilenceExits": confirmedExits,
            "rawContentMaximumError": golden.maximumSampleError, "comparedRawFrames": golden.comparedFrames,
            "independentEnvelopeError": maximumEnvelopeError, "processor": metadata(final)])
    }

    @Test func unarmedNaturalRestsAndANoRenderCommandBurstDoNotAlterQuietMusic() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory, rate: sourceClockRate, amplitude: 0.000_01, naturalRest: 1.5..<1.8)
        let subject = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        defer { subject.stopAll() }
        var maximumDifference: Float = 0
        for _ in 0..<16 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let before = try #require(pair.rawOutput.floatChannelData)
            let after = try #require(pair.finalOutput.floatChannelData)
            for c in 0..<2 { for i in 0..<Int(pair.finalOutput.frameLength) { maximumDifference = max(maximumDifference, abs(before[c][i] - after[c][i])) } }
        }
        // No IO exists between these actual accepted commands. The processor
        // may retire its bounded recent-running gate; it must not taper the
        // unrelated encoded rest more than a second later.
        for _ in 0..<30 { subject.pause(); subject.resume() }
        for _ in 0..<100 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let before = try #require(pair.rawOutput.floatChannelData)
            let after = try #require(pair.finalOutput.floatChannelData)
            for c in 0..<2 { for i in 0..<Int(pair.finalOutput.frameLength) { maximumDifference = max(maximumDifference, abs(before[c][i] - after[c][i])) } }
        }
        let snapshot = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(maximumDifference == 0, "Unarmed/retired gates must preserve even quiet high-resolution content exactly")
        #expect(snapshot.modifiedOutputFrames == 0)
        try ControlBoundaryEvidence.record(["name": "unarmed-quiet-rest-and-no-io-burst",
            "maximumRawFinalDifference": maximumDifference, "processor": metadata(snapshot)])
    }

    @Test func aResumeInsideAnEncodedLongRestDoesNotTaperTheNextNaturalNote() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The natural rest is substantially longer than the REAL negotiated
        // resume budget. No fake frame receipt or precomputed mix is used.
        let rest = 1.0..<4.0
        let url = try fixture(in: directory, rate: sourceClockRate, amplitude: 0.35,
                              duration: 6, naturalRest: rest)
        let subject = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        defer { subject.stopAll() }
        var difference: Float = 0
        var consecutiveSilentBlocks = 0
        var observedRest = false
        for _ in 0..<160 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let raw = try #require(pair.rawOutput.floatChannelData)
            let final = try #require(pair.finalOutput.floatChannelData)
            var peak: Float = 0
            for channel in 0..<2 { for frame in 0..<Int(pair.finalOutput.frameLength) {
                peak = max(peak, abs(raw[channel][frame]))
                difference = max(difference, abs(raw[channel][frame] - final[channel][frame]))
            } }
            let position = subject.position(of: .a)
            if rest.contains(position) && peak <= 0.000_000_000_001 { consecutiveSilentBlocks += 1 }
            else { consecutiveSilentBlocks = 0 }
            if consecutiveSilentBlocks == 2 { observedRest = true; break }
        }
        try #require(observedRest, "The real production DSP output must be inside the encoded rest before issuing controls")
        let initial = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(initial.modifiedOutputFrames == 0)
        subject.pause()
        let frozen = subject.transportSnapshotForTesting(.a)
        #expect(rest.contains(frozen.position))
        for _ in 0..<8 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let raw = try #require(pair.rawOutput.floatChannelData)
            let final = try #require(pair.finalOutput.floatChannelData)
            for channel in 0..<2 { for frame in 0..<Int(pair.finalOutput.frameLength) {
                difference = max(difference, abs(raw[channel][frame] - final[channel][frame]))
            } }
            #expect(subject.position(of: .a) == frozen.position)
        }
        subject.resume()
        let resumed = subject.transportSnapshotForTesting(.a)
        #expect(resumed.generation == frozen.generation && resumed.startOffset == frozen.startOffset)
        #expect(abs(resumed.position - frozen.position) <= 2 / sourceClockRate)
        var outputSinceResume = 0
        var firstNaturalNoteAt: Int?
        var notePeak: Float = 0
        for _ in 0..<240 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let raw = try #require(pair.rawOutput.floatChannelData)
            let final = try #require(pair.finalOutput.floatChannelData)
            for frame in 0..<Int(pair.finalOutput.frameLength) {
                var peak: Float = 0
                for channel in 0..<2 {
                    peak = max(peak, abs(raw[channel][frame]))
                    difference = max(difference, abs(raw[channel][frame] - final[channel][frame]))
                }
                if firstNaturalNoteAt == nil && peak > 0.000_000_000_001 {
                    firstNaturalNoteAt = outputSinceResume + frame
                }
                notePeak = max(notePeak, peak)
            }
            outputSinceResume += Int(pair.finalOutput.frameLength)
            if notePeak > 0.1 { break }
        }
        let noteFrame = try #require(firstNaturalNoteAt,
                                    "The actual final output must reach the next encoded musical note")
        let final = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(final.controlBudgetFinalFrames > 0)
        #expect(noteFrame > Int(final.controlBudgetFinalFrames) + Int(final.delayFrames),
                "The fixture must exercise retirement of the real native-resume budget")
        #expect(notePeak > 0.1)
        #expect(difference == 0, "A transport gate must not taper a natural note outside its finite refill budget")
        #expect(final.modifiedOutputFrames == 0)
        #expect(final.resourceGeneration == initial.resourceGeneration && final.hostResetRequests == initial.hostResetRequests)
        #expect(final.appliedHostResetRequests == initial.appliedHostResetRequests)
        try ControlBoundaryEvidence.record(["name": "resume-inside-long-encoded-rest",
            "firstNaturalNoteAfterResumeFrames": noteFrame, "outputFramesAfterResume": outputSinceResume,
            "maximumRawFinalDifference": difference, "naturalNotePeak": notePeak,
            "frozenMediaSeconds": frozen.position, "processor": metadata(final),
            "scope": "Actual PlaybackEngine output; not a substitute for separate raw FIFO tests of non-silent source continuity"])
    }

    @Test func twoDeckOutputMixKeepsBothSourceClocksAndTheSameRawFrameOrder() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(in: directory, rate: sourceClockRate, amplitude: 0.18, duration: 8, chirp: true)
        let reference = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate, bothDecks: true)
        let subject = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate, bothDecks: true)
        defer { reference.stopAll(); subject.stopAll() }
        let golden = try TransportPCMReference(engine: reference, quantum: quantum, buffers: 160,
                                              observation: .rawBeforeBoundaryEnvelope)
        var trace = ControlBoundaryPCMTrace()
        for index in 0..<16 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput)
            if index == 15 { try trace.append(pair) }
        }
        subject.pause()
        let a = subject.transportSnapshotForTesting(.a)
        let b = subject.transportSnapshotForTesting(.b)
        #expect(!a.nodePlaying && !b.nodePlaying && a.paused && b.paused)
        for _ in 0..<24 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
            #expect(subject.position(of: .a) == a.position && subject.position(of: .b) == b.position)
        }
        subject.resume()
        #expect(subject.transportSnapshotForTesting(.a).generation == a.generation)
        #expect(subject.transportSnapshotForTesting(.b).generation == b.generation)
        var resumeRefillSilenceFrames = 0
        for _ in 0..<32 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            resumeRefillSilenceFrames += try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
        }
        let snapshot = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(resumeRefillSilenceFrames <= Int(snapshot.controlBudgetFinalFrames) + Int(snapshot.delayFrames),
                "Actual native-start recovery must not hide excess silence in the strict media oracle")
        let analysis = try ControlBoundaryPCMOracle.analyze(trace, envelopeFrames: Int(snapshot.envelopeFrames),
                                                          floor: Float(snapshot.silenceDetectionFloor))
        #expect(analysis.entries.count == 1 && analysis.exits.count == 1)
        #expect(analysis.modifiedFrames > 0 && golden.maximumSampleError < 0.000_01 && golden.maximumSignal > 0.1)
        try ControlBoundaryEvidence.record(["name": "two-deck-production-output", "resumeRefillSilenceFrames": resumeRefillSilenceFrames, "analysis": analysis.json,
            "rawContentMaximumError": golden.maximumSampleError, "processor": metadata(snapshot),
            "scope": "Actual two-deck mix; existing live gapless/segment/EOF tests remain independent"])
    }

    @Test func rawCaptureRejectsMissingOutputTimestampsInsteadOfFabricatingSilence() throws {
        let graph = try DirectControlBoundaryGraph(rate: 48_000, processed: true)
        let unit = try #require(graph.effect)
        try graph.schedule([Array(repeating: 0.2, count: 8192), Array(repeating: -0.17, count: 8192)])
        _ = try graph.pull()
        let before = try graph.snapshot()
        var missingError: NSError?
        let missing = KumoneCopyControlBoundaryRawOutput(unit, 1_000_000, graph.quantum, &missingError)
        #expect(missing == nil && missingError != nil)
        let next = try graph.pull()
        #expect(next.finalOutput.frameLength == graph.quantum && next.rawOutput.frameLength == graph.quantum)
        let after = try graph.snapshot()
        #expect(after.resourceGeneration == before.resourceGeneration)
        #expect(after.hostResetRequests == before.hostResetRequests)
        #expect(after.appliedHostResetRequests == before.appliedHostResetRequests)
        try ControlBoundaryEvidence.record(["name": "raw-capture-missing-timestamp-rejected",
            "missingTimestampError": missingError?.localizedDescription ?? "none",
            "nextActualRenderStart": next.renderStartSampleTime,
            "scope": "Invalid test observation fails explicitly; no fabricated zero or extra engine render"])
    }

    @Test func explicitResetAndStoppedReprepareRejectOldRawEpochs() throws {
        let first = try DirectControlBoundaryGraph(rate: 44_100, processed: true)
        let unit = try #require(first.effect)
        try first.schedule([Array(repeating: 0.3, count: 8192), Array(repeating: -0.2, count: 8192)])
        let old = try first.pull()
        let before = try first.snapshot()

        // Explicit host reset is intentional here. Ordinary transport tests
        // separately require this counter and FIFO epoch to remain unchanged.
        unit.auAudioUnit.reset()
        let pending = try first.snapshot()
        #expect(pending.hostResetRequests == before.hostResetRequests + 1)
        var error: NSError?
        #expect(KumoneCopyControlBoundaryRawOutput(unit, old.renderStartSampleTime, first.quantum, &error) == nil)
        #expect(error != nil, "A pending reset must reject stale observations")
        let new = try first.pull()
        let applied = try first.snapshot()
        #expect(applied.resourceGeneration == before.resourceGeneration + 1)
        #expect(applied.appliedHostResetRequests == pending.hostResetRequests)
        error = nil
        #expect(KumoneCopyControlBoundaryRawOutput(unit, old.renderStartSampleTime, first.quantum, &error) == nil)
        #expect(error != nil, "A completed reset must also reject previous-epoch samples")
        #expect(new.renderStartSampleTime > old.renderStartSampleTime)

        first.engine.stop()
        first.player.stop()
        first.engine.disconnectNodeOutput(first.player)
        first.engine.disconnectNodeOutput(unit)
        first.engine.detach(unit)
        // No rendering or engine owns this detached AU's render resources.
        if unit.auAudioUnit.renderResourcesAllocated { unit.auAudioUnit.deallocateRenderResources() }
        let detached = try first.snapshot()
        #expect(!detached.prepared)
        let rebuilt = try DirectControlBoundaryGraph(rate: 96_000, processed: true, existingEffect: unit)
        let allocated = try rebuilt.snapshot()
        #expect(allocated.prepared && allocated.resourceGeneration > applied.resourceGeneration)
        #expect(allocated.inputSampleRate == 96_000 && allocated.outputSampleRate == 96_000)
        #expect(allocated.envelopeFrames == 192 && allocated.delayFrames == 194)
        #expect(abs(unit.auAudioUnit.latency - Double(allocated.delayFrames) / 96_000) < 1.0 / 96_000)
        error = nil
        #expect(KumoneCopyControlBoundaryRawOutput(unit, old.renderStartSampleTime, rebuilt.quantum, &error) == nil)
        #expect(error != nil, "Fresh allocation cannot return a previous stream's raw data")
        var impulse = Array(repeating: Array(repeating: Float(0), count: 8192), count: 2)
        impulse[0][512] = 0.4
        impulse[1][512] = -0.2
        try rebuilt.schedule(impulse)
        var trace = ControlBoundaryPCMTrace()
        for _ in 0..<16 { try trace.append(rebuilt.pull()) }
        let nonzero = try #require(trace.final[0].firstIndex { abs($0) > 0.1 })
        #expect(abs(trace.final[0][nonzero] - 0.4) < 0.000_01)
        for channel in 0..<2 {
            #expect(zip(trace.raw[channel], trace.final[channel]).allSatisfy { abs($0.0 - $0.1) < 0.000_01 })
        }
        try ControlBoundaryEvidence.record(["name": "explicit-reset-and-stopped-reprepare",
            "oldEpoch": before.resourceGeneration, "resetEpoch": applied.resourceGeneration,
            "rebuiltEpoch": allocated.resourceGeneration, "rebuiltOutputRate": allocated.outputSampleRate,
            "rebuiltDelayFrames": allocated.delayFrames, "actualImpulseFrame": nonzero,
            "scope": "Explicit reset/reallocation only; never an allowed pause/resume operation"])
    }

    @Test func aLateNativeReadyRetryRearmsTheRealFinalOutputWithoutChangingTheAnchor() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try fixture(in: folder, rate: sourceClockRate, duration: 8, chirp: true)
        let reference = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        let subject = try engine(url, sourceRate: sourceClockRate, outputRate: sourceClockRate)
        defer { reference.stopAll(); subject.stopAll() }
        let golden = try TransportPCMReference(engine: reference, quantum: quantum, buffers: 160,
                                              observation: .rawBeforeBoundaryEnvelope)
        var trace = ControlBoundaryPCMTrace()
        for index in 0..<16 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput)
            if index == 15 { try trace.append(pair) }
        }
        let initial = try requireProcessor(subject, outputRate: sourceClockRate)
        subject.pause()
        let frozen = subject.transportSnapshotForTesting(.a)
        for _ in 0..<24 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
        }
        try subject.setTransportResumeReadinessHeldForTesting(true, on: .a)
        subject.resume()
        let early = try requireProcessor(subject, outputRate: sourceClockRate)
        try #require(early.controlBudgetFinalFrames > 0)
        // Advance real output beyond the entry budget while the original
        // native-readiness retry branch withholds the player's real start.
        var drained = 0
        while drained <= Int(early.controlBudgetFinalFrames) + Int(early.delayFrames) {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
            drained += Int(pair.finalOutput.frameLength)
            let held = subject.transportSnapshotForTesting(.a)
            #expect(!held.nodePlaying && held.generation == frozen.generation)
            #expect(abs(held.position - frozen.position) <= 2 / sourceClockRate)
        }
        try subject.setTransportResumeReadinessHeldForTesting(false, on: .a)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !subject.transportSnapshotForTesting(.a).nodePlaying && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try #require(subject.transportSnapshotForTesting(.a).nodePlaying,
                     "Only the existing scheduled retry may invoke the actual native start")
        let resumed = subject.transportSnapshotForTesting(.a)
        #expect(resumed.generation == frozen.generation && resumed.startOffset == frozen.startOffset)
        #expect(abs(resumed.position - frozen.position) <= 2 / sourceClockRate)
        var resumeRefillSilenceFrames = 0
        for _ in 0..<24 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            resumeRefillSilenceFrames += try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try trace.append(pair)
        }
        let final = try requireProcessor(subject, outputRate: sourceClockRate)
        #expect(resumeRefillSilenceFrames <= Int(final.controlBudgetFinalFrames) + Int(final.delayFrames),
                "Actual native-start recovery must not hide excess silence in the strict media oracle")
        let analysis = try ControlBoundaryPCMOracle.analyze(trace, envelopeFrames: Int(final.envelopeFrames),
                                                          floor: Float(final.silenceDetectionFloor))
        #expect(analysis.entries.count == 1 && analysis.exits.count == 1)
        #expect(analysis.modifiedFrames > 0 && golden.maximumSampleError < 0.000_01)
        #expect(final.transportCommands > early.transportCommands,
                "A late real start needs a fresh processor announcement; UI command count is separate")
        #expect(final.resourceGeneration == initial.resourceGeneration && final.hostResetRequests == initial.hostResetRequests)
        #expect(final.appliedHostResetRequests == initial.appliedHostResetRequests)
        try ControlBoundaryEvidence.record(["name": "late-native-ready-resume", "resumeRefillSilenceFrames": resumeRefillSilenceFrames,
            "realOutputFramesBeforeNativeStart": drained, "initialGateFrames": early.controlBudgetFinalFrames,
            "rawContentMaximumError": golden.maximumSampleError, "analysis": analysis.json,
            "processor": metadata(final),
            "scope": "Actual engine and existing retry; offline test seam withholds readiness, not a physical-route timing proof"])
    }
}
