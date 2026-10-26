import AppKit
import Foundation
import Testing
@testable import KumoneCore

@Suite("Queue panel occurrence safety")
@MainActor
struct QueuePanelInteractionTests {
    private func track(_ id: Int) throws -> Track {
        try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "name": "Track \(id)", "dt": 180_000,
        ]))
    }

    @Test func identicalSongsHaveDistinctRowsAndDeleteTheClickedOccurrence() throws {
        let tracks = try [track(1), track(7), track(2), track(7), track(3)]
        let player = PlayerService(queueForTesting: tracks, currentIndex: 0)
        let entries = player.upcomingQueueEntries
        #expect(entries[0].track.id == entries[2].track.id)
        #expect(entries[0].id != entries[2].id)

        player.removeQueueEntry(entries[2])
        #expect(player.queue.map(\.id) == [1, 7, 2, 3])
        #expect(player.currentIndex == 0)
        #expect(player.currentTrack?.id == 1)

        // A queued/stale mouse event must not remove another occurrence.
        player.removeQueueEntry(entries[0])
        #expect(player.queue.map(\.id) == [1, 7, 2, 3])
    }

    @Test func deletingAnInsertedDuplicateDoesNotDeleteTheListedCopy() throws {
        let player = PlayerService(queueForTesting: try [track(1), track(7), track(3)], currentIndex: 0,
                                   inserted: try [track(7), track(2), track(7)])
        let entries = player.upcomingQueueEntries
        #expect(Set(entries.map(\.id)).count == entries.count)
        player.removeQueueEntry(entries[2])
        #expect(player.playNextList.map(\.id) == [7, 2])
        #expect(player.queue.map(\.id) == [1, 7, 3])

        player.removeQueueEntry(entries[2])
        player.jumpToQueueEntry(entries[2])
        #expect(player.playNextList.map(\.id) == [7, 2])
        #expect(player.currentTrack?.id == 1)
        #expect(!player.isPlaying)
    }

    @Test(arguments: [QueueOrder.listed, .shuffled, .autoMix])
    func removalKeepsTheCurrentOccurrenceAndActiveOrder(order: QueueOrder) throws {
        let tracks = try [track(7), track(2), track(7), track(3)]
        let player = PlayerService(queueForTesting: tracks, currentIndex: 0, order: order, orderedTracks: tracks)
        let entry = try #require(player.upcomingQueueEntries.first { $0.track.id == 7 })
        player.removeQueueEntry(entry)
        #expect(player.activeQueue.map(\.id) == [7, 2, 3])
        #expect(player.currentIndex == 0)
        #expect(player.currentTrack?.id == 7)
    }

    @Test func adjacentDuplicatesCannotBeRemovedTwiceByAStaleClick() throws {
        let player = PlayerService(queueForTesting: try [track(1), track(7), track(7), track(7)], currentIndex: 0)
        let first = try #require(player.upcomingQueueEntries.first)
        player.removeQueueEntry(first)
        player.removeQueueEntry(first)
        #expect(player.queue.map(\.id) == [1, 7, 7])
        let refreshed = try #require(player.upcomingQueueEntries.first)
        #expect(first.id != refreshed.id)
        player.removeQueueEntry(refreshed)
        #expect(player.queue.map(\.id) == [1, 7])
    }

    @Test func nativeMouseEventsSelectThenActivateOnlyOnce() throws {
        let view = QueueRowMouseTarget.ClickView(frame: NSRect(x: 0, y: 0, width: 200, height: 46))
        var selected = 0
        var activated = 0
        view.select = { selected += 1 }
        view.activate = { activated += 1 }

        for count in 1...3 {
            let down = try mouseEvent(type: .leftMouseDown, clickCount: count)
            let up = try mouseEvent(type: .leftMouseUp, clickCount: count)
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
        #expect(selected == 1)
        #expect(activated == 1)
    }

    @Test func releasingOutsideSongBodyDoesNotSelectOrPlay() throws {
        let view = QueueRowMouseTarget.ClickView(frame: NSRect(x: 0, y: 0, width: 200, height: 46))
        var selected = false
        var activated = false
        view.select = { selected = true }
        view.activate = { activated = true }
        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, clickCount: 1))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, clickCount: 1, location: NSPoint(x: 240, y: 20)))
        #expect(!selected)
        #expect(!activated)
    }

    @Test func queueBodyKeyboardActivationDoesNotRunTheSelectionAction() throws {
        let view = QueueRowMouseTarget.ClickView(frame: NSRect(x: 0, y: 0, width: 200, height: 46))
        var selected = 0
        var activated = 0
        view.select = { selected += 1 }
        view.activate = { activated += 1 }
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ",
                                                 isARepeat: false, keyCode: 49))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 1, windowNumber: 0, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        view.keyDown(with: space)
        #expect(selected == 1)
        #expect(activated == 0)
        view.keyDown(with: enter)
        #expect(selected == 1)
        #expect(activated == 1)
    }

    @Test func foreignSnapshotOrCurrentOccurrenceCannotMutateTheQueue() throws {
        let player = PlayerService(queueForTesting: try [track(1), track(7), track(7)], currentIndex: 0)
        let original = player.queue
        let current = QueuePanelEntry(candidate: .init(track: original[0], origin: .queue(0)),
                                      revision: player.queueRevision)
        let wrongSong = QueuePanelEntry(candidate: .init(track: try track(99), origin: .queue(1)),
                                        revision: player.queueRevision)
        let future = QueuePanelEntry(candidate: .init(track: original[1], origin: .queue(1)),
                                     revision: player.queueRevision &+ 1)
        for entry in [current, wrongSong, future] {
            player.removeQueueEntry(entry)
            player.jumpToQueueEntry(entry)
        }
        #expect(player.queue == original)
        #expect(player.currentIndex == 0)
        #expect(player.currentTrack?.id == 1)
        #expect(!player.isPlaying)
    }

    private func mouseEvent(type: NSEvent.EventType, clickCount: Int,
                            location: NSPoint = NSPoint(x: 20, y: 20)) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                       timestamp: Double(clickCount), windowNumber: 0, context: nil,
                                       eventNumber: clickCount, clickCount: clickCount, pressure: 0))
    }
}
