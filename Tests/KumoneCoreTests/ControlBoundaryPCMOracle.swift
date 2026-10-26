import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

/// Reads the real pre-envelope and final outputs from ONE production pull.
/// No render, seek, sample search or position change is performed by this oracle.
struct ControlBoundaryPCMTrace {
    private(set) var raw = [[Float](), [Float]()]
    private(set) var final = [[Float](), [Float]()]
    private(set) var starts: [Int64] = []
    private var nextSampleTime: Int64?

    mutating func append(_ pair: PlaybackEngine.BoundaryRenderEvidence) throws {
        let source = pair.rawOutput
        let output = pair.finalOutput
        try #require(source.frameLength == output.frameLength)
        try #require(source.format.sampleRate == output.format.sampleRate)
        try #require(source.format.channelCount == output.format.channelCount)
        try #require(source.format.channelCount == 2)
        if let nextSampleTime {
            #expect(pair.renderStartSampleTime == nextSampleTime,
                    "Raw and final evidence must cover consecutive actual output timestamps")
        }
        nextSampleTime = pair.renderStartSampleTime + Int64(output.frameLength)
        starts.append(pair.renderStartSampleTime)
        let before = try #require(source.floatChannelData)
        let after = try #require(output.floatChannelData)
        for channel in 0..<2 {
            raw[channel].append(contentsOf: UnsafeBufferPointer(start: before[channel], count: Int(source.frameLength)))
            self.final[channel].append(contentsOf: UnsafeBufferPointer(start: after[channel], count: Int(output.frameLength)))
        }
    }

    var frames: Int { raw.first?.count ?? 0 }
}

struct ControlBoundaryPCMAnalysis {
    let entries: [Int]
    let exits: [Int]
    let envelopeError: Float
    let unchangedError: Float
    let rawMaximumStep: Float
    let finalMaximumStep: Float
    let maximumDifference: Float
    let nonfiniteSamples: Int
    let modifiedFrames: Int

    var json: [String: Any] {
        ["silenceEntries": entries, "silenceExits": exits,
         "independentEnvelopeError": envelopeError, "unchangedRegionError": unchangedError,
         "rawMaximumAdjacentDelta": rawMaximumStep, "finalMaximumAdjacentDelta": finalMaximumStep,
         "maximumRawFinalDifference": maximumDifference, "nonfiniteSamples": nonfiniteSamples,
         "actuallyModifiedOutputFrames": modifiedFrames]
    }
}

enum ControlBoundaryPCMOracle {
    /// The fixture uses distinct stereo phases. A two-frame all-channel
    /// numerical floor is not confused with its normal single-channel zeros.
    /// Only call this on a trace whose ordinary start/refill has settled,
    /// containing explicitly issued pause/resume commands. Natural rests are
    /// tested separately and must remain unchanged while the gate is unarmed.
    static func analyze(_ trace: ControlBoundaryPCMTrace, envelopeFrames n: Int,
                        floor: Float) throws -> ControlBoundaryPCMAnalysis {
        try #require(n >= 2 && trace.frames > n)
        try #require(trace.raw.count == 2 && trace.final.count == 2)
        try #require(trace.raw.allSatisfy { $0.count == trace.frames })
        try #require(trace.final.allSatisfy { $0.count == trace.frames })
        let count = trace.frames
        let silent = (0..<count).map { i in trace.raw.allSatisfy { abs($0[i]) <= floor } }
        var entries: [Int] = []
        var exits: [Int] = []
        if count > 2 {
            for i in 1..<(count - 1) where !silent[i - 1] && silent[i] && silent[i + 1] { entries.append(i) }
            for i in 2..<count where silent[i - 2] && silent[i - 1] && !silent[i] { exits.append(i) }
        }
        // Independent mathematical expectation, not the processor's gain
        // receipts. This detects a bypass, tap-only processing or wrong edge.
        var gain = Array(repeating: 1.0, count: count)
        for edge in entries {
            let last = edge - 1
            for j in 0..<n {
                let frame = last - (n - 1 - j)
                guard frame >= 0 else { continue }
                let value: Double = j == 0 ? 1 : (j == n - 1 ? 0 : pow(cos(.pi * Double(j) / (2 * Double(n - 1))), 2))
                gain[frame] = min(gain[frame], value)
            }
        }
        for edge in exits {
            for j in 0..<n where edge + j < count {
                let value: Double = j == 0 ? 0 : (j == n - 1 ? 1 : pow(sin(.pi * Double(j) / (2 * Double(n - 1))), 2))
                gain[edge + j] = min(gain[edge + j], value)
            }
        }
        var expectedError: Float = 0
        var unchangedError: Float = 0
        var maximumDifference: Float = 0
        var maximumOvershoot: Float = 0
        var rawStep: Float = 0
        var finalStep: Float = 0
        var nonfinite = 0
        var modified = 0
        for frame in 0..<count {
            var changed = false
            for channel in 0..<2 {
                let raw = trace.raw[channel][frame]
                let actual = trace.final[channel][frame]
                guard raw.isFinite && actual.isFinite else { nonfinite += 1; continue }
                let expected = Float(Double(raw) * gain[frame])
                expectedError = max(expectedError, abs(actual - expected))
                let difference = abs(actual - raw)
                maximumDifference = max(maximumDifference, difference)
                if gain[frame] == 1 { unchangedError = max(unchangedError, difference) }
                if difference > 0.000_000_1 { changed = true }
                maximumOvershoot = max(maximumOvershoot, abs(actual) - abs(raw))
                if frame > 0 {
                    rawStep = max(rawStep, abs(raw - trace.raw[channel][frame - 1]))
                    finalStep = max(finalStep, abs(actual - trace.final[channel][frame - 1]))
                }
            }
            if changed { modified += 1 }
        }
        #expect(nonfinite == 0)
        #expect(maximumOvershoot < 0.000_000_1, "A de-click envelope may not amplify or clip the real raw output")
        #expect(expectedError < 0.000_01, "Actual final output must match the independent envelope")
        #expect(unchangedError < 0.000_01, "Outside the bounded edge envelope the final waveform must remain unchanged")
        return ControlBoundaryPCMAnalysis(entries: entries, exits: exits, envelopeError: expectedError,
            unchangedError: unchangedError, rawMaximumStep: rawStep, finalMaximumStep: finalStep,
            maximumDifference: maximumDifference, nonfiniteSamples: nonfinite, modifiedFrames: modified)
    }
}

enum ControlBoundaryEvidence {
    private static let lock = NSLock()
    private static var cases: [[String: Any]] = []

    static func record(_ value: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        cases.append(value)
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"] ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: root).appendingPathComponent(".build/control-boundary-validation.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report: [String: Any] = [
            "scope": "Actual inline production audio processor, pre-envelope raw and final output; not a physical DAC/listening or universal click-free claim",
            "rawContentTolerance": 0.000_01, "sampleCoordinate": "AU/manual output sample timestamps",
            "cases": cases,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        print("CONTROL_BOUNDARY \(value["name"] ?? "unknown")")
    }
}
