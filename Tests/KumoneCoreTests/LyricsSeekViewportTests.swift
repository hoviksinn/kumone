import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import XCTest
@testable import KumoneCore

// Run this real lyric viewport in its own XCTest process, away from the other
// AppKit fixtures and the GPU/audio suites. Test media is synthetic and offline;
// timing comparisons do not establish DAC output or physical listening quality.

@MainActor
private final class LyricsViewportApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        XCTFail("The hosted lyric viewport unexpectedly requested application termination")
        return .terminateCancel
    }
}

@MainActor
private enum LyricsViewportEvidence {
    static var cases: [[String: Any]] = []

    // Cache the actual hosted view for diagnosis, not as a readiness signal or
    // a pixel-match oracle. Calls happen after setup or after Seek assertions,
    // outside the measured Seek interval. All content is synthetic test data.
    static func capturePNG(_ host: NSView) -> [String: Any] {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ["available": false, "reason": "Native bitmap representation unavailable"]
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return ["available": false, "reason": "Native PNG encoding unavailable"]
        }
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let name = "lyrics-viewport-\(cases.count).png"
        let destination = URL(fileURLWithPath: root).appendingPathComponent(".build/\(name)")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return ["available": true, "file": name, "bytes": data.count,
                    "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
                    "scope": "Public NSView cached rendering of the real production LyricsPanel; not a physical display capture or automated glyph-pixel acceptance"]
        } catch {
            return ["available": false, "reason": String(describing: error)]
        }
    }

    static func record(_ values: [String: Any]) throws {
        cases.append(values)
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let destination = URL(fileURLWithPath: root)
            .appendingPathComponent(".build/lyrics-seek-viewport-validation.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "scope": "Actual production LyricsPanel in NSHostingView; real native wheel/document motion and production row identity/text/bounds from public SwiftUI anchors, converted through one native receiver. AX is supplemental. No glyph-pixel/VoiceOver/DAC/listening/frame-throughput claim.",
            "cases": cases,
        ], options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }
}

@MainActor
private struct HostedLyricsRoot: View {
    let player: PlayerService
    let presentation: LyricsPanelPresentation

    var body: some View {
        LyricsPanel(presentation: presentation)
            .environmentObject(player)
            .environmentObject(SettingsManager.shared)
            .overlayPreferenceValue(LyricsViewportAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    LyricsGeometryCapture(frames: anchors.mapValues { geometry[$0] })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// One test-only, transparent receiver for the entire real hosted panel. Its
/// rectangles come from anchors on existing production rows/the follow button,
/// never from a row-height estimate, duplicate lyric UI or the cursor index.
@MainActor
private struct LyricsGeometryCapture: NSViewRepresentable {
    let frames: [LyricsViewportElement: CGRect]

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        if view.frames != frames {
            view.frames = frames
            view.layoutRevision &+= 1
        }
    }

    @MainActor
    final class CaptureView: NSView {
        var frames: [LyricsViewportElement: CGRect] = [:]
        var layoutRevision: UInt64 = 0
        // GeometryReader uses a top-left origin. AppKit conversion handles
        // flipping and the real window origin instead of assuming an offset.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func screenFrame(of element: LyricsViewportElement) -> NSRect? {
            guard let frame = frames[element], !frame.isEmpty, let window else { return nil }
            return window.convertToScreen(convert(frame, to: nil))
        }
    }
}

final class LyricsSeekViewportTests: XCTestCase {}

@MainActor
extension LyricsSeekViewportTests {
    private enum FixtureFailure: Error { case unready(String) }

    private struct AccessibilityObservation {
        let label: String
        let title: String
        let value: String
        let role: String
        let sourceClass: String
        let childCount: Int
        let frame: NSRect

        var textValues: [String] { [label, title, value].filter { !$0.isEmpty } }
    }

    @MainActor
    private final class Fixture {
        private static var applicationPrepared = false
        private static let applicationDelegate = LyricsViewportApplicationDelegate()
        let engine: PlaybackEngine
        let player: PlayerService
        let window: NSWindow
        let host: NSHostingView<HostedLyricsRoot>
        let temporaryDirectory: URL
        var lastAccessibilityQuery: [String: Any] = [:]
        var wheelReceipts: [[String: Any]] = []

        init(presentation: LyricsPanelPresentation, paused: Bool) async throws {
            if !Self.applicationPrepared {
                NSApplication.shared.delegate = Self.applicationDelegate
                NSApplication.shared.finishLaunching()
                Self.applicationPrepared = true
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("QieTingLyricsViewport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("synthetic.caf")
            let format = DeckChain.format
            let frames = AVAudioFrameCount(20 * format.sampleRate)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            pcm.frameLength = frames
            let channels = try XCTUnwrap(pcm.floatChannelData)
            for frame in 0..<Int(frames) {
                let seconds = Double(frame) / format.sampleRate
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][frame] = Float(0.1 * sin(2 * .pi * (173 * seconds + 17 * seconds * seconds)))
                }
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: pcm)
            let fixtureEngine = PlaybackEngine()
            try fixtureEngine.enableOfflineRenderingForTesting(maximumFrameCount: 1024)
            _ = try fixtureEngine.loadFile(at: url, on: .a)
            fixtureEngine.play(deck: .a, from: 0)
            let track = try JSONDecoder().decode(Track.self, from: Data(
                #"{"id":626262,"name":"Seek viewport fixture","dt":20000}"#.utf8))
            let lyrics = ParsedLyrics(lines: (0..<40).map {
                LyricLine(id: $0, time: Double($0) * 0.5, text: "Seek fixture line \($0)")
            })
            // The injected service starts no timer, account observer, network
            // operation, user-file migration or real output-device routing.
            let fixturePlayer = PlayerService(playbackEngineForTesting: fixtureEngine, track: track, lyrics: lyrics)
            if paused { fixturePlayer.pause() }
            let initialSample = await fixturePlayer.samplePlaybackTime()
            _ = try XCTUnwrap(initialSample)
            let fixtureWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 440, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            fixtureWindow.isReleasedWhenClosed = false
            let fixtureHost = NSHostingView(rootView: HostedLyricsRoot(player: fixturePlayer, presentation: presentation))
            temporaryDirectory = directory
            engine = fixtureEngine
            player = fixturePlayer
            window = fixtureWindow
            host = fixtureHost
            fixtureWindow.contentView = fixtureHost
            fixtureWindow.makeKeyAndOrderFront(nil)
            fixtureHost.layoutSubtreeIfNeeded()
            // Complete actual queued SwiftUI/AppKit work, rather than sleeping
            // for an assumed launch or scroll animation duration.
            await Self.nativeLayoutCommit(host)
        }

        static func nativeLayoutCommit(_ host: NSView) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    continuation.resume()
                }
            }
        }

        func dispose() {
            engine.stopAll()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func accessibilityObservations(_ fixture: Fixture) -> [AccessibilityObservation] {
        var seen: Set<ObjectIdentifier> = []
        var observations: [AccessibilityObservation] = []
        var rawElements: [[String: Any]] = []
        func protocols(_ candidate: AnyObject) -> [String: Bool] {
            ["full": candidate is any NSAccessibilityProtocol,
             "base": candidate is any NSAccessibilityElementProtocol,
             "staticText": candidate is any NSAccessibilityStaticText,
             "button": candidate is any NSAccessibilityButton]
        }
        func visit(_ candidate: AnyObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(candidate)).inserted else { return }
            rawElements.append(["class": String(describing: type(of: candidate)),
                                "depth": depth, "protocols": protocols(candidate)])
            var label = "", title = "", value = "", role = ""
            var frame = NSRect.zero
            var children: [Any] = []
            if let element = candidate as? any NSAccessibilityProtocol {
                children = element.accessibilityChildren() ?? []
                let rawValue = element.accessibilityValue()
                // Static text can expose its content as AXValue. Query each
                // public field independently: an empty AXLabel must not hide
                // a nonempty AXTitle or AXValue on the same native element.
                value = (rawValue as? String) ?? (rawValue as? NSAttributedString)?.string ?? ""
                label = element.accessibilityLabel() ?? ""
                title = element.accessibilityTitle() ?? ""
                role = element.accessibilityRole()?.rawValue ?? ""
                frame = element.accessibilityFrame()
            } else {
                // Role-based elements need not adopt the much larger full
                // NSAccessibilityProtocol. Use only their public interfaces.
                if let element = candidate as? any NSAccessibilityElementProtocol {
                    frame = element.accessibilityFrame()
                }
                if let text = candidate as? any NSAccessibilityStaticText {
                    value = text.accessibilityValue() ?? ""
                    role = NSAccessibility.Role.staticText.rawValue
                }
                if let button = candidate as? any NSAccessibilityButton {
                    label = button.accessibilityLabel() ?? ""
                    role = NSAccessibility.Role.button.rawValue
                }
            }
            observations.append(AccessibilityObservation(
                label: label, title: title, value: value, role: role,
                sourceClass: String(describing: type(of: candidate)),
                childCount: children.count, frame: frame))
            for child in children { visit(child as AnyObject, depth: depth + 1) }
            // A hosting bridge can be ignored by AX while a descendant NSView
            // owns the actual accessible scroll document. Preserve that route
            // without assuming every bridge exports its native subviews in AX.
            if let view = candidate as? NSView {
                for child in view.subviews { visit(child, depth: depth + 1) }
            }
        }
        let host = fixture.host
        let ordered = host.accessibilityChildrenInNavigationOrder() ?? []
        let unignored = NSAccessibility.unignoredChildren(from: [host])
        var hitResults: [(point: NSPoint, element: AnyObject?)] = []
        var points: Set<String> = []
        // Query actual native leaf centers. Their geometry only supplies AX
        // hit-test points; identity still requires the returned lyric text.
        // No row index, guessed row height or synthetic label is substituted.
        for view in descendants(host) where view.subviews.isEmpty && !view.isHiddenOrHasHiddenAncestor {
            let rect = view.convert(view.bounds, to: host).intersection(host.bounds)
            guard !rect.isEmpty else { continue }
            let point = fixture.window.convertPoint(toScreen: host.convert(
                NSPoint(x: rect.midX, y: rect.midY), to: nil))
            guard points.insert(NSStringFromPoint(point)).inserted else { continue }
            let element = host.accessibilityHitTest(point).map { $0 as AnyObject }
            hitResults.append((point: point, element: element))
        }
        visit(host, depth: 0)
        for element in ordered { visit(element as AnyObject, depth: 0) }
        for element in unignored { visit(element as AnyObject, depth: 0) }
        for result in hitResults {
            if let element = result.element { visit(element, depth: 0) }
        }
        fixture.lastAccessibilityQuery = [
            "navigationOrderCount": ordered.count, "unignoredCount": unignored.count,
            "navigationOrder": ordered.map { element -> [String: Any] in
                ["class": String(describing: type(of: element)), "protocols": protocols(element as AnyObject)]
            },
            "unignored": unignored.map { element -> [String: Any] in
                ["class": String(describing: type(of: element)), "protocols": protocols(element as AnyObject)]
            },
            "hitTests": hitResults.map { result -> [String: Any] in
                ["screenPoint": NSStringFromPoint(result.point),
                 "class": result.element.map { String(describing: type(of: $0)) } ?? "none",
                 "protocols": result.element.map(protocols) ?? [:]]
            },
            "rawElements": Array(rawElements.prefix(240)),
        ]
        return observations
    }

    private func visibleFrame(of scroll: NSScrollView, in window: NSWindow) -> NSRect {
        window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
    }

    private func geometryCapture(_ fixture: Fixture) -> LyricsGeometryCapture.CaptureView? {
        descendants(fixture.host).compactMap { $0 as? LyricsGeometryCapture.CaptureView }.first
    }

    private func lineFrame(_ index: Int, in fixture: Fixture) -> NSRect? {
        // Both identity and text originate at the existing production row.
        // A missing/unrealized row stays missing; no coordinate is synthesized.
        geometryCapture(fixture)?.screenFrame(of: .line(id: index, text: "Seek fixture line \(index)"))
    }

    private func hasFollowButton(_ fixture: Fixture) -> Bool {
        guard let frame = geometryCapture(fixture)?.screenFrame(of: .followPlayback) else { return false }
        let panel = fixture.window.convertToScreen(fixture.host.convert(fixture.host.bounds, to: nil))
        return frame.intersects(panel)
    }

    private func geometrySnapshot(_ fixture: Fixture) -> [String: Any] {
        guard let capture = geometryCapture(fixture) else { return ["attached": false, "captureCount": 0] }
        let count = descendants(fixture.host).compactMap { $0 as? LyricsGeometryCapture.CaptureView }.count
        let rows = capture.frames.map { element, frame -> [String: Any] in
            var values: [String: Any] = [
                "frameInCapture": NSStringFromRect(frame),
                "screenFrame": capture.screenFrame(of: element).map(NSStringFromRect) ?? "detached-or-empty",
            ]
            switch element {
            case .line(let id, let text):
                values["kind"] = "line"
                values["lineID"] = id
                values["text"] = text
            case .followPlayback:
                values["kind"] = "actual-follow-button"
            }
            return values
        }
        return [
            "attached": capture.window === fixture.window, "captureCount": count,
            "bounds": NSStringFromRect(capture.bounds),
            "screenFrame": NSStringFromRect(fixture.window.convertToScreen(capture.convert(capture.bounds, to: nil))),
            "layoutRevision": capture.layoutRevision, "isFlipped": capture.isFlipped,
            "elements": rows,
            "scope": "Actual production component identity/text and layout/hit bounds; no cursor-derived or estimated coordinates, no post-blur glyph pixels or AX semantic claim",
        ]
    }

    private func setupSnapshot(_ fixture: Fixture, scenario: String) -> [String: Any] {
        let views = descendants(fixture.host)
        let accessibility = accessibilityObservations(fixture)
        let rendering = LyricsViewportEvidence.capturePNG(fixture.host)
        return [
            "scenario": scenario,
            "windowFrame": NSStringFromRect(fixture.window.frame),
            "hostBounds": NSStringFromRect(fixture.host.bounds),
            "windowVisible": fixture.window.isVisible, "windowKey": fixture.window.isKeyWindow,
            "applicationActive": NSApp.isActive,
            "applicationRunning": NSApp.isRunning,
            "activationPolicy": NSRunningApplication.current.activationPolicy.rawValue,
            "lyricLineCount": fixture.player.lyrics?.lines.count ?? -1,
            "activeIndex": fixture.player.lyricsCursor.activeIndex ?? -1,
            "progressSeconds": fixture.player.progress,
            "nativeViews": views.prefix(200).map { view -> [String: Any] in
                ["class": String(describing: type(of: view)), "bounds": NSStringFromRect(view.bounds),
                 "frameInWindow": NSStringFromRect(view.convert(view.bounds, to: nil)),
                 "visibleRect": NSStringFromRect(view.visibleRect),
                 "hidden": view.isHiddenOrHasHiddenAncestor]
            },
            "nativeScrollViews": views.compactMap { $0 as? NSScrollView }.map { scroll -> [String: Any] in
                ["class": String(describing: type(of: scroll)),
                 "documentClass": scroll.documentView.map { String(describing: type(of: $0)) } ?? "none",
                 "documentBounds": NSStringFromRect(scroll.documentView?.bounds ?? .zero),
                 "documentVisibleRect": NSStringFromRect(scroll.documentVisibleRect),
                 "clipBounds": NSStringFromRect(scroll.contentView.bounds),
                 "contentSize": NSStringFromSize(scroll.contentSize),
                 "viewportScreenFrame": NSStringFromRect(visibleFrame(of: scroll, in: fixture.window))]
            },
            "geometryCapture": geometrySnapshot(fixture),
            "nativeCachedRendering": rendering,
            "nativeWheelReceipts": fixture.wheelReceipts,
            "accessibilityQuery": fixture.lastAccessibilityQuery,
            "accessibility": accessibility.prefix(240).map { item -> [String: Any] in
                ["class": item.sourceClass, "role": item.role, "label": item.label,
                 "title": item.title, "value": item.value, "children": item.childCount,
                 "screenFrame": NSStringFromRect(item.frame)]
            },
        ]
    }

    private func waitForSetup(_ fixture: Fixture, description: String,
                              captureInitialRendering: Bool = false,
                              condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        repeat {
            await Fixture.nativeLayoutCommit(fixture.host)
            if condition() {
                if captureInitialRendering {
                    try LyricsViewportEvidence.record(setupSnapshot(fixture, scenario: "setup-ready: \(description)"))
                } else {
                    // Do not spend the real manual-follow grace period on
                    // bitmap caching or semantic-tree diagnostics.
                    try LyricsViewportEvidence.record([
                        "scenario": "setup-ready: \(description)",
                        "geometryCapture": geometrySnapshot(fixture),
                    ])
                }
                return
            }
            // Only readiness polling. No post-seek delay is admitted below:
            // otherwise the production 3s manual-follow timeout could hide it.
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        let failure = setupSnapshot(fixture, scenario: "setup-failed: \(description)")
        try LyricsViewportEvidence.record(failure)
        // Preserve the synthetic failure receipt even if artifact collection
        // itself fails. This runs only after the unchanged readiness deadline.
        let data = try JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys])
        print("LYRICS_VIEWPORT_SETUP_FAILURE " + String(decoding: data, as: UTF8.self))
        XCTFail("Unable to establish actual hosted viewport setup: \(description)")
        throw FixtureFailure.unready(description)
    }

    private func wheel(_ delta: Int32, phase: CGScrollPhase, expectedPhase: NSEvent.Phase,
                       in scroll: NSScrollView, window: NSWindow) throws -> [String: Any] {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: point)
        // CGEvent positions use global top-left coordinates; the scroll view
        // receives the event directly, so it needs no global event tap or TCC.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screenPoint.x, y: top - screenPoint.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.phase, expectedPhase, "Reject malformed native phase injection")
        let before = scroll.documentVisibleRect
        scroll.scrollWheel(with: event)
        return ["phase": event.phase.rawValue, "delta": delta,
                "scrollingDeltaX": event.scrollingDeltaX, "scrollingDeltaY": event.scrollingDeltaY,
                "deltaX": event.deltaX, "deltaY": event.deltaY,
                "cgPointDeltaY": cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                "cgFixedDeltaY": cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                "momentumPhase": event.momentumPhase.rawValue, "eventTimestamp": event.timestamp,
                "eventWindowNumber": event.windowNumber,
                "fixtureWindowNumber": window.windowNumber,
                "eventHasFixtureWindow": event.window === window,
                "locationInWindow": NSStringFromPoint(event.locationInWindow),
                "locationInScroll": NSStringFromPoint(scroll.convert(event.locationInWindow, from: nil)),
                "documentVisibleBefore": NSStringFromRect(before),
                "documentVisibleAfterDispatch": NSStringFromRect(scroll.documentVisibleRect)]
    }

    private func enterRealManualScrolling(_ fixture: Fixture, scroll: NSScrollView) async throws {
        let before = scroll.documentVisibleRect
        fixture.wheelReceipts.append(try wheel(-80, phase: .began, expectedPhase: .began,
                                              in: scroll, window: fixture.window))
        // A real gesture delivers separate native input turns. Sending its
        // whole lifetime in one synchronous stack can hide intermediate
        // interaction phases from the hosted SwiftUI scroll coordinator.
        // Commit each existing phase; do not sleep or change the Seek budget.
        await Fixture.nativeLayoutCommit(fixture.host)
        fixture.wheelReceipts[fixture.wheelReceipts.count - 1]["documentVisibleAfterNativeCommit"] = NSStringFromRect(scroll.documentVisibleRect)
        fixture.wheelReceipts[fixture.wheelReceipts.count - 1]["followButtonAfterNativeCommit"] = hasFollowButton(fixture)
        fixture.wheelReceipts.append(try wheel(-100, phase: .changed, expectedPhase: .changed,
                                              in: scroll, window: fixture.window))
        await Fixture.nativeLayoutCommit(fixture.host)
        fixture.wheelReceipts[fixture.wheelReceipts.count - 1]["documentVisibleAfterNativeCommit"] = NSStringFromRect(scroll.documentVisibleRect)
        fixture.wheelReceipts[fixture.wheelReceipts.count - 1]["followButtonAfterNativeCommit"] = hasFollowButton(fixture)
        fixture.wheelReceipts.append(try wheel(0, phase: .ended, expectedPhase: .ended,
                                              in: scroll, window: fixture.window))
        try await waitForSetup(fixture, description: "native wheel movement and production follow button") {
            scroll.documentVisibleRect != before && self.hasFollowButton(fixture)
        }
        XCTAssertNotEqual(scroll.documentVisibleRect, before, "A generated event without a real scroll is not coverage")
        XCTAssertTrue(hasFollowButton(fixture), "The production manual-follow suspension must actually be active")
    }

    private func verifyExternalSeek(presentation: LyricsPanelPresentation,
                                    paused: Bool, manualScroll: Bool) async throws {
        let fixture = try await Fixture(presentation: presentation, paused: paused)
        defer { fixture.dispose() }
        var nativeScroll: NSScrollView?
        try await waitForSetup(fixture, description: "initial lyric line and native scroll view",
                               captureInitialRendering: true) {
            nativeScroll = self.descendants(fixture.host).compactMap { $0 as? NSScrollView }.first
            guard let scroll = nativeScroll, let first = self.lineFrame(0, in: fixture) else { return false }
            return first.intersects(self.visibleFrame(of: scroll, in: fixture.window))
                && (scroll.documentView?.bounds.height ?? 0) > scroll.contentSize.height
        }
        let scroll = try XCTUnwrap(nativeScroll)
        let capture = try XCTUnwrap(geometryCapture(fixture), "The real production-row bounds receiver must be mounted")
        XCTAssertTrue(capture.window === fixture.window)
        XCTAssertEqual(descendants(fixture.host).compactMap { $0 as? LyricsGeometryCapture.CaptureView }.count, 1)
        XCTAssertEqual(capture.bounds.size.width, fixture.host.bounds.size.width, accuracy: 0.5)
        XCTAssertEqual(capture.bounds.size.height, fixture.host.bounds.size.height, accuracy: 0.5)
        if manualScroll {
            try await enterRealManualScrolling(fixture, scroll: scroll)
        } else {
            XCTAssertFalse(hasFollowButton(fixture), "Ordinary seek must start with automatic following enabled")
        }
        let before = scroll.documentVisibleRect
        let geometryBefore = geometrySnapshot(fixture)
        let target = 12.0
        let targetIndex = 24
        let beforeTargetFrame = lineFrame(targetIndex, in: fixture)
        XCTAssertFalse(beforeTargetFrame.map {
            !$0.isEmpty && $0.intersects(visibleFrame(of: scroll, in: fixture.window))
        } ?? false, "The destination must start outside the viewport for this to test an actual scroll")
        let issued = ProcessInfo.processInfo.systemUptime
        // Match the real external progress-scrubber ordering rather than
        // invoking a lyric-row click or the manual-follow button.
        fixture.player.isScrubbing = true
        fixture.player.seek(to: target)
        fixture.player.isScrubbing = false
        let acceptedSample = await fixture.player.samplePlaybackTime()
        let sample = try XCTUnwrap(acceptedSample)
        XCTAssertEqual(sample.seconds, target, accuracy: 2 / DeckChain.format.sampleRate)
        XCTAssertEqual(fixture.engine.position(of: .a), sample.seconds, accuracy: 2 / DeckChain.format.sampleRate)
        XCTAssertEqual(fixture.player.progress, sample.seconds)
        XCTAssertEqual(fixture.player.livePlaybackTime, sample.seconds)
        XCTAssertEqual(fixture.player.lyricsCursor.mediaTime, sample.seconds)
        XCTAssertEqual(fixture.player.lyricsCursor.activeIndex, targetIndex)
        for _ in 0..<3 { await Fixture.nativeLayoutCommit(fixture.host) }
        let elapsed = ProcessInfo.processInfo.systemUptime - issued
        let viewport = visibleFrame(of: scroll, in: fixture.window)
        let targetFrame = lineFrame(targetIndex, in: fixture)
        let follows = !hasFollowButton(fixture)
        let targetVisible = targetFrame.map { !$0.isEmpty && $0.intersects(viewport) } ?? false
        try LyricsViewportEvidence.record([
            "scenario": manualScroll ? "external-seek-after-real-manual-scroll" : "ordinary-external-seek-without-wheel-input",
            "presentation": presentation == .standard ? "standard" : "immersive",
            "paused": paused, "manualScrollBeforeSeek": manualScroll, "targetSeconds": target,
            "engineSeconds": fixture.engine.position(of: .a), "sampleSeconds": sample.seconds,
            "progressSeconds": fixture.player.progress, "lyricSeconds": fixture.player.lyricsCursor.mediaTime,
            "activeIndex": fixture.player.lyricsCursor.activeIndex ?? -1,
            "elapsedNativeCommitSeconds": elapsed,
            "manualFollowCleared": follows, "targetVisible": targetVisible,
            "targetRowScreenFrame": targetFrame.map(NSStringFromRect) ?? "not-realized",
            "rowMeasurement": "Actual production row ID and text with public bounds anchor/native screen conversion",
            "geometryBeforeSeek": geometryBefore, "geometryAfterSeek": geometrySnapshot(fixture),
            "viewportScreenFrame": NSStringFromRect(viewport),
            "documentVisibleBefore": NSStringFromRect(before),
            "documentVisibleAfter": NSStringFromRect(scroll.documentVisibleRect),
        ])
        // If CI scheduling itself consumes the automatic-follow interval, the
        // experiment did not isolate explicit Seek handling and must fail.
        XCTAssertLessThan(elapsed, LyricsVisualParameters.followResumeDelay,
                          "The viewport observation must precede timeout-based automatic recovery")
        XCTAssertTrue(follows, "Explicit external seek must end stale manual-scroll suspension")
        XCTAssertTrue(targetVisible,
                      "Correct engine/service/cursor time is insufficient: the actual target row must become visible")
        XCTAssertNotEqual(scroll.documentVisibleRect, before,
                          "A new active cursor must move the actual native document after external seek")
        XCTAssertEqual(fixture.player.isPlaying, !paused, "Viewport refresh must not change transport state")
        try LyricsViewportEvidence.record([
            "scenario": "native-render-after-seek-assertions",
            "presentation": presentation == .standard ? "standard" : "immersive",
            "paused": paused, "nativeCachedRendering": LyricsViewportEvidence.capturePNG(fixture.host),
        ])
    }

    func testPausedExternalSeekReanchorsStandardLyricsAfterRealManualScroll() async throws {
        try await verifyExternalSeek(presentation: .standard, paused: true, manualScroll: true)
    }

    func testPlayingExternalSeekReanchorsImmersiveLyricsAfterRealManualScroll() async throws {
        try await verifyExternalSeek(presentation: .immersive, paused: false, manualScroll: true)
    }

    func testOrdinaryPlayingSeekReanchorsStandardLyricsWithoutWheelInput() async throws {
        // This separate path prevents the manual-follow finding from being
        // mistaken for an explanation of every progress-scrubber seek.
        try await verifyExternalSeek(presentation: .standard, paused: false, manualScroll: false)
    }
}

