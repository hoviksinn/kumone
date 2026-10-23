import AppKit
import CoreGraphics
import Dispatch
import SwiftUI
import Testing
@testable import KumoneCore

@MainActor
private enum NativeScrollEvidence {
    static var gestures: [[String: Any]] = []

    static func record(_ gesture: [String: Any]) throws {
        gestures.append(gesture)
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let destination = URL(fileURLWithPath: root)
            .appendingPathComponent(".build/native-scroll-validation.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let scope = "Public CG-created wheel input delivered to the actual native scroll view, with per-phase native document motion. CG-created NSEvents have no associated NSWindow; this does not establish NSApplication/WindowServer routing, physical trackpad momentum, or fading. No programmatic document/clip/knob position changes in the wheel checks."
        try JSONSerialization.data(withJSONObject: ["scope": scope, "gestures": gestures],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
        let receipt = try JSONSerialization.data(withJSONObject: gesture, options: [.sortedKeys])
        print("NATIVE_SCROLL_GESTURE " + String(decoding: receipt, as: UTF8.self))
    }
}

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

    private enum WheelSequence: String {
        case originalBeganEnded
        case completeGesture
    }

    private func scrollSnapshot(_ scroll: NSScrollView) -> [String: Any] {
        ["scrollClass": String(describing: type(of: scroll)),
         "scrollBounds": NSStringFromRect(scroll.bounds),
         "scrollVisibleRect": NSStringFromRect(scroll.visibleRect),
         "clipBounds": NSStringFromRect(scroll.contentView.bounds),
         "clipVisibleRect": NSStringFromRect(scroll.contentView.visibleRect),
         "documentFrame": NSStringFromRect(scroll.documentView?.frame ?? .zero),
         "documentBounds": NSStringFromRect(scroll.documentView?.bounds ?? .zero),
         "documentVisibleRect": NSStringFromRect(scroll.documentVisibleRect),
         "offsetX": scroll.documentVisibleRect.origin.x,
         "offsetY": scroll.documentVisibleRect.origin.y,
         "contentWidth": scroll.contentSize.width,
         "documentWidth": scroll.documentView?.frame.width ?? 0,
         "scrollerStyle": scroll.scrollerStyle.rawValue,
         "hasHorizontalScroller": scroll.hasHorizontalScroller,
         "hasVerticalScroller": scroll.hasVerticalScroller,
         "autohidesScrollers": scroll.autohidesScrollers]
    }

    private func horizontalWheel(in scroll: NSScrollView, window: NSWindow,
                                 scenario: String, sequence: WheelSequence = .completeGesture) async throws {
        let start = scroll.documentVisibleRect
        let initial = scrollSnapshot(scroll)
        #expect(scroll.window === window)
        #expect((scroll.documentView?.frame.width ?? 0) > scroll.contentSize.width + 100)
        let visible = scroll.contentView.visibleRect
        #expect(!visible.isEmpty)
        let point = scroll.contentView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        let screen = window.convertPoint(toScreen: point)
        let root = try #require(window.contentView)
        let hit = root.hitTest(root.convert(point, from: nil))
        #expect(hit?.enclosingScrollView === scroll,
                "The wheel point must fall inside the actual visible target scroll view")
        // Match the public WebKit test helper's complete wheel sequence:
        // began carries one pixel, changed carries the remainder, ended zero.
        // Keep the old two-event setup on separate diagnostic fixtures so CI
        // can distinguish a missing changed phase from a production failure.
        let phases: [(CGScrollPhase, NSEvent.Phase, Int32)] = sequence == .completeGesture
            ? [(.began, .began, -1), (.changed, .changed, -79), (.ended, .ended, 0)]
            : [(.began, .began, -80), (.ended, .ended, 0)]
        var receipts: [[String: Any]] = []
        for (cgPhase, phase, deltaX) in phases {
            let input = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                            wheelCount: 2, wheel1: 0, wheel2: deltaX, wheel3: 0))
            input.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            input.flags = []
            input.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            input.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgPhase.rawValue))
            input.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            input.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            let event = try #require(NSEvent(cgEvent: input))
            #expect(event.type == .scrollWheel)
            #expect(event.timestamp > 0)
            #expect(event.phase == phase && event.momentumPhase.isEmpty)
            #expect(event.hasPreciseScrollingDeltas)
            #expect(event.scrollingDeltaX == CGFloat(deltaX) && event.scrollingDeltaY == 0)
            let before = scrollSnapshot(scroll)
            scroll.scrollWheel(with: event)
            await nativeCommit(scroll)
            receipts.append([
                "eventType": event.type.rawValue, "eventTimestamp": event.timestamp,
                "modifierFlags": event.modifierFlags.rawValue,
                "eventWindowNumber": event.windowNumber, "eventHasHostWindow": event.window === window,
                "eventHasAnyWindow": event.window != nil,
                "locationInWindow": NSStringFromPoint(event.locationInWindow),
                "intendedWindowPoint": NSStringFromPoint(point), "screenPoint": NSStringFromPoint(screen),
                "hitViewClass": hit.map { String(describing: type(of: $0)) } ?? "none",
                "hitViewEnclosingScrollIsTarget": hit?.enclosingScrollView === scroll,
                "phase": event.phase.rawValue, "cgPhase": cgPhase.rawValue,
                "momentumPhase": event.momentumPhase.rawValue,
                "scrollingDeltaX": event.scrollingDeltaX, "scrollingDeltaY": event.scrollingDeltaY,
                "deltaX": event.deltaX, "deltaY": event.deltaY,
                "cgPointDeltaX": input.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                "cgFixedDeltaX": input.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                "before": before, "afterNativeCommit": scrollSnapshot(scroll),
            ])
        }
        try NativeScrollEvidence.record([
            "scenario": scenario, "sequence": sequence.rawValue,
            "delivery": "direct NSScrollView.scrollWheel(with:) using public CG/NSEvent APIs",
            "hostWindowNumber": window.windowNumber, "hostWindowFrame": NSStringFromRect(window.frame),
            "before": initial, "after": scrollSnapshot(scroll), "events": receipts,
            "actualHorizontalMotion": scroll.documentVisibleRect.origin.x > start.origin.x,
        ])
        if sequence == .completeGesture {
            #expect(scroll.documentVisibleRect.origin.x > start.origin.x,
                    "The complete native horizontal wheel gesture must move the actual document")
        }
    }

    @Test func completeHorizontalWheelGestureMovesNativeControl() async throws {
        for style in [NSScroller.Style.legacy, .overlay] {
            for sequence in [WheelSequence.originalBeganEnded, .completeGesture] {
                _ = NSApplication.shared
                let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 300),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
                scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 3600, height: 260))
                scroll.hasHorizontalScroller = true
                scroll.hasVerticalScroller = false
                scroll.scrollerStyle = style
                scroll.autohidesScrollers = true
                window.contentView = scroll
                window.orderFront(nil)
                await nativeCommit(scroll)
                try await horizontalWheel(in: scroll, window: window,
                                          scenario: "ordinary-native-control", sequence: sequence)
            }
        }
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
        let (originalWindow, originalHosting) = host(shelves(identity: 0))
        defer { originalWindow.close() }
        let horizontal = try await horizontalProbes(in: hosting)
        let originalHorizontal = try await horizontalProbes(in: originalHosting)
        for style in [NSScroller.Style.legacy, .overlay] {
            for root in [hosting, originalHosting] {
                for probe in descendants(root, of: NativeScrollPreferences.Probe.self) {
                    probe.preferredStyle = { style }
                    probe.applyPreferences()
                }
                await nativeCommit(root)
            }
            for probe in originalHorizontal {
                let scroll = try #require(probe.enclosingScrollView)
                try await horizontalWheel(in: scroll, window: originalWindow,
                                          scenario: "production-shelf-original-input-diagnostic",
                                          sequence: .originalBeganEnded)
            }
            for probe in horizontal {
                let scroll = try #require(probe.enclosingScrollView)
                #expect(scroll.scrollerStyle == style)
                #expect(!scroll.hasHorizontalScroller)
                #expect(!scroll.hasVerticalScroller)
                try await horizontalWheel(in: scroll, window: window, scenario: "production-shelf-hidden-indicator")
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
            try await horizontalWheel(in: scroll, window: window, scenario: "production-shelf-recreated-native-view")
        }
    }
}
