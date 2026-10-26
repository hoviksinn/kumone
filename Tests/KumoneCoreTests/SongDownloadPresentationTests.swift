import AppKit
import SwiftUI
import Testing
@testable import KumoneCore

@Suite("Song download presentation", .serialized)
@MainActor
struct SongDownloadPresentationTests {
    private func track() throws -> Track {
        try JSONDecoder().decode(Track.self, from: Data(
            #"{"id":987654,"name":"Synthetic download presentation","dt":3000}"#.utf8))
    }

    /// Host the actual public controls without account/settings environment
    /// objects. A hidden control must neither instantiate its download body
    /// nor reserve a button-sized hit region in a song/queue/header row.
    private func expectNoControl<V: View>(_ content: V) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 240, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView:
            HStack(spacing: 0) {
                Color.clear.frame(width: 24, height: 24)
                content
            }
            .fixedSize()
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(hosting.fittingSize.width - 24) < 1,
                "Hidden download content must not reserve a clickable row action")
        #expect(abs(hosting.fittingSize.height - 24) < 1)
    }

    @Test func trackAndQueueDownloadControlHasNoRenderedButton() async throws {
        try await expectNoControl(TrackDownloadButton(track: track(), isVisible: true))
    }

    @Test func songDownloadActionsHaveNoRenderedControl() async throws {
        try await expectNoControl(TrackDownloadActions(track: track(), showsIcons: true))
    }

    @Test func albumAndPlaylistDownloadControlsHaveNoRenderedButton() async throws {
        let song = try track()
        try await expectNoControl(DownloadCollectionButton(tracks: [song], owner: "album:123", name: "Synthetic album"))
        try await expectNoControl(DownloadCollectionButton(tracks: [song], owner: "playlist:456", name: "Synthetic playlist",
                                                           compact: true))
    }
}
