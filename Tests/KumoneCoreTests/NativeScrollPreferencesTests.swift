import AppKit
import CoreGraphics
import Dispatch
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

    private func nativeCommit(_ root: NSView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                root.layoutSubtreeIfNeeded()
                root.displayIfNeeded()
                continuation.resume()
            }
        }
    }

    /// The production shelf, including its indicator modifier, is inside the
    /// same automatic vertical environment used by ordinary app pages. These
    /// read-only probes locate the actual native scroll views for assertions.
    private func shelves(identity: Int) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(0..<2) { row in
                    Shelf(title: "Shelf \(row)") {
                        HStack(spacing: 0) {
                            ForEach(0..<20) { index in
                                Text("Album \(index)").frame(width: 180, height: 80)
                            }
                        }
                        .background(NativeScrollPreferences().frame(width: 0, height: 0))
                    }
                    .frame(height: 140)
                }
                Text("Vertical content").frame(height: 900)
            }
            .frame(maxWidth: .infinity)
            .background(NativeScrollPreferences().frame(width: 0, height: 0))
        }
        .scrollIndicators(.automatic)
        .id(identity)
    }

    private func horizontalProbes(in root: NSView,
                                  excluding old: NSScrollView? = nil) async throws -> [NativeScrollPreferences.Probe] {
        for _ in 0..<50 {
            await nativeCommit(root)
            let matches = descendants(root, of: NativeScrollPreferences.Probe.self).filter { probe in
                guard let scroll = probe.enclosingScrollView, scroll !== old else { return false }
                return (scroll.documentView?.frame.width ?? 0) > scroll.contentSize.width + 100
            }
            if matches.count == 2 { return matches }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Both real production shelves must have wide native scroll documents")
        throw CocoaError(.coderReadCorrupt)
    }

    private func horizontalWheel(in scroll: NSScrollView, window: NSWindow) async throws {
        let start = scroll.documentVisibleRect
        let input = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 2, wheel1: 0, wheel2: -80, wheel3: 0))
        input.timestamp = DispatchTime.now().uptimeNanoseconds
        input.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        input.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: point)
        input.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        let event = try #require(NSEvent(cgEvent: input))
        #expect(event.type == .scrollWheel)
        #expect(event.scrollingDeltaX < 0 && event.scrollingDeltaY == 0)
        // This checks native horizontal input/document motion only. A direct
        // responder call is not a complete WindowServer gesture lifecycle or
        // evidence about trackpad momentum cancellation after lyric Seek.
        scroll.scrollWheel(with: event)
        await nativeCommit(scroll)
        let end = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
        end.timestamp = DispatchTime.now().uptimeNanoseconds
        end.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        end.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
        scroll.scrollWheel(with: try #require(NSEvent(cgEvent: end)))
        await nativeCommit(scroll)
        #expect(scroll.documentVisibleRect.origin.x > start.origin.x,
                "Hiding the native indicator must preserve real horizontal wheel scrolling")
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

    @Test func productionShelvesNeverShowHorizontalIndicatorsUnderNativeStyles() async throws {
        let (window, hosting) = host(shelves(identity: 0))
        defer { window.close() }
        let horizontal = try await horizontalProbes(in: hosting)
        for style in [NSScroller.Style.legacy, .overlay] {
            for probe in descendants(hosting, of: NativeScrollPreferences.Probe.self) {
                probe.preferredStyle = { style }
                probe.applyPreferences()
            }
            await nativeCommit(hosting)
            for probe in horizontal {
                let scroll = try #require(probe.enclosingScrollView)
                #expect(scroll.scrollerStyle == style)
                #expect(!scroll.hasHorizontalScroller)
                #expect(!scroll.hasVerticalScroller)
                try await horizontalWheel(in: scroll, window: window)
            }
            let vertical = try #require(descendants(hosting, of: NativeScrollPreferences.Probe.self)
                .compactMap(\.enclosingScrollView).first { $0.hasVerticalScroller })
            #expect(vertical.scrollerStyle == style)
            #expect(!vertical.hasHorizontalScroller)
            #expect(vertical.autohidesScrollers)
            if style == .legacy {
                let indicator = try #require(vertical.verticalScroller)
                #expect(!indicator.isHiddenOrHasHiddenAncestor,
                        "An overflowing legacy vertical bar must remain available for Always users")
            }
        }
    }

    @Test func horizontalNeverPolicySurvivesNativeViewRecreation() async throws {
        let (window, hosting) = host(shelves(identity: 0))
        defer { window.close() }
        let original = try await horizontalProbes(in: hosting)
        let old = try #require(original.first?.enclosingScrollView)
        hosting.rootView = shelves(identity: 1)
        let replacements = try await horizontalProbes(in: hosting, excluding: old)
        #expect(old.window == nil)
        for probe in replacements {
            let scroll = try #require(probe.enclosingScrollView)
            probe.preferredStyle = { .legacy }
            probe.applyPreferences()
            await nativeCommit(hosting)
            #expect(scroll.scrollerStyle == .legacy)
            #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
            try await horizontalWheel(in: scroll, window: window)
        }
    }
}
