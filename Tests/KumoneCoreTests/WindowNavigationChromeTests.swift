import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest
@testable import KumoneCore

// XCTest adapters preserve the original Boolean expressions, optional
// requirements, failure propagation, and each assertion's source location.
// The throwing autoclosure also admits an optional requirement nested inside
// an expectation without evaluating the requirement outside XCTAssertTrue.
private func expect(_ expression: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try expression(), message(), file: file, line: line)
}

private func require<Value>(_ expression: @autoclosure () throws -> Value?,
                            _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) throws -> Value {
    try XCTUnwrap(try expression(), message(), file: file, line: line)
}

@discardableResult
private func require(_ expression: @autoclosure () throws -> Bool,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
    try XCTUnwrap(try expression() ? true : nil, message(), file: file, line: line)
}

@MainActor
private final class NavigationFixtureState: ObservableObject {
    @Published var path: [Destination] = []
    @Published var columnVisibility: NavigationSplitViewVisibility = .detailOnly
}

/// A hosted test process is not the application executable. Unexpected AppKit
/// termination must be an observable test failure, not an early successful exit.
@MainActor
private final class HostedNavigationApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let stack = Thread.callStackSymbols
        try? NavigationValidationEvidence.record([
            "scenario": "unexpected-application-termination",
            "currentEventType": sender.currentEvent.map { Int($0.type.rawValue) } ?? -1,
            "stack": stack,
        ])
        XCTFail("Hosted window test unexpectedly requested NSApplication termination: \(stack.joined(separator: "\n"))")
        return .terminateCancel
    }
}

private struct NavigationFixtureLeaf: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.identifier = NSUserInterfaceItemIdentifier(name) }
}

@MainActor
private struct NavigationFixtureRoot: View {
    @ObservedObject var state: NavigationFixtureState
    let player: PlayerService
    let panels: WindowPanelCoordinator
    let columnVisibility: NavigationSplitViewVisibility
    var body: some View {
        MainWindow(path: $state.path, testing: MainWindowTestConfiguration(
            leaf: { destination in AnyView(NavigationFixtureLeaf(name: fixtureName(destination))) },
            panelCoordinator: panels, initialColumnVisibility: columnVisibility,
            liveColumnVisibility: $state.columnVisibility))
            .environmentObject(player)
            .environmentObject(AccountStore.shared)
            .environmentObject(SettingsManager.shared)
            .environmentObject(ToastCenter.shared)
            // Match production: MainWindow is the only declarative minimum.
            // NSHostingView's standard sizing bounds propagate it to AppKit.
    }
}

private func fixtureName(_ destination: Destination?) -> String {
    "fixture." + (destination.map { String(describing: $0) } ?? "home")
}

@MainActor
private enum NavigationValidationEvidence {
    static var cases: [[String: Any]] = []
    static func record(_ values: [String: Any]) throws {
        cases.append(values)
        let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"] ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: root).appendingPathComponent(".build/window-navigation-validation.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "scope": "Real MainWindow/HSplitView/NavigationStack/PlayerBar in NSHostingView; offline synthetic page leaves. Synthetic screen bounds affect production opening geometry only; NSWindow frame requests remain subject to the physical hosted display. No physical multi-monitor/full-screen animation claim.",
            "cases": cases,
        ], options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

/// Unlike rectangle-only tests these push real SwiftUI navigation destinations
/// and inspect the production player's native attachment, visibility and input.
final class WindowNavigationChromeTests: XCTestCase {}

@MainActor
extension WindowNavigationChromeTests {
    private enum FixtureFailure: Error {
        case timedOut(String)
    }

    @MainActor
    private final class Fixture {
        private static var applicationPrepared = false
        private static let applicationDelegate = HostedNavigationApplicationDelegate()
        let state: NavigationFixtureState
        let panels = WindowPanelCoordinator()
        let player: PlayerService
        let window: NSWindow
        let host: NSHostingView<NavigationFixtureRoot>
        init(columnVisibility: NavigationSplitViewVisibility = .detailOnly) async throws {
            let fixtureState = NavigationFixtureState()
            fixtureState.columnVisibility = columnVisibility
            state = fixtureState
            if !Self.applicationPrepared {
                try NavigationValidationEvidence.record(["scenario": "application-bootstrap", "phase": "before-finishLaunching"])
                NSApplication.shared.delegate = Self.applicationDelegate
                // Keep a stack even for a direct exit that bypasses AppKit's
                // delegate. This is test-process diagnostics, never App code.
                atexit {
                    fputs("HOSTED_TEST_PROCESS_EXIT\n", stderr)
                    for line in Thread.callStackSymbols { fputs(line + "\n", stderr) }
                }
                // SwiftPM supplies no NSApplication event loop. Finish the
                // native launch once before dispatching real AppKit events.
                NSApplication.shared.finishLaunching()
                Self.applicationPrepared = true
                try NavigationValidationEvidence.record(["scenario": "application-bootstrap", "phase": "after-finishLaunching"])
            }
            let track = try JSONDecoder().decode(Track.self, from: Data(
                #"{"id":606060,"name":"Navigation fixture","dt":180000}"#.utf8))
            // Graph construction only: no engine start, hardware routing,
            // account/network observers, persistence or progress timer.
            player = PlayerService(playbackEngineForTesting: PlaybackEngine(), track: track,
                                   lyrics: ParsedLyrics(lines: []))
            panels.animationDuration = 0.04
            window = NSWindow(contentRect: CGRect(x: 0, y: 80, width: 1021, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: Theme.Layout.minWindowWidth,
                                           height: Theme.Layout.minWindowHeight)
            host = NSHostingView(rootView: NavigationFixtureRoot(state: state, player: player, panels: panels,
                                                               columnVisibility: columnVisibility))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            // Construct the real native hierarchy as fixture setup. The
            // following four-second observation budget measures settling and
            // interactions, not lazy creation of SwiftUI's first host graph.
            let layoutStart = ProcessInfo.processInfo.systemUptime
            host.layoutSubtreeIfNeeded()
            try NavigationValidationEvidence.record([
                "scenario": "fixture-initial-layout",
                "seconds": ProcessInfo.processInfo.systemUptime - layoutStart,
                "hostBounds": NSStringFromRect(host.bounds),
                "coordinatorAttached": panels.window === window,
            ])
            // MainWindowConfigurator deliberately attaches on the next main
            // dispatch turn, outside SwiftUI's synchronous graph transaction.
            // Complete that real bootstrap before starting interaction clocks.
            // FIFO ordering is a readiness barrier, not a guessed time delay.
            let queuedAt = ProcessInfo.processInfo.systemUptime
            let dispatchedAt = await withCheckedContinuation { (continuation: CheckedContinuation<TimeInterval, Never>) in
                DispatchQueue.main.async {
                    continuation.resume(returning: ProcessInfo.processInfo.systemUptime)
                }
            }
            try NavigationValidationEvidence.record([
                "scenario": "fixture-native-attachment-barrier",
                "mainQueueSeconds": dispatchedAt - queuedAt,
                "continuationSeconds": ProcessInfo.processInfo.systemUptime - dispatchedAt,
                "coordinatorAttached": panels.window === window,
            ])
            try require(panels.window === window, "The real configurator must attach before the fixture is ready")
        }
        func dispose() {
            player.pause()
            panels.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
    private func markers(_ name: String, in root: NSView) -> [NSView] {
        descendants(root).filter { $0.identifier?.rawValue == name && $0.window != nil }
    }

    private func rectValues(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY),
         "width": Double(rect.width), "height": Double(rect.height)]
    }

    private func snapshot(_ fixture: Fixture, scenario: String, includeTree: Bool = false) -> [String: Any] {
        let views = descendants(fixture.host)
        let main = markers("QieTing.MainColumn", in: fixture.host).first
        let contentLayout = fixture.window.contentLayoutRect
        // Build only JSON values here; never hand AppKit objects or enum-keyed
        // dictionaries to the evidence writer, including on failure paths.
        var values: [String: Any] = [
            "scenario": scenario,
            "path": fixture.state.path.map { fixtureName($0) },
            "windowFrame": rectValues(fixture.window.frame),
            "contentLayoutRect": rectValues(contentLayout),
            "contentBounds": rectValues(fixture.window.contentView?.bounds ?? .zero),
            "hostBounds": rectValues(fixture.host.bounds),
            "contentMinimum": ["width": Double(fixture.window.contentMinSize.width),
                               "height": Double(fixture.window.contentMinSize.height)],
            "coordinatorMinimumWidth": Double(fixture.panels.minimumContentWidth),
            "declarativeMinimumWidth": Double(fixture.panels.declarativeMinimumContentWidth),
            "hostFittingSize": ["width": Double(fixture.host.fittingSize.width),
                                "height": Double(fixture.host.fittingSize.height)],
            "contentAspectRatio": Double(contentLayout.width / max(1, contentLayout.height)),
            "mainColumnWidth": Double(main?.bounds.width ?? 0),
            "mainColumnFrame": rectValues(main.map { $0.convert($0.bounds, to: fixture.host) } ?? .zero),
            "panelMode": fixture.panels.mode.rawValue,
            "panel": fixture.panels.panel.map { String(describing: $0) } ?? "none",
            "activePanel": fixture.player.activePanel.map { String(describing: $0) } ?? "none",
            "panelWidth": Double(fixture.panels.panelWidth),
            "baseContentWidth": Double(fixture.panels.baseContentWidth),
            "insideReveal": Double(fixture.panels.insideReveal),
            "isAnimating": fixture.panels.isAnimating,
            "isFullScreen": fixture.panels.isFullScreen,
            "insufficientSpace": fixture.panels.insufficientSpace,
            "originalFrame": rectValues(fixture.panels.originalFrame ?? .zero),
            "windowVisible": fixture.window.isVisible,
            "windowKey": fixture.window.isKeyWindow,
            "applicationActive": NSApp.isActive,
            "applicationRunning": NSApp.isRunning,
            "applicationDelegateClass": NSApp.delegate.map { String(describing: type(of: $0)) } ?? "none",
            "nativeToolbarStyle": Int(fixture.window.toolbarStyle.rawValue),
            "nativeToolbarVisible": fixture.window.toolbar?.isVisible ?? false,
            "nativeToolbarPresent": fixture.window.toolbar != nil,
            "nativeToolbarItems": fixture.window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? [],
            "nativeContentRect": rectValues(fixture.window.contentRect(forFrameRect: fixture.window.frame)),
            "hasAttachedSheet": fixture.window.attachedSheet != nil,
            "hasModalWindow": NSApp.modalWindow != nil,
            "firstResponderClass": fixture.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
            "editingFieldCount": views.compactMap { $0 as? NSTextField }.filter { $0.currentEditor() != nil }.count,
            "physicalVisibleFrame": rectValues(fixture.window.screen?.visibleFrame ?? .zero),
            "syntheticVisibleFrame": rectValues(fixture.panels.visibleFrameForTesting ?? .zero),
        ]
        values["markers"] = views.compactMap { view -> [String: Any]? in
            guard let name = view.identifier?.rawValue,
                  name.hasPrefix("QieTing.") || name.hasPrefix("fixture.") else { return nil }
            return ["identifier": name, "class": String(describing: type(of: view)),
                    "bounds": rectValues(view.bounds), "frameInWindow": rectValues(view.convert(view.bounds, to: nil)),
                    "visibleRect": rectValues(view.visibleRect), "hidden": view.isHiddenOrHasHiddenAncestor,
                    "attached": view.window === fixture.window]
        }
        values["nativeWindowControls"] = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind -> [String: Any] in
            guard let control = fixture.window.standardWindowButton(kind) else {
                return ["kind": Int(kind.rawValue), "present": false]
            }
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: control.superview)
            return ["kind": Int(kind.rawValue), "present": true,
                    "bounds": rectValues(control.bounds), "frame": rectValues(control.frame),
                    "hidden": control.isHiddenOrHasHiddenAncestor, "alpha": Double(control.alphaValue),
                    "attached": control.window === fixture.window,
                    "hitClass": control.hitTest(point).map { String(describing: type(of: $0)) } ?? "none"]
        }
        if includeTree {
            values["nativeTree"] = views.map { view in
                ["class": String(describing: type(of: view)), "identifier": view.identifier?.rawValue ?? "",
                 "bounds": NSStringFromRect(view.bounds)]
            }
        }
        return values
    }

    @discardableResult
    private func requireOutsidePlan(_ fixture: Fixture, scenario: String) throws -> CGFloat {
        let main = try require(markers("QieTing.MainColumn", in: fixture.host).first)
        let visible = try require(fixture.panels.visibleFrameForTesting ?? fixture.window.screen?.visibleFrame)
        let plan = WindowPanelGeometry.openingPlan(
            frame: fixture.window.frame, contentSize: fixture.window.contentLayoutRect.size,
            mainWidth: main.bounds.width, visibleFrame: visible, isFullScreen: fixture.panels.isFullScreen)
        var values = snapshot(fixture, scenario: scenario)
        values["openingPlanMode"] = plan?.mode.rawValue ?? "rejected"
        values["openingPlanPanelWidth"] = Double(plan?.panelWidth ?? 0)
        values["openingPlanFrame"] = rectValues(plan?.frame ?? .zero)
        try NavigationValidationEvidence.record(values)
        // Outside-session tests must prove their real hosted geometry admits
        // that mode before a rejected request can present a modal alert.
        try require(plan?.mode == .expandedOutside, "The hosted fixture must admit an outside pane before this scenario")
        return main.bounds.width
    }

    private func wait(_ fixture: Fixture, _ description: String, stableLayout: Bool = false,
                      condition: () -> Bool) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 4
        var previous: NativeLayoutObservation?
        var unchangedSince = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            let layoutStart = ProcessInfo.processInfo.systemUptime
            fixture.host.layoutSubtreeIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            let satisfied = condition()
            let current = satisfied && stableLayout ? nativeLayoutObservation(fixture) : nil
            samples.append([
                "elapsed": now - started, "layoutSeconds": now - layoutStart,
                "predicateSatisfied": satisfied, "nativeObservationAvailable": current != nil,
                "editableFieldCount": descendants(fixture.host).compactMap { $0 as? NSTextField }.filter { $0.isEditable }.count,
                "coordinatorAttached": fixture.panels.window === fixture.window,
                "observationUnchanged": current != nil && current == previous,
                "unchangedSeconds": now - unchangedSince,
                "frame": NSStringFromRect(fixture.window.frame),
            ])
            // Preserve the first observation plus the latest settling history.
            if samples.count > 13 { samples.remove(at: 1) }
            if satisfied {
                if !stableLayout || (current != nil && current == previous && now - unchangedSince >= 0.25) {
                    try NavigationValidationEvidence.record([
                        "scenario": "wait-completed: \(description)", "samples": samples,
                    ])
                    return
                }
                if let current {
                    if current != previous {
                        previous = current
                        unchangedSince = now
                    }
                } else {
                    previous = nil
                    unchangedSince = now
                }
            } else {
                previous = nil
                unchangedSince = now
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try NavigationValidationEvidence.record([
            "scenario": "wait-timed-out: \(description)", "samples": samples,
        ])
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "timeout: \(description)", includeTree: true))
        XCTFail("Timed out waiting for \(description); mode=\(fixture.panels.mode.rawValue), frame=\(fixture.window.frame), contentLayout=\(fixture.window.contentLayoutRect), insufficientSpace=\(fixture.panels.insufficientSpace). See window-navigation-validation.json for the native snapshot.")
        throw FixtureFailure.timedOut(description)
    }

    private struct NativeLayoutObservation: Equatable {
        let windowFrame: CGRect
        let contentLayoutRect: CGRect
        let contentMinimum: NSSize
        let hostBounds: CGRect
        let mainBounds: CGRect
        let mainFrame: CGRect
        let editableFieldCount: Int
    }

    private func nativeLayoutObservation(_ fixture: Fixture) -> NativeLayoutObservation? {
        guard fixture.panels.window === fixture.window, !fixture.panels.isAnimating,
              let main = markers("QieTing.MainColumn", in: fixture.host).first,
              main.bounds.width >= PlayerLayoutMetrics.minimumMainWidth,
              main.bounds.height > 0 else { return nil }
        let fields = descendants(fixture.host).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        guard fields.count == 1 else { return nil }
        // SwiftUI installs native titlebar/toolbar constraints after the
        // initial host layout. Observe the resulting minimum and geometry,
        // without assuming any fixed titlebar height or frame adjustment.
        return NativeLayoutObservation(
            windowFrame: fixture.window.frame,
            contentLayoutRect: fixture.window.contentLayoutRect,
            contentMinimum: fixture.window.contentMinSize,
            hostBounds: fixture.host.bounds,
            mainBounds: main.bounds,
            mainFrame: main.convert(main.bounds, to: fixture.host),
            editableFieldCount: fields.count)
    }

    private func check(_ fixture: Fixture, destination: Destination?,
                       originalBar: ObjectIdentifier? = nil, scenario: String) async throws -> ObjectIdentifier {
        let expected = fixtureName(destination)
        try await wait(fixture, "configured window and visible destination \(expected)", stableLayout: true) {
            guard fixture.panels.window === fixture.window,
                  self.markers(expected, in: fixture.host).contains(where: {
                      !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor
                  }),
                  let bar = self.markers("QieTing.PlayerBar", in: fixture.host).first,
                  let lyrics = self.markers("QieTing.PlayerBar.Lyrics", in: fixture.host).first,
                  let main = self.markers("QieTing.MainColumn", in: fixture.host).first
            else { return false }
            // Native configuration and middle-column geometry are committed
            // asynchronously after initial hosting. Observe their completion
            // instead of racing the first panel command against attachment.
            let frame = bar.convert(bar.bounds, to: fixture.host)
            return main.bounds.width >= PlayerLayoutMetrics.minimumMainWidth
                && bar.bounds.width >= 779 && abs(bar.bounds.height - 56) < 1
                && frame.minX >= fixture.host.bounds.minX - 0.5
                && frame.maxX <= fixture.host.bounds.maxX + 0.5
                && lyrics.bounds.width > 0 && lyrics.bounds.height > 0
                && abs(lyrics.bounds.width - lyrics.bounds.height) < 1
        }
        let bars = markers("QieTing.PlayerBar", in: fixture.host)
        expect(bars.count == 1)
        let bar = try require(bars.first)
        let identity = ObjectIdentifier(bar)
        if let originalBar { expect(identity == originalBar) }
        expect(bar.window === fixture.window)
        expect(!bar.isHiddenOrHasHiddenAncestor)
        expect(!bar.visibleRect.isEmpty)
        expect(bar.bounds.width >= 779 && bar.bounds.width <= 881)
        expect(abs(bar.bounds.height - 56) < 1)
        let barFrame = bar.convert(bar.bounds, to: fixture.host)
        expect(barFrame.minX >= fixture.host.bounds.minX - 0.5)
        expect(barFrame.maxX <= fixture.host.bounds.maxX + 0.5)
        let button = try require(markers("QieTing.PlayerBar.Lyrics", in: fixture.host).first)
        expect(abs(button.bounds.width - button.bounds.height) < 1)
        let pointInWindow = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let pointInHostSuperview = fixture.host.superview?.convert(pointInWindow, from: nil) ?? pointInWindow
        let hit = fixture.host.hitTest(pointInHostSuperview)
        expect(hit != nil)
        let leaves = markers(expected, in: fixture.host)
        expect(!leaves.contains { leaf in hit === leaf || (hit?.isDescendant(of: leaf) ?? false) })
        expect(fixture.player.currentTrack?.id == 606060)
        // Keeping native titlebar controls is part of the product contract;
        // NSToolbar item visibility alone does not prove those controls exist.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let control = try require(fixture.window.standardWindowButton(kind))
            expect(control.window === fixture.window)
            expect(!control.isHiddenOrHasHiddenAncestor)
            expect(control.alphaValue > 0.99)
            expect(control.bounds.width > 0 && control.bounds.height > 0)
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: control.superview)
            let hit = control.hitTest(point)
            expect(hit === control || (hit?.isDescendant(of: control) ?? false))
        }
        var values = snapshot(fixture, scenario: scenario)
        values.merge([
            "scenario": scenario, "destination": expected, "barIdentity": String(describing: identity),
            "attachedBarCount": bars.count, "barVisible": !bar.visibleRect.isEmpty,
            "barFrame": NSStringFromRect(bar.convert(bar.bounds, to: nil)),
            "panelMode": fixture.panels.mode.rawValue, "hitClass": hit.map { String(describing: type(of: $0)) } ?? "none",
            "isPlaying": fixture.player.isPlaying,
        ], uniquingKeysWith: { _, current in current })
        try NavigationValidationEvidence.record(values)
        return identity
    }

    func testAlbumArtistAndOrdinaryDestinationsKeepTheSameLivePlayer() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        let serviceID = ObjectIdentifier(fixture.player)
        let clockID = ObjectIdentifier(fixture.player.clock)
        expect(fixture.player.isPlaying)
        let bar = try await check(fixture, destination: nil, scenario: "home-playing")
        let originalWindowFrame = fixture.window.frame
        let playingPaths: [[Destination]] = [
            [.album(7)], [], [.artist(42)], [.artist(42), .album(7)], [.artist(42)], [],
            [.playlist(9)], [], [.search("fixture")], [], [.collections], [], [.recents], [], [.daily], [], [.cloud], [],
        ]
        for path in playingPaths {
            fixture.state.path = path
            _ = try await check(fixture, destination: path.last, originalBar: bar, scenario: "push-pop-playing")
            expect(fixture.player.isPlaying)
            expect(fixture.window.frame == originalWindowFrame)
        }
        fixture.player.pause()
        let pausedPaths: [[Destination]] = [[.artist(42)], [.artist(42), .album(7)], []]
        for path in pausedPaths {
            fixture.state.path = path
            _ = try await check(fixture, destination: path.last, originalBar: bar, scenario: "push-pop-paused")
            expect(!fixture.player.isPlaying)
            expect(fixture.window.frame == originalWindowFrame)
        }
        expect(ObjectIdentifier(fixture.player) == serviceID)
        expect(ObjectIdentifier(fixture.player.clock) == clockID)
    }

    func testLyricsQueueAndImmersiveKeepWindowAndPlayerIdentity() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        let bar = try await check(fixture, destination: nil, scenario: "before-panel")
        let original = fixture.window.frame
        // The hosted runner may have only a 1024pt physical display. Injecting
        // this geometry tests real window-frame operations, not real monitors.
        fixture.panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        try requireOutsidePlan(fixture, scenario: "lyrics-outside-precondition")
        fixture.player.activePanel = .lyrics
        try await wait(fixture, "outside lyrics", stableLayout: true) {
            fixture.panels.mode == .expandedOutside && !fixture.panels.isAnimating && fixture.window.frame.width > original.width + 280
        }
        let expanded = fixture.window.frame
        let panelPaths: [[Destination]] = [[.album(7)], [.artist(42)], []]
        for path in panelPaths {
            fixture.state.path = path
            _ = try await check(fixture, destination: path.last, originalBar: bar, scenario: "lyrics-navigation")
        }
        fixture.player.activePanel = .queue
        try await wait(fixture, "queue switch") { fixture.panels.panel == .queue }
        expect(fixture.window.frame == expanded)
        fixture.state.path = [.playlist(9)]
        _ = try await check(fixture, destination: .playlist(9), originalBar: bar, scenario: "queue-navigation")
        let minimum = fixture.window.contentMinSize
        let searchFields = descendants(fixture.host).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        expect(searchFields.count == 1)
        let searchField = try require(searchFields.first)
        expect(fixture.window.makeFirstResponder(searchField))
        try await wait(fixture, "native search field editor focused") {
            guard let editor = searchField.currentEditor() else { return false }
            return fixture.window.firstResponder === editor
        }
        let searchEditor = try require(searchField.currentEditor())
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "search-focused-before-immersive"))
        fixture.player.showNowPlaying = true
        try await wait(fixture, "attached immersive view") {
            self.markers("QieTing.Immersive", in: fixture.host).contains { !$0.visibleRect.isEmpty }
        }
        try await wait(fixture, "ordinary search field resigns its editor in immersive view") {
            fixture.window.firstResponder !== searchEditor && searchField.currentEditor() == nil
        }
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "search-resigned-in-immersive"))
        expect(markers("QieTing.PlayerBar", in: fixture.host).count == 1)
        expect(ObjectIdentifier(try require(markers("QieTing.PlayerBar", in: fixture.host).first)) == bar)
        expect(fixture.window.frame == expanded)
        expect(fixture.window.contentMinSize == minimum)
        let systemButtonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for kind in systemButtonTypes {
            let systemButton = try require(fixture.window.standardWindowButton(kind))
            expect(!systemButton.isHiddenOrHasHiddenAncestor)
            expect(systemButton.alphaValue > 0.99)
        }
        fixture.player.showNowPlaying = false
        try await wait(fixture, "immersive view removed") {
            self.markers("QieTing.Immersive", in: fixture.host).isEmpty
        }
        _ = try await check(fixture, destination: .playlist(9), originalBar: bar, scenario: "exit-immersive")
        expect(fixture.window.makeFirstResponder(searchField))
        try await wait(fixture, "ordinary search field accepts focus after immersive view") {
            guard let editor = searchField.currentEditor() else { return false }
            return fixture.window.firstResponder === editor
        }
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "search-refocused-after-immersive"))
        expect(fixture.window.makeFirstResponder(nil))
        fixture.player.activePanel = nil
        try await wait(fixture, "original frame restored", stableLayout: true) {
            fixture.panels.mode == .closed && abs(fixture.window.frame.width - original.width) < 0.5
        }
        expect(fixture.window.frame == original)
        expect(fixture.window.contentMinSize.width == PlayerLayoutMetrics.minimumWindowWidth)
        _ = try await check(fixture, destination: .playlist(9), originalBar: bar, scenario: "close-panel-restored")
    }

    func testRealLyricsButtonRemainsClickableAfterNavigation() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        fixture.panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        let bar = try await check(fixture, destination: nil, scenario: "before-real-click")
        fixture.state.path = [.album(7)]
        _ = try await check(fixture, destination: .album(7), originalBar: bar, scenario: "before-real-click-album")
        try requireOutsidePlan(fixture, scenario: "real-click-outside-precondition")
        let button = try require(markers("QieTing.PlayerBar.Lyrics", in: fixture.host).first)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "real-click-before-event-creation"))
        let down = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: fixture.window.windowNumber, context: nil,
                                                  eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                                windowNumber: fixture.window.windowNumber, context: nil,
                                                eventNumber: 2, clickCount: 1, pressure: 0))
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "real-click-before-post-up"))
        // Queue an up before down in case AppKit starts synchronous tracking.
        // Dispatch through NSApplication so its currentEvent and window routing
        // are established just as they are in the normal native event loop.
        NSApp.postEvent(up, atStart: true)
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "real-click-after-post-up"))
        NSApp.sendEvent(down)
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "real-click-after-send-down"))
        // SwiftUI may return from down without entering a tracking loop. In
        // that case dispatch our still-queued up explicitly; never consume an
        // event belonging to another hosted test or send a consumed up twice.
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
           queued.windowNumber == up.windowNumber, queued.eventNumber == up.eventNumber {
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
        }
        try NavigationValidationEvidence.record(snapshot(fixture, scenario: "real-click-after-up-dispatch"))
        try await wait(fixture, "real lyrics button action") { fixture.player.activePanel == .lyrics }
        _ = try await check(fixture, destination: .album(7), originalBar: bar, scenario: "after-real-click")
    }
    func testRapidPanelCommandsAndUserResizeDoNotAccumulateWindowWidth() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        _ = try await check(fixture, destination: nil, scenario: "rapid-before")
        fixture.panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        let mainWidth = try requireOutsidePlan(fixture, scenario: "rapid-outside-precondition")
        let original = fixture.window.frame
        for _ in 0..<10 {
            _ = fixture.panels.request(.lyrics, mainWidth: mainWidth)
            _ = fixture.panels.request(.queue, mainWidth: mainWidth)
            _ = fixture.panels.request(nil, mainWidth: mainWidth)
        }
        try await wait(fixture, "rapid session closes", stableLayout: true) { fixture.panels.mode == .closed && !fixture.panels.isAnimating }
        expect(fixture.window.frame == original)
        expect(fixture.panels.request(.lyrics, mainWidth: mainWidth))
        try await wait(fixture, "manual-resize start", stableLayout: true) { fixture.panels.mode == .expandedOutside && !fixture.panels.isAnimating }
        var manuallyChanged = fixture.window.frame
        manuallyChanged.origin.x += 30
        manuallyChanged.origin.y += 20
        manuallyChanged.size.width += 80
        manuallyChanged.size.height += 20
        fixture.window.setFrame(manuallyChanged, display: true)
        try await wait(fixture, "manual resize rebased", stableLayout: true) {
            abs((fixture.panels.originalFrame?.width ?? 0) - (original.width + 80)) < 0.5
        }
        let expected = try require(fixture.panels.originalFrame)
        let resizedMain = try require(markers("QieTing.MainColumn", in: fixture.host).first)
        expect(fixture.panels.request(nil, mainWidth: resizedMain.bounds.width))
        try await wait(fixture, "manual session closes", stableLayout: true) { fixture.panels.mode == .closed && !fixture.panels.isAnimating }
        expect(fixture.window.frame == expected)
    }

    func testVisibleSidebarAtTheSharedMinimumKeepsTheSingleRowWithinTheWindow() async throws {
        let fixture = try await Fixture(columnVisibility: .all)
        defer { fixture.dispose() }
        let bar = try await check(fixture, destination: nil, scenario: "sidebar-visible-minimum")
        fixture.state.path = [.album(7)]
        _ = try await check(fixture, destination: .album(7), originalBar: bar, scenario: "sidebar-minimum-album")
        let button = try require(markers("QieTing.PlayerBar.PlayPause", in: fixture.host).first)
        expect(button.bounds.width >= 30 && button.bounds.height >= 30)
        expect(button.bounds.width <= 40 && button.bounds.height <= 40)
        expect(fixture.window.contentMinSize.width == 1021)
        let nativeChrome = fixture.window.contentRect(forFrameRect: fixture.window.frame).height
            - fixture.window.contentLayoutRect.height
        expect(fixture.window.contentMinSize.height - nativeChrome == 640,
                "The shared minimum reserves 640pt of usable content independently of native chrome")
    }

    func testSidebarCollapseAndExpansionPreserveNavigationAndChromeInstances() async throws {
        let fixture = try await Fixture(columnVisibility: .all)
        defer { fixture.dispose() }
        let bar = try await check(fixture, destination: nil, scenario: "sidebar-toggle-before-navigation")
        let main = try require(markers("QieTing.MainColumn", in: fixture.host).first)
        let header = try require(markers("QieTing.MainHeader", in: fixture.host).first)
        let search = try require(descendants(fixture.host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let serviceID = ObjectIdentifier(fixture.player)
        let clockID = ObjectIdentifier(fixture.player.clock)
        let navigationPath: [Destination] = [.artist(42), .album(7)]
        fixture.state.path = navigationPath
        _ = try await check(fixture, destination: .album(7), originalBar: bar, scenario: "sidebar-toggle-nested-album")
        let leaf = try require(markers(fixtureName(.album(7)), in: fixture.host).first)

        for visibility in [NavigationSplitViewVisibility.detailOnly, .all, .detailOnly, .all] {
            fixture.state.columnVisibility = visibility
            let collapsed = visibility == .detailOnly
            let scenario = collapsed ? "sidebar-toggle-collapsed" : "sidebar-toggle-expanded"
            try await wait(fixture, "actual split-column geometry for \(scenario)") {
                guard let current = self.markers("QieTing.MainColumn", in: fixture.host).first else { return false }
                let frame = current.convert(current.bounds, to: fixture.host)
                return collapsed
                    ? abs(frame.minX - fixture.host.bounds.minX) < 0.5
                        && abs(frame.width - fixture.host.bounds.width) < 0.5
                    : frame.minX - fixture.host.bounds.minX >= PlayerLayoutMetrics.minimumSidebarWidth
                        && frame.width >= PlayerLayoutMetrics.minimumMainWidth
            }
            _ = try await check(fixture, destination: .album(7), originalBar: bar, scenario: scenario)
            expect(fixture.state.path == navigationPath)
            expect(markers("QieTing.MainColumn", in: fixture.host).count == 1)
            expect(markers("QieTing.MainColumn", in: fixture.host).first === main)
            expect(markers("QieTing.MainHeader", in: fixture.host).count == 1)
            expect(markers("QieTing.MainHeader", in: fixture.host).first === header)
            expect(!header.isHiddenOrHasHiddenAncestor && !header.visibleRect.isEmpty)
            let editableFields = descendants(fixture.host).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            expect(editableFields.count == 1)
            expect(editableFields.first === search)
            expect(search.window === fixture.window && !search.visibleRect.isEmpty)
            expect(markers(fixtureName(.album(7)), in: fixture.host).first === leaf)
            expect(ObjectIdentifier(fixture.player) == serviceID)
            expect(ObjectIdentifier(fixture.player.clock) == clockID)
        }

        fixture.state.path.removeLast()
        _ = try await check(fixture, destination: .artist(42), originalBar: bar, scenario: "sidebar-toggle-back-to-artist")
        expect(fixture.state.path == [.artist(42)])
        expect(markers("QieTing.MainColumn", in: fixture.host).first === main)
        expect(markers("QieTing.MainHeader", in: fixture.host).first === header)
        fixture.state.path = []
        _ = try await check(fixture, destination: nil, originalBar: bar, scenario: "sidebar-toggle-back-to-home")
        expect(markers("QieTing.MainColumn", in: fixture.host).first === main)
        expect(markers("QieTing.MainHeader", in: fixture.host).first === header)
    }

    func testCollapsedWideWindowUsesAnInsidePaneWithoutGrowingItsFrameOrMinimum() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        let bar = try await check(fixture, destination: nil, scenario: "inside-collapsed-before-resize")
        fixture.panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        fixture.window.setContentSize(NSSize(width: 1200, height: 640))
        try await wait(fixture, "1200pt collapsed window layout") {
            abs(fixture.host.bounds.width - 1200) < 0.5
                && abs(fixture.window.frame.width - 1200) < 0.5
        }
        _ = try await check(fixture, destination: nil, originalBar: bar, scenario: "inside-collapsed-wide")
        let original = fixture.window.frame
        expect(fixture.window.contentLayoutRect.width / fixture.window.contentLayoutRect.height >= 16.0 / 9.0)
        fixture.player.activePanel = .lyrics
        try await wait(fixture, "inside lyrics and actual content minimum", stableLayout: true) {
            fixture.panels.mode == .expandedInside
                && abs(fixture.window.contentMinSize.width - 1161) < 0.5
                && self.markers("QieTing.RightPanel", in: fixture.host).contains { $0.bounds.width >= 340 }
        }
        expect(fixture.panels.panelWidth == 340)
        expect(fixture.window.frame == original)
        expect(fixture.window.contentMinSize.width <= fixture.window.contentLayoutRect.width)
        _ = try await check(fixture, destination: nil, originalBar: bar, scenario: "inside-collapsed-open")
        fixture.player.activePanel = nil
        try await wait(fixture, "inside pane closes without resizing", stableLayout: true) { fixture.panels.mode == .closed }
        expect(fixture.window.frame == original)
        expect(fixture.window.contentMinSize.width == 1021)
    }

    func testHostedTeardownCancelsAnAnimatingSessionWithoutPublishingBackIntoTheGraph() async throws {
        var fixture: Fixture? = try await Fixture()
        defer { fixture?.dispose() }
        _ = try await check(try require(fixture), destination: nil, scenario: "teardown-before-animation")
        let panels = try require(fixture?.panels)
        panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        panels.animationDuration = 0.2
        let mainWidth = try requireOutsidePlan(try require(fixture), scenario: "teardown-outside-precondition")
        expect(panels.request(.lyrics, mainWidth: mainWidth))
        expect(panels.isAnimating)
        weak var releasedHost = fixture?.host
        var cleanupPublications = 0
        let observation = panels.objectWillChange.sink { _ in cleanupPublications += 1 }
        defer { observation.cancel() }
        fixture?.dispose()
        fixture = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while releasedHost != nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(releasedHost == nil, "The actual NSHostingView must be destroyed, not retained to conceal dismantle failures")
        expect(cleanupPublications == 0, "dismantle cleanup must not synchronously invalidate the SwiftUI graph being destroyed")
        expect(panels.window == nil)
        try NavigationValidationEvidence.record([
            "scenario": "hosted-teardown-no-publications", "cleanupPublications": cleanupPublications,
            "hostReleased": releasedHost == nil, "windowDetached": panels.window == nil,
        ])
        // A live coordinator subsequently attached through the configurator
        // resets its display flags; teardown itself never publishes them.
        let nextWindow = NSWindow(contentRect: CGRect(x: 0, y: 80, width: 1021, height: 640),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        nextWindow.isReleasedWhenClosed = false
        panels.attach(to: nextWindow)
        expect(cleanupPublications > 0, "A live attachment must still publish its fresh state")
        expect(!panels.isAnimating)
        expect(panels.mode == .closed && panels.panel == nil)
        expect(panels.panelWidth == 0 && panels.insideReveal == 0)
        panels.detach()
        nextWindow.close()
    }

    func testFullScreenNotificationsSuspendFrameOwnershipAndRestoreTheOutsideSession() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        _ = try await check(fixture, destination: nil, scenario: "fullscreen-notifications-before")
        fixture.panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        let mainWidth = try requireOutsidePlan(fixture, scenario: "fullscreen-outside-precondition")
        let original = fixture.window.frame
        expect(fixture.panels.request(.lyrics, mainWidth: mainWidth))
        try await wait(fixture, "outside session settles", stableLayout: true) { !fixture.panels.isAnimating }
        let expanded = fixture.window.frame
        // These exercise AppKit notification/state ownership in the real
        // hosted window. They do not create a fullscreen Space or a monitor.
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: fixture.window)
        expect(fixture.panels.mode == .expandedInside)
        expect(fixture.window.frame == expanded)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: fixture.window)
        expect(fixture.panels.isFullScreen)
        expect(fixture.window.contentMinSize.width == 1161)
        let savedClosedFrame = fixture.panels.originalFrame
        let requestedOrigin = expanded.offsetBy(dx: 15, dy: 0).origin
        // This scenario exercises a native move, not a frame resize. setFrame
        // would also ask AppKit to constrain the size against the physical CI
        // display, which our synthetic opening-plan bounds cannot enlarge.
        fixture.window.setFrameOrigin(requestedOrigin)
        var moved = snapshot(fixture, scenario: "fullscreen-native-origin-move")
        moved["requestedOrigin"] = ["x": Double(requestedOrigin.x), "y": Double(requestedOrigin.y)]
        moved["expectedUnchangedSize"] = ["width": Double(expanded.width), "height": Double(expanded.height)]
        try NavigationValidationEvidence.record(moved)
        expect(fixture.window.frame.size == expanded.size)
        expect(fixture.panels.originalFrame == savedClosedFrame)
        fixture.window.setFrameOrigin(expanded.origin)
        expect(fixture.window.frame == expanded)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: fixture.window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: fixture.window)
        expect(!fixture.panels.isFullScreen)
        expect(fixture.panels.mode == .expandedOutside)
        expect(fixture.window.contentMinSize.width == 1362)
        expect(fixture.window.frame == expanded)
        expect(abs(fixture.panels.baseContentWidth - 1021) < 0.5)
        expect(fixture.panels.request(nil, mainWidth: mainWidth))
        try await wait(fixture, "post-fullscreen outside close", stableLayout: true) { fixture.panels.mode == .closed && !fixture.panels.isAnimating }
        expect(fixture.window.frame == original)
    }

    func testNativeFullScreenTakingOverAnInFlightCloseDoesNotLeaveAnOrphanPanel() async throws {
        let fixture = try await Fixture()
        defer { fixture.dispose() }
        _ = try await check(fixture, destination: nil, scenario: "fullscreen-close-interruption-before")
        fixture.panels.visibleFrameForTesting = CGRect(x: -1000, y: -1000, width: 4000, height: 3000)
        let mainWidth = try requireOutsidePlan(fixture, scenario: "fullscreen-close-outside-precondition")
        let original = fixture.window.frame
        expect(fixture.panels.request(.queue, mainWidth: mainWidth))
        try await wait(fixture, "outside queue settles", stableLayout: true) { !fixture.panels.isAnimating }
        expect(fixture.panels.request(nil, mainWidth: mainWidth))
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: fixture.window)
        expect(fixture.panels.mode == .closed)
        expect(fixture.panels.panel == nil)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: fixture.window)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: fixture.window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: fixture.window)
        try await wait(fixture, "interrupted close restores after native ownership", stableLayout: true) {
            !fixture.panels.isAnimating && fixture.panels.mode == .closed
                && abs(fixture.window.frame.width - original.width) < 0.5
        }
        expect(fixture.window.frame == original)
    }

}
