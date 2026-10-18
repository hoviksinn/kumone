import AppKit
import SwiftUI
import Testing
@testable import KumoneCore

/// These are hosted native scroll views, not a reimplementation of scrollbar
/// layout. Physical trackpad fading and dragging still need a real Mac check.
@Suite("Native scrollbar preferences", .serialized)
@MainActor
struct NativeScrollPreferencesTests {
    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func host<V: View>(_ content: V) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func probe(in root: NSView) async throws -> NativeScrollPreferences.Probe {
        for _ in 0..<50 {
            root.layoutSubtreeIfNeeded()
            if let probe = descendants(root, of: NativeScrollPreferences.Probe.self).first,
               probe.enclosingScrollView != nil {
                return probe
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("SwiftUI did not attach the native preference probe to its NSScrollView")
        throw CocoaError(.coderReadCorrupt)
    }

    @Test func verticalScrollViewAdoptsNativePreferenceAndRemainsScrollable() async throws {
        let (window, hosting) = host(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<60) { index in
                        Text("Song \(index)").frame(maxWidth: .infinity, minHeight: 30)
                    }
                }
                .background(NativeScrollPreferences().frame(width: 0, height: 0))
            }
            .scrollIndicators(.automatic)
        )
        defer { window.close() }
        let probe = try await probe(in: hosting)
        let scroll = try #require(probe.enclosingScrollView)
        probe.applyPreferences()
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        #expect(scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.autohidesScrollers)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y > 100)
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
    }

    @Test func liveSystemPreferenceChangesPreserveTheScrollAxes() async throws {
        let (window, hosting) = host(
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0..<20) { index in
                        Text("Album \(index)").frame(width: 180, height: 80)
                    }
                }
                .background(NativeScrollPreferences().frame(width: 0, height: 0))
            }
            .scrollIndicators(.automatic)
        )
        defer { window.close() }
        let probe = try await probe(in: hosting)
        let scroll = try #require(probe.enclosingScrollView)
        #expect(scroll.hasHorizontalScroller)
        #expect(!scroll.hasVerticalScroller)
        var style = NSScroller.Style.legacy
        probe.preferredStyle = { style }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect(scroll.scrollerStyle == .legacy)
        #expect(scroll.horizontalScroller != nil)
        #expect(scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
        style = .overlay
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
        probe.preferredStyle = { NSScroller.preferredScrollerStyle }
        probe.applyPreferences()
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
    }
}
