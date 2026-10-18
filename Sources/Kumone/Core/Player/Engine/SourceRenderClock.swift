import AVFoundation
import AudioToolbox
import Synchronization

/// A bounded, allocation-free render observer on the EXISTING source AU.
/// The seqlock publishes a paired timestamp and cumulative source frame
/// count. Pauses contribute zero frames, even if the native player clock's
/// host mapping jumps. It remains correct before time-pitch at any rate.
final class SourceRenderClock: @unchecked Sendable {
    struct Snapshot {
        var framesAtStart: UInt64
        var framesAtEnd: UInt64
        var sampleTime: Double
        var hostTime: UInt64
        var flags: UInt32

        func audioTime(sampleRate: Double) -> AVAudioTime? {
            var time = AudioTimeStamp()
            time.mSampleTime = sampleTime
            time.mHostTime = hostTime
            time.mFlags = AudioTimeStampFlags(rawValue: flags)
            guard time.mFlags.contains(.sampleTimeValid) else { return nil }
            return AVAudioTime(audioTimeStamp: &time, sampleRate: sampleRate)
        }
    }

    private let unit: AUAudioUnit
    private var token: Int?
    private final class Storage: @unchecked Sendable {
        let revision = Atomic<UInt64>(0)
        let renderedFrames = Atomic<UInt64>(0)
        let frameStart = Atomic<UInt64>(0)
        let sampleBits = Atomic<UInt64>(0)
        let hostTime = Atomic<UInt64>(0)
        let timestampFlags = Atomic<UInt32>(0)
    }
    private let storage = Storage()

    init(unit: AUAudioUnit) {
        self.unit = unit
        token = unit.token(byAddingRenderObserver: { [storage] flags, timestamp, count, bus in
            guard flags.contains(.unitRenderAction_PostRender),
                  !flags.contains(.unitRenderAction_PostRenderError), bus == 0 else { return }
            let stamp = timestamp.pointee
            _ = storage.revision.wrappingAdd(1, ordering: .acquiringAndReleasing)
            let previous = storage.renderedFrames.load(ordering: .relaxed)
            storage.frameStart.store(previous, ordering: .relaxed)
            storage.renderedFrames.store(previous + UInt64(count), ordering: .relaxed)
            storage.sampleBits.store(stamp.mSampleTime.bitPattern, ordering: .relaxed)
            storage.hostTime.store(stamp.mHostTime, ordering: .relaxed)
            storage.timestampFlags.store(stamp.mFlags.rawValue, ordering: .relaxed)
            _ = storage.revision.wrappingAdd(1, ordering: .releasing)
        })
    }

    deinit { if let token { unit.removeRenderObserver(token) } }

    var snapshot: Snapshot? {
        // Bounded retries: a position read may retain the previous media
        // position during an overlapping render, never spin on the queue.
        for _ in 0..<4 {
            let before = storage.revision.load(ordering: .acquiring)
            guard before > 0, before & 1 == 0 else { continue }
            let result = Snapshot(framesAtStart: storage.frameStart.load(ordering: .acquiring),
                framesAtEnd: storage.renderedFrames.load(ordering: .acquiring),
                sampleTime: Double(bitPattern: storage.sampleBits.load(ordering: .acquiring)),
                hostTime: storage.hostTime.load(ordering: .acquiring),
                flags: storage.timestampFlags.load(ordering: .acquiring))
            if storage.revision.load(ordering: .acquiring) == before { return result }
        }
        return nil
    }
}
