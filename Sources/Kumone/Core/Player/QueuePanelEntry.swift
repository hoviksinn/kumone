import Foundation

/// An occurrence in a specific queue snapshot. Two copies of the same song
/// have distinct origins; mutations retire all IDs rather than reusing a
/// deleted duplicate's identity for the next row.
struct QueuePanelEntry: Identifiable, Equatable {
    struct ID: Hashable {
        let revision: UInt64
        let origin: PlaybackQueueCandidate.Origin
    }

    let id: ID
    let track: Track

    init(candidate: PlaybackQueueCandidate, revision: UInt64) {
        id = .init(revision: revision, origin: candidate.origin)
        track = candidate.track
    }
}

/// AppKit delivers one mouse-up per physical click, with its native click
/// count. Selecting the first click is immediate; only the second activates.
enum QueueRowClickAction: Equatable {
    case select, activate, none

    static func action(clickCount: Int) -> Self {
        switch clickCount {
        case 1: return .select
        case 2: return .activate
        default: return .none
        }
    }
}
