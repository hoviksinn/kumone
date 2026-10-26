import AppKit
import CoreGraphics
import Dispatch
import SwiftUI
import Testing
@testable import KumoneCore

/// The serial queue exclusively owns the handle. The small error lock is never
/// held while creating, writing, synchronizing or printing diagnostic files.
/// In CI #55 a synchronous journal write stalled the main thread for 672ms and
/// delayed the native bounds response under measurement.
private final class NativeScrollJournalWriter: @unchecked Sendable {
    private let destination: URL
    private let queue = DispatchQueue(label: "QieTing.Tests.NativeScrollJournal", qos: .utility)
    private let errorLock = NSLock()
    private var firstError: (any Error)?
    private var handle: FileHandle?

    init(destination: URL) {
        self.destination = destination
    }

    func enqueue(_ data: Data) {
        queue.async { [self] in
            do {
                if handle == nil {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    handle = try FileHandle(forWritingTo: destination)
                }
                guard let handle else { throw CocoaError(.fileWriteUnknown) }
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try FileHandle.standardError.write(contentsOf: Data("NATIVE_SCROLL_JOURNAL ".utf8) + data)
            } catch {
                errorLock.lock()
                if firstError == nil { firstError = error }
                errorLock.unlock()
            }
        }
    }

    func currentError() -> (any Error)? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return firstError
    }

    /// Called only by scopeExit, after this test's native input measurements.
    /// A failed diagnostic write remains a test failure, never a silent pass.
    func drain() throws {
        queue.sync {}
        if let error = currentError() { throw error }
    }
}

/// Only the test's main actor reads AppKit and captures stage data/timestamps.
/// File I/O runs on the independent writer while AppKit processes the input.
/// The external watchdog reads flushed JSON and samples the recorded test PID.
@MainActor
private enum NativeScrollJournal {
    private static var writer: NativeScrollJournalWriter?
    private static var sequence = 0
    private static var activeTest: String?

    static func record(_ stage: String, details: [String: Any] = [:]) throws {
        if writer == nil {
            let root = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
                ?? FileManager.default.currentDirectoryPath
            let destination = URL(fileURLWithPath: root)
                .appendingPathComponent(".build/native-scroll-journal.jsonl")
            writer = NativeScrollJournalWriter(destination: destination)
        }
        let destination = try #require(writer)
        if let error = destination.currentError() { throw error }
        sequence += 1
        if stage == "test.begin", let name = details["test"] as? String { activeTest = name }
        var value = details
        if let activeTest { value["test"] = activeTest }
        value["sequence"] = sequence
        value["stage"] = stage
        value["testProcessID"] = ProcessInfo.processInfo.processIdentifier
        value["systemUptime"] = ProcessInfo.processInfo.systemUptime
        value["isMainThread"] = Thread.isMainThread
        value["journalDelivery"] = "serial-background-io"
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0a)
        destination.enqueue(data)
    }

    // Defers cannot throw. A journal I/O failure must still fail the test.
    static func scopeExit(_ name: String) {
        do { try record("test.scope.exit", details: ["test": name]) }
        catch { Issue.record("Could not persist native-scroll scope exit: \(error)") }
        do { try writer?.drain() }
        catch { Issue.record("Could not drain native-scroll journal: \(error)") }
    }
}

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
        let scope = "Public CG-created discrete line-based mouse-wheel input delivered to the actual native scroll view. Every fixture requires actual forward and reverse native document movement. CG-created NSEvents have no associated NSWindow; this does not establish NSApplication/WindowServer routing, physical trackpad gestures/momentum, or fading. No programmatic document/clip/knob position changes in the wheel checks."
        try JSONSerialization.data(withJSONObject: ["scope": scope, "gestures": gestures],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
        let receipt = try JSONSerialization.data(withJSONObject: gesture, options: [.sortedKeys])
        print("NATIVE_SCROLL_GESTURE " + String(decoding: receipt, as: UTF8.self))
    }
}

/// Observe completion of one real native input, rather than assuming that one
/// main-queue turn commits SwiftUI's asynchronous scroll response (CI #54).
/// This probe never lays out, displays or writes a scroll position in a bounds
/// notification. Its only timer is a strict failure deadline for the test.
@MainActor
private final class NativeWheelMotionObservation {
    struct Receipt {
        let status: String
        let elapsedSeconds: TimeInterval
        let nativeOffset: CGFloat?
        let notificationCount: Int

        var respondedWithinDeadline: Bool {
            status == "bounds-notification" && elapsedSeconds <= 0.250
        }

        var json: [String: Any] {
            var value: [String: Any] = ["status": status, "elapsedSeconds": elapsedSeconds,
                                       "responseDeadlineSeconds": 0.250,
                                       "notificationCount": notificationCount]
            if let nativeOffset { value["matchedNativeBoundsOriginX"] = nativeOffset }
            return value
        }
    }

    private let clip: NSClipView
    private let originalPostsNotifications: Bool
    private let baseline: CGFloat
    private let increasing: Bool
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var startedAt: TimeInterval?
    private var notificationCount = 0
    private var receipt: Receipt?
    private var continuation: CheckedContinuation<Receipt, Never>?

    init(clip: NSClipView, increasing: Bool) {
        self.clip = clip
        self.increasing = increasing
        baseline = clip.bounds.origin.x
        originalPostsNotifications = clip.postsBoundsChangedNotifications
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
        // Enabling this may itself post; the probe ignores notifications until
        // arm(), immediately before the actual native input call.
        clip.postsBoundsChangedNotifications = true
    }

    func arm() {
        startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.finish(status: "response-deadline-exceeded", nativeOffset: nil)
        }
    }

    private func boundsChanged() {
        guard startedAt != nil else { return }
        notificationCount += 1
        let offset = clip.bounds.origin.x
        guard increasing ? offset > baseline : offset < baseline else { return }
        finish(status: "bounds-notification", nativeOffset: offset)
    }

    private func finish(status: String, nativeOffset: CGFloat?) {
        guard case nil = receipt else { return }
        let elapsed = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let value = Receipt(status: status, elapsedSeconds: elapsed,
                            nativeOffset: nativeOffset, notificationCount: notificationCount)
        receipt = value
        timeout?.cancel()
        timeout = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: value)
    }

    func wait() async -> Receipt {
        await withTaskCancellationHandler {
            if let receipt { return receipt }
            return await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.finish(status: "cancelled", nativeOffset: nil) }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        clip.postsBoundsChangedNotifications = originalPostsNotifications
        finish(status: "closed", nativeOffset: nil)
        timeout?.cancel()
        timeout = nil
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

    private func host<V: View>(_ content: V) throws -> (NSWindow, NSHostingView<V>) {
        try NativeScrollJournal.record("swiftui-fixture.create.enter")
        _ = NSApplication.shared
        try NativeScrollJournal.record("swiftui-fixture.application.ready")
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let context: [String: Any] = ["hostWindowNumber": window.windowNumber]
        try NativeScrollJournal.record("swiftui-fixture.window.created", details: context)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content)
        try NativeScrollJournal.record("swiftui-fixture.content.enter", details: context)
        window.contentView = hosting
        try NativeScrollJournal.record("swiftui-fixture.content.return", details: context)
        try NativeScrollJournal.record("window.orderFront.enter", details: context)
        window.orderFront(nil)
        try NativeScrollJournal.record("window.orderFront.return", details: context)
        try NativeScrollJournal.record("swiftui-fixture.layout.enter", details: context)
        hosting.layoutSubtreeIfNeeded()
        try NativeScrollJournal.record("swiftui-fixture.layout.return", details: context)
        return (window, hosting)
    }

    private func close(_ window: NSWindow) {
        let context: [String: Any] = ["hostWindowNumber": window.windowNumber]
        do {
            try NativeScrollJournal.record("window.close.enter", details: context)
        } catch {
            Issue.record("Could not persist native-scroll window close entry: \(error)")
        }
        window.close()
        do {
            try NativeScrollJournal.record("window.close.return", details: context)
        } catch {
            Issue.record("Could not persist native-scroll window close return: \(error)")
        }
    }

    private func probe(in root: NSView) async throws -> NativeScrollPreferences.Probe {
        for _ in 0..<50 {
            try NativeScrollJournal.record("probe.layout.enter")
            root.layoutSubtreeIfNeeded()
            try NativeScrollJournal.record("probe.layout.return")
            try NativeScrollJournal.record("probe.query.enter")
            if let probe = descendants(root, of: NativeScrollPreferences.Probe.self).first,
               probe.enclosingScrollView != nil {
                try NativeScrollJournal.record("probe.query.ready")
                return probe
            }
            try NativeScrollJournal.record("probe.query.pending")
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("SwiftUI did not attach the native preference probe to its NSScrollView")
        throw CocoaError(.coderReadCorrupt)
    }

    private func nativeCommit(_ root: NSView, context: [String: Any] = [:]) async throws {
        try NativeScrollJournal.record("commit.enqueue", details: context)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.main.async { @MainActor in
                do {
                    try NativeScrollJournal.record("commit.main-block.enter", details: context)
                    try NativeScrollJournal.record("commit.layout.enter", details: context)
                    root.layoutSubtreeIfNeeded()
                    try NativeScrollJournal.record("commit.layout.return", details: context)
                    try NativeScrollJournal.record("commit.display.enter", details: context)
                    root.displayIfNeeded()
                    try NativeScrollJournal.record("commit.display.return", details: context)
                    try NativeScrollJournal.record("commit.continuation.resume", details: context)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try NativeScrollJournal.record("commit.await.return", details: context)
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
            try await nativeCommit(root, context: ["purpose": "horizontal-probe-readiness"])
            try NativeScrollJournal.record("horizontal-probe.query.enter")
            let matches = descendants(root, of: NativeScrollPreferences.Probe.self).filter { probe in
                guard let scroll = probe.enclosingScrollView, scroll !== old else { return false }
                return (scroll.documentView?.frame.width ?? 0) > scroll.contentSize.width + 100
            }
            try NativeScrollJournal.record("horizontal-probe.query.return", details: ["matches": matches.count])
            if matches.count == 2 { return matches }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Both real production shelves must have wide native scroll documents")
        throw CocoaError(.coderReadCorrupt)
    }

    private func scrollSnapshot(_ scroll: NSScrollView, context: [String: Any]) throws -> [String: Any] {
        try NativeScrollJournal.record("snapshot.enter", details: context)
        let value: [String: Any] = ["scrollClass": String(describing: type(of: scroll)),
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
        try NativeScrollJournal.record("snapshot.return", details: context.merging(["snapshot": value]) { _, new in new })
        return value
    }

    /// Legacy mouse wheels emit independent line-based events with neither a
    /// gesture phase nor momentum. CI #52 proved that synchronously calling a
    /// phased began enters AppKit's concurrent gesture monitor before this
    /// helper can deliver changed/ended. Exercise the supported mouse-wheel
    /// protocol instead of pretending that sequential calls form that stream.
    /// https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property
    private func horizontalWheel(in scroll: NSScrollView, window: NSWindow,
                                 scenario: String) async throws {
        let context: [String: Any] = ["scenario": scenario, "wheelProtocol": "discrete-line-mouse-wheel",
                                     "hostWindowNumber": window.windowNumber,
                                     "scrollerStyle": scroll.scrollerStyle.rawValue]
        try NativeScrollJournal.record("wheel.geometry.enter", details: context)
        let start = scroll.documentVisibleRect
        let initial = try scrollSnapshot(scroll, context: context.merging(["snapshotPurpose": "wheel-initial"]) { _, new in new })
        #expect(scroll.window === window)
        #expect((scroll.documentView?.frame.width ?? 0) > scroll.contentSize.width + 100)
        // Shelf deliberately allows its content's shadows outside the strip.
        // AppKit can therefore report the ancestor's 300pt visibleRect for a
        // 92pt clip view (CI #53). Only its intersection with the clip's own
        // bounds is an actual wheel target; the expanded midpoint hits the
        // enclosing vertical scroll view instead.
        let visible = scroll.contentView.visibleRect.intersection(scroll.contentView.bounds)
        #expect(!visible.isEmpty)
        let point = scroll.contentView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        let screen = window.convertPoint(toScreen: point)
        let root = try #require(window.contentView)
        // AppKit hitTest takes SUPERview coordinates. Passing the flipped
        // NSHostingView's own coordinates selected the other shelf (CI #54).
        // https://developer.apple.com/documentation/appkit/nsview/hittest(_:)
        let hitSpace = try #require(root.superview)
        let hitPoint = hitSpace.convert(point, from: nil)
        let hit = root.hitTest(hitPoint)
        #expect(hit?.enclosingScrollView === scroll,
                "The wheel target must be inside the actual visible native scroll view")
        try NativeScrollJournal.record("wheel.geometry.return", details: context.merging([
            "targetClipBounds": NSStringFromRect(scroll.contentView.bounds),
            "targetClipVisibleRect": NSStringFromRect(scroll.contentView.visibleRect),
            "actualTargetViewport": NSStringFromRect(visible),
            "intendedWindowPoint": NSStringFromPoint(point),
            "hitTestPointInSuperview": NSStringFromPoint(hitPoint),
            "hitTestCoordinateSpace": String(describing: type(of: hitSpace)),
            "hitViewEnclosingScrollIsTarget": hit?.enclosingScrollView === scroll,
            "commitRootClass": String(describing: type(of: root)),
        ]) { _, new in new })
        var receipts: [[String: Any]] = []
        var forwardOffset = start.origin.x
        var previousTimestamp: TimeInterval = 0
        // These are two complete discrete inputs, not begin/end fragments.
        // Their opposite signs also verify the left-edge direction assumption.
        for (direction, deltaX) in [("forward", Int32(-8)), ("reverse", Int32(8))] {
            let eventContext = context.merging(["direction": direction, "signedInputLinesX": deltaX]) { _, new in new }
            try NativeScrollJournal.record("wheel.create.enter", details: eventContext)
            let input = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                            wheelCount: 2, wheel1: 0, wheel2: deltaX, wheel3: 0))
            input.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            input.flags = []
            input.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            input.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
            input.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            input.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            #expect(input.getIntegerValueField(.scrollWheelEventDeltaAxis2) == Int64(deltaX))
            #expect(input.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
            #expect(input.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
            #expect(input.getIntegerValueField(.scrollWheelEventScrollPhase) == 0)
            #expect(input.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
            let event = try #require(NSEvent(cgEvent: input))
            #expect(event.type == .scrollWheel)
            #expect(event.modifierFlags.isEmpty)
            #expect(event.timestamp > previousTimestamp)
            previousTimestamp = event.timestamp
            #expect(event.phase.isEmpty && event.momentumPhase.isEmpty)
            #expect(!event.hasPreciseScrollingDeltas)
            #expect(event.scrollingDeltaX.isFinite && event.scrollingDeltaX != 0)
            #expect((event.scrollingDeltaX < 0) == (deltaX < 0))
            #expect(event.scrollingDeltaY == 0)
            let format: [String: Any] = [
                "eventType": event.type.rawValue, "eventTimestamp": event.timestamp,
                "modifierFlags": event.modifierFlags.rawValue,
                "eventWindowNumber": event.windowNumber, "eventHasHostWindow": event.window === window,
                "eventHasAnyWindow": event.window != nil,
                "locationInWindow": NSStringFromPoint(event.locationInWindow),
                "intendedWindowPoint": NSStringFromPoint(point), "screenPoint": NSStringFromPoint(screen),
                "hitViewClass": hit.map { String(describing: type(of: $0)) } ?? "none",
                "hitViewEnclosingScrollIsTarget": hit?.enclosingScrollView === scroll,
                "phase": event.phase.rawValue, "momentumPhase": event.momentumPhase.rawValue,
                "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                "isDirectionInvertedFromDevice": event.isDirectionInvertedFromDevice,
                "scrollingDeltaX": event.scrollingDeltaX, "scrollingDeltaY": event.scrollingDeltaY,
                "deltaX": event.deltaX, "deltaY": event.deltaY,
                "cgIsContinuous": input.getIntegerValueField(.scrollWheelEventIsContinuous),
                "cgPhase": input.getIntegerValueField(.scrollWheelEventScrollPhase),
                "cgMomentumPhase": input.getIntegerValueField(.scrollWheelEventMomentumPhase),
                "cgLineDeltaX": input.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                "cgPointDeltaX": input.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                "cgFixedDeltaX": input.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            ]
            try NativeScrollJournal.record("wheel.ready", details: eventContext.merging(format) { _, new in new })
            let before = try scrollSnapshot(scroll, context: eventContext.merging(["snapshotPurpose": "wheel-before"]) { _, new in new })
            let beforeOffset = scroll.documentVisibleRect.origin.x
            let motion = NativeWheelMotionObservation(clip: scroll.contentView,
                                                      increasing: direction == "forward")
            defer { motion.close() }
            try NativeScrollJournal.record("scrollWheel.enter", details: eventContext)
            motion.arm()
            scroll.scrollWheel(with: event)
            let immediatelyAfterInput = scroll.documentVisibleRect.origin.x
            try NativeScrollJournal.record("scrollWheel.return", details: eventContext.merging([
                "offsetImmediatelyAfterNativeInput": immediatelyAfterInput,
            ]) { _, new in new })
            // The shelf's owner is the NSHostingView, not the child native
            // scroll view. Commit that same existing queue turn at the real
            // root so pending SwiftUI layout/display participates before the
            // next input and observation. This does not wait for a duration
            // or set any scroll position.
            try await nativeCommit(root, context: eventContext.merging([
                "commitScope": "window-content-root",
                "commitRootClass": String(describing: type(of: root)),
                "commitRootIsNativeScrollTarget": root === scroll,
            ]) { _, new in new })
            let response = await motion.wait()
            try NativeScrollJournal.record("wheel.native-motion-complete", details: eventContext.merging([
                "nativeMotionResponse": response.json,
            ]) { _, new in new })
            #expect(response.respondedWithinDeadline,
                    "The real native bounds notification must confirm this input within 250ms")
            let after = try scrollSnapshot(scroll, context: eventContext.merging(["snapshotPurpose": "wheel-after"]) { _, new in new })
            let afterOffset = scroll.documentVisibleRect.origin.x
            if direction == "forward" {
                forwardOffset = afterOffset
                #expect(scroll.documentVisibleRect.origin.x > start.origin.x,
                        "The native horizontal mouse wheel must move the actual document forward")
            } else {
                #expect(scroll.documentVisibleRect.origin.x < forwardOffset,
                        "The opposite native mouse-wheel input must move the actual document back")
            }
            receipts.append(format.merging([
                "direction": direction, "signedInputLinesX": deltaX,
                "before": before, "afterNativeCommit": after,
                "actualOffsetBefore": beforeOffset, "actualOffsetAfter": afterOffset,
                "offsetImmediatelyAfterNativeInput": immediatelyAfterInput,
                "nativeMotionResponse": response.json,
                "commitScope": "window-content-root",
                "commitRootClass": String(describing: type(of: root)),
                "actualTargetViewport": NSStringFromRect(visible),
                "actualHorizontalMotion": direction == "forward" ? afterOffset > beforeOffset : afterOffset < beforeOffset,
            ]) { _, new in new })
        }
        let final = try scrollSnapshot(scroll, context: context.merging(["snapshotPurpose": "wheel-final"]) { _, new in new })
        try NativeScrollJournal.record("wheel.evidence.enter", details: context)
        try NativeScrollEvidence.record([
            "scenario": scenario, "sequence": "discrete-line-forward-and-reverse",
            "delivery": "direct NSScrollView.scrollWheel(with:) using public CG/NSEvent APIs; no NSApplication routing claim",
            "hostWindowNumber": window.windowNumber, "hostWindowFrame": NSStringFromRect(window.frame),
            "before": initial, "after": final, "events": receipts,
            "forwardOffsetX": forwardOffset,
            "actualForwardMotion": forwardOffset > start.origin.x,
            "actualReverseMotion": scroll.documentVisibleRect.origin.x < forwardOffset,
        ])
        try NativeScrollJournal.record("wheel.evidence.return", details: context)
        try NativeScrollJournal.record("wheel.return", details: context)
    }

    @Test func completeHorizontalWheelGestureMovesNativeControl() async throws {
        try NativeScrollJournal.record("test.begin", details: ["test": "completeHorizontalWheelGestureMovesNativeControl"])
        defer { NativeScrollJournal.scopeExit("completeHorizontalWheelGestureMovesNativeControl") }
        for style in [NSScroller.Style.legacy, .overlay] {
            let context: [String: Any] = ["scrollerStyle": style.rawValue,
                                         "wheelProtocol": "discrete-line-mouse-wheel",
                                         "scenario": "ordinary-native-control"]
            try NativeScrollJournal.record("native-control.create.enter", details: context)
            _ = NSApplication.shared
            try NativeScrollJournal.record("native-control.application.ready", details: context)
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            try NativeScrollJournal.record("native-control.window.created", details: context.merging(["hostWindowNumber": window.windowNumber]) { _, new in new })
            window.isReleasedWhenClosed = false
            defer { close(window) }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
            scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 3600, height: 260))
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = false
            scroll.scrollerStyle = style
            scroll.autohidesScrollers = true
            try NativeScrollJournal.record("native-control.content.enter", details: context)
            window.contentView = scroll
            try NativeScrollJournal.record("native-control.content.return", details: context)
            try NativeScrollJournal.record("window.orderFront.enter", details: context)
            window.orderFront(nil)
            try NativeScrollJournal.record("window.orderFront.return", details: context)
            try await nativeCommit(scroll, context: context.merging(["purpose": "native-control-initial"]) { _, new in new })
            try await horizontalWheel(in: scroll, window: window, scenario: "ordinary-native-control")
        }
    }

    @Test func verticalScrollViewAdoptsNativePreferenceAndRemainsScrollable() async throws {
        try NativeScrollJournal.record("test.begin", details: ["test": "verticalScrollViewAdoptsNativePreferenceAndRemainsScrollable"])
        defer { NativeScrollJournal.scopeExit("verticalScrollViewAdoptsNativePreferenceAndRemainsScrollable") }
        let (window, hosting) = try host(
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
        defer { close(window) }
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
        try NativeScrollJournal.record("test.begin", details: ["test": "liveSystemPreferenceChangesPreserveTheScrollAxes"])
        defer { NativeScrollJournal.scopeExit("liveSystemPreferenceChangesPreserveTheScrollAxes") }
        let (window, hosting) = try host(
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
        defer { close(window) }
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
        try NativeScrollJournal.record("test.begin", details: ["test": "productionShelvesNeverShowHorizontalIndicatorsUnderNativeStyles"])
        defer { NativeScrollJournal.scopeExit("productionShelvesNeverShowHorizontalIndicatorsUnderNativeStyles") }
        let (window, hosting) = try host(shelves(identity: 0))
        defer { close(window) }
        let horizontal = try await horizontalProbes(in: hosting)
        for style in [NSScroller.Style.legacy, .overlay] {
            for probe in descendants(hosting, of: NativeScrollPreferences.Probe.self) {
                probe.preferredStyle = { style }
                probe.applyPreferences()
            }
            try await nativeCommit(hosting, context: ["purpose": "production-shelf-style-change", "scrollerStyle": style.rawValue])
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
        try NativeScrollJournal.record("test.begin", details: ["test": "horizontalNeverPolicySurvivesNativeViewRecreation"])
        defer { NativeScrollJournal.scopeExit("horizontalNeverPolicySurvivesNativeViewRecreation") }
        let (window, hosting) = try host(shelves(identity: 0))
        defer { close(window) }
        let original = try await horizontalProbes(in: hosting)
        let old = try #require(original.first?.enclosingScrollView)
        hosting.rootView = shelves(identity: 1)
        let replacements = try await horizontalProbes(in: hosting, excluding: old)
        #expect(old.window == nil)
        for probe in replacements {
            let scroll = try #require(probe.enclosingScrollView)
            probe.preferredStyle = { .legacy }
            probe.applyPreferences()
            try await nativeCommit(hosting, context: ["purpose": "recreated-shelf-style-change"])
            #expect(scroll.scrollerStyle == .legacy)
            #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
            try await horizontalWheel(in: scroll, window: window, scenario: "production-shelf-recreated-native-view")
        }
    }
}
