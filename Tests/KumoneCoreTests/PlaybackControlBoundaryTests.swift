import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

/// Actual production output evidence, with a separate strict pre-envelope PCM layer.
/// Every value is measured after the real deck DSP, master limiter and volume.
/// The fixtures are original synthetic PCM; no music or account data is saved.
private enum PlaybackBoundaryEvidence {
    static let lock = NSLock()
    static var cases: [[String: Any]] = []

    static func record(_ measurements: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        cases.append(measurements)
        let report: [String: Any] = [
            "scope": "Actual inline processed final production output plus strict raw-media oracle; no physical DAC/listening claim",
            "outputSampleRate": DeckChain.format.sampleRate,
            "interpretation": "A large adjacent-sample delta is waveform evidence, not by itself proof of the reported audible click. Compare the steady control and source position checks.",
            "cases": cases,
        ]
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".build/playback-boundary-diagnostic.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        var summary = measurements
        for name in ["steady", "pause", "resume", "replacement"] {
            guard var stage = summary[name] as? [String: Any] else { continue }
            stage.removeValue(forKey: "maximumDeltaContext")
            summary[name] = stage
        }
        print("PLAYBACK_BOUNDARY \(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)")
    }
}

@Suite("Playback control output boundaries", .serialized)
struct PlaybackControlBoundaryTests {
    private let quantum: AVAudioFrameCount = 1024
    private let sampleRate = DeckChain.format.sampleRate

    /// The two channels have distinct phases so a legitimate zero crossing is
    /// not mistaken for intentionally paused digital silence by the PCM FIFO.
    private func fixture(sampleRate: Double, amplitude: Float, phase: Double,
                         in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let count = AVAudioFrameCount(sampleRate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Int(count) {
                let time = Double(frame) / sampleRate
                data[channel][frame] = amplitude * Float(sin(2 * .pi * 211.3 * time + phase + Double(channel) * 0.13))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QieTingBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Wait for actual converted buffers, never for a guessed decoder delay.
    /// Offline IO can otherwise outrun the asynchronous file feeder, producing
    /// diagnostic starvation unrelated to a physical playback control edge.
    private func waitForPreparedSource(_ engine: PlaybackEngine, sourceRate: Double) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let state = engine.transportSnapshotForTesting(.a)
            if state.nodePlaying && (sourceRate == sampleRate || state.queuedSourceBufferCount >= 8) { return }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < deadline
        let state = engine.transportSnapshotForTesting(.a)
        #expect(state.nodePlaying && (sourceRate == sampleRate || state.queuedSourceBufferCount >= 8),
                "prepare actual source buffers before measuring offline control boundaries")
        try #require(state.nodePlaying)
        if sourceRate != sampleRate { try #require(state.queuedSourceBufferCount >= 8) }
    }

    private func engine(_ url: URL, sourceRate: Double, boundaryRawCapture: Bool = false) throws -> PlaybackEngine {
        let result = PlaybackEngine()
        if boundaryRawCapture {
            try result.enableBoundaryRawCaptureForTesting(capacityFrames: 262_144)
        }
        try result.enableOfflineRenderingForTesting(maximumFrameCount: quantum)
        _ = try result.loadFile(at: url, on: .a)
        result.play(deck: .a, from: 0)
        try waitForPreparedSource(result, sourceRate: sourceRate)
        return result
    }

    private func append(_ buffer: AVAudioPCMBuffer, to channels: inout [[Float]]) throws {
        let data = try #require(buffer.floatChannelData)
        #expect(buffer.frameLength == quantum)
        for channel in channels.indices {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
        }
    }

    /// Report the strongest adjacent-sample jump, its exact context, and the
    /// two digital-silence boundaries. Never seek/search to align PCM; the
    /// independent golden FIFO below consumes every source frame in order.
    private func metrics(_ channels: [[Float]]) -> [String: Any] {
        var peak: Float = 0
        var maximumStep: Float = 0
        var maximumChannel = 0
        var maximumFrame = 0
        var silenceEntries: [[String: Any]] = []
        var silenceExits: [[String: Any]] = []
        var nonfinite = 0
        let frames = channels.first?.count ?? 0
        for channel in channels.indices {
            for frame in 0..<frames {
                let value = channels[channel][frame]
                if !value.isFinite { nonfinite += 1; continue }
                peak = max(peak, abs(value))
                guard frame > 0 else { continue }
                let previous = channels[channel][frame - 1]
                let delta = abs(value - previous)
                if delta > maximumStep {
                    maximumStep = delta
                    maximumChannel = channel
                    maximumFrame = frame
                }
            }
        }
        if frames > 1 {
            for frame in 1..<frames {
                let silentBefore = channels.allSatisfy { abs($0[frame - 1]) < 0.000_000_01 }
                let silentAfter = channels.allSatisfy { abs($0[frame]) < 0.000_000_01 }
                let delta = channels.map { abs($0[frame] - $0[frame - 1]) }.max() ?? 0
                if !silentBefore && silentAfter { silenceEntries.append(["frame": frame, "delta": delta]) }
                if silentBefore && !silentAfter { silenceExits.append(["frame": frame, "delta": delta]) }
            }
        }
        // A small, original synthetic PCM window supports a later, independent
        // waveform/DSP experiment without exporting any real music.
        let contextStart = max(0, maximumFrame - 512)
        let contextEnd = min(frames, maximumFrame + 513)
        return [
            "framesPerChannel": frames, "channelCount": channels.count,
            "peak": peak, "maximumAdjacentDelta": maximumStep,
            "maximumDeltaChannel": maximumChannel, "maximumDeltaFrame": maximumFrame,
            "maximumDeltaContextStart": contextStart,
            "maximumDeltaContext": channels.map { Array($0[contextStart..<contextEnd]) },
            "silenceEntries": silenceEntries, "silenceExits": silenceExits,
            "nonfiniteSamples": nonfinite,
        ]
    }

    @Test(arguments: [44_100.0, 96_000.0], [Float(0.08), Float(0.55)])
    func pauseAndResumeMeasureActualOutputWithoutChangingItsPCM(sourceRate: Double, amplitude: Float) throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try fixture(sampleRate: sourceRate, amplitude: amplitude, phase: 0.71,
                              in: folder, name: "original-synthetic-tone")
        let reference = try engine(url, sourceRate: sourceRate, boundaryRawCapture: true)
        let subject = try engine(url, sourceRate: sourceRate, boundaryRawCapture: true)
        defer { reference.stopAll(); subject.stopAll() }
        let golden = try TransportPCMReference(engine: reference, quantum: quantum, buffers: 100, observation: .rawBeforeBoundaryEnvelope)
        var boundaryTrace = ControlBoundaryPCMTrace()
        var steady = Array(repeating: [Float](), count: 2)
        for index in 0..<32 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let output = pair.finalOutput
            try golden.compare(pair.rawOutput)
            if index >= 28 { try append(output, to: &steady) }
            if index == 31 { try boundaryTrace.append(pair) }
        }
        let before = subject.transportSnapshotForTesting(.a)
        subject.pause()
        let frozen = subject.transportSnapshotForTesting(.a)
        #expect(frozen.paused && !frozen.nodePlaying && frozen.engineRunning)
        #expect(abs(frozen.position - before.position) <= 2 / sampleRate)
        var pause = steady.map { Array($0.suffix(Int(quantum))) }
        for _ in 0..<24 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let output = pair.finalOutput
            try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try boundaryTrace.append(pair)
            try append(output, to: &pause)
            #expect(subject.position(of: .a) == frozen.position)
        }
        let pausedTail = pause.map { Array($0.suffix(Int(quantum))) }
        #expect(pausedTail.flatMap { $0 }.allSatisfy { abs($0) < 0.000_001 })
        subject.resume()
        let resumed = subject.transportSnapshotForTesting(.a)
        #expect(resumed.generation == before.generation)
        #expect(!resumed.paused && resumed.nodePlaying)
        #expect(abs(resumed.position - frozen.position) <= 2 / sampleRate)
        var resume = pausedTail
        var resumeRefillSilenceFrames = 0
        for _ in 0..<32 {
            let pair = try subject.renderOfflineBoundaryEvidenceForTesting(quantum)
            let output = pair.finalOutput
            resumeRefillSilenceFrames += try golden.compare(pair.rawOutput, allowingIntentionalSilence: true)
            try boundaryTrace.append(pair)
            try append(output, to: &resume)
        }
        #expect((resume.flatMap { $0 }.map(abs).max() ?? 0) > amplitude * 0.4,
                "recovery must produce actual audio; pre-pause sound cannot validate resume")
        #expect(subject.position(of: .a) > frozen.position)
        let sourceLead = try #require(frozen.actualSourceRenderLeadFrames)
        let refillBound = max(Int(ceil(frozen.sourceProcessingLatency * sampleRate)), Int(sourceLead))
            + 2 * Int(quantum)
        #expect(resumeRefillSilenceFrames <= refillBound,
                "resume silence must remain inside the measured production pipeline bound")
        #expect(golden.maximumSignal > amplitude * 0.4, "silence cannot validate a boundary measurement")
        #expect(golden.maximumSampleError < 0.000_01,
                "diagnostic observation must retain every audible PCM frame with the original strict tolerance")
        let allMeasuredSamplesAreFinite = (steady + pause + resume).flatMap { $0 }.allSatisfy { $0.isFinite }
        #expect(allMeasuredSamplesAreFinite)
        let processor = subject.boundarySnapshotForTesting()
        #expect(processor.available && processor.prepared && !processor.rawCaptureOverflow && !processor.rawCaptureTimestampFault)
        let finalAnalysis = try ControlBoundaryPCMOracle.analyze(boundaryTrace,
            envelopeFrames: Int(processor.envelopeFrames), floor: Float(processor.silenceDetectionFloor))
        #expect(finalAnalysis.entries.count == 1 && finalAnalysis.exits.count == 1)
        #expect(finalAnalysis.modifiedFrames > 0 && finalAnalysis.maximumDifference > amplitude * 0.01)
        #expect(finalAnalysis.finalMaximumStep < finalAnalysis.rawMaximumStep)
        try ControlBoundaryEvidence.record(["name": "known-control-boundary-two-layers", "sourceRate": sourceRate,
            "sourceAmplitude": amplitude, "rawContentMaximumError": golden.maximumSampleError,
            "comparedRawFrames": golden.comparedFrames, "finalOutput": finalAnalysis.json,
            "outputRate": processor.outputSampleRate, "delayFrames": processor.delayFrames,
            "envelopeFrames": processor.envelopeFrames])
        try PlaybackBoundaryEvidence.record([
            "operation": "pause-resume", "sourceSampleRate": sourceRate, "sourceAmplitude": amplitude,
            "steady": metrics(steady), "pause": metrics(pause), "resume": metrics(resume),
            "frozenMediaSeconds": frozen.position, "resumedMediaSeconds": resumed.position,
            "generationBefore": before.generation, "generationAfter": resumed.generation,
            "pauseRequestedTicks": frozen.lastPauseRequestedAt,
            "pauseExecutedTicks": frozen.lastPauseExecutedAt,
            "pauseCompletedTicks": frozen.lastPauseCompletedAt,
            "resumeRequestedTicks": resumed.lastResumeRequestedAt,
            "resumeExecutedTicks": resumed.lastResumeExecutedAt,
            "resumeCompletedTicks": resumed.lastResumeCompletedAt,
            "sourceFramesCompared": golden.comparedFrames, "maximumPCMError": golden.maximumSampleError,
            "resumeRefillSilenceFrames": resumeRefillSilenceFrames, "measuredRefillBoundFrames": refillBound,
            "productionSignalProcessingChanged": true, "pcmComparisonLayer": "pre-envelope-with-same-fifo-delay",
            "processedFinalOutput": finalAnalysis.json,
        ])
    }

    @Test(arguments: [44_100.0, 96_000.0])
    func directReplacementMeasuresStopResetAndStartBoundary(sourceRate: Double) throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try fixture(sampleRate: sourceRate, amplitude: 0.55, phase: 0.71,
                                in: folder, name: "first-original-synthetic-tone")
        let second = try fixture(sampleRate: sourceRate, amplitude: 0.55, phase: 2.18,
                                 in: folder, name: "second-original-synthetic-tone")
        let subject = try engine(first, sourceRate: sourceRate)
        defer { subject.stopAll() }
        var steady = Array(repeating: [Float](), count: 2)
        for index in 0..<32 {
            let output = try subject.renderOfflineForTesting(quantum)
            if index >= 28 { try append(output, to: &steady) }
        }
        let before = subject.transportSnapshotForTesting(.a)
        var replacement = steady.map { Array($0.suffix(Int(quantum))) }
        subject.stop(deck: .a)
        _ = try subject.loadFile(at: second, on: .a)
        subject.play(deck: .a, from: 0)
        try waitForPreparedSource(subject, sourceRate: sourceRate)
        let replaced = subject.transportSnapshotForTesting(.a)
        for _ in 0..<40 { try append(subject.renderOfflineForTesting(quantum), to: &replacement) }
        #expect(replaced.generation > before.generation)
        #expect(!replaced.paused && replaced.nodePlaying)
        let allReplacementSamplesAreFinite = replacement.flatMap { $0 }.allSatisfy { $0.isFinite }
        #expect(allReplacementSamplesAreFinite)
        #expect((replacement.flatMap { $0 }.map(abs).max() ?? 0) > 0.2)
        try PlaybackBoundaryEvidence.record([
            "operation": "direct-stop-load-play", "sourceSampleRate": sourceRate,
            "steady": metrics(steady), "replacement": metrics(replacement),
            "generationBefore": before.generation, "generationAfter": replaced.generation,
            "productionSignalProcessingChanged": true, "nonzeroReplacementRepairClaim": false,
        ])
    }
}
