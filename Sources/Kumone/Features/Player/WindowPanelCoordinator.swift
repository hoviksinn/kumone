import AppKit
import SwiftUI

/// Owns one open-panel session. Its mode is selected only when opening; lyrics
/// and queue substitutions never resize the window or start another session.
@MainActor
final class WindowPanelCoordinator: ObservableObject {
    @Published private(set) var mode: WindowPanelMode = .closed
    @Published private(set) var panel: RightPanel?
    @Published private(set) var panelWidth: CGFloat = 0
    @Published private(set) var insideReveal: CGFloat = 0
    @Published private(set) var baseContentWidth: CGFloat = 0
    @Published private(set) var isFullScreen = false
    @Published private(set) var isAnimating = false
    @Published var insufficientSpace = false
    private(set) var originalFrame: CGRect?
    private(set) weak var window: NSWindow?
    private var isClosing = false
    private var sessionWasOutside = false
    private var restorationAfterFullScreen: CGRect?
    private var generation = 0
    private var programmaticFrame = false
    private var nativeFullScreenTransition = false
    private var deferredRequest: (panel: RightPanel?, sidebarWidth: CGFloat)?
    private var sidebarWidthAtOpen: CGFloat = 0
    private var observerTokens: [NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    private var lastStableFrame: CGRect?
    var reduceMotion = false
    /// Geometry injection is used only by hosted tests on small CI displays.
    var visibleFrameForTesting: CGRect?
    var animationDuration: TimeInterval = 0.3
    var addedWidth: CGFloat { panelWidth + PlayerLayoutMetrics.dividerWidth }
    var hasPanel: Bool { mode != .closed }
    var declarativeMinimumContentWidth: CGFloat {
        // AppKit owns outside frame interpolation. A final-width SwiftUI
        // minimum during opening would resize the window before that tween.
        if mode == .expandedOutside, isAnimating {
            return PlayerLayoutMetrics.minimumWindowWidth
        }
        return minimumContentWidth
    }
    var minimumContentWidth: CGFloat {
        guard hasPanel, !isClosing else { return PlayerLayoutMetrics.minimumWindowWidth }
        let minimumNavigationWidth = sidebarWidthAtOpen + PlayerLayoutMetrics.minimumMainWidth
        if mode == .expandedOutside {
            // Outside layout preserves a complete closed-window base while
            // the user resizes. Its saved closed frame shares the same floor.
            return max(PlayerLayoutMetrics.minimumWindowWidth, minimumNavigationWidth) + addedWidth
        }
        // An inside pane can share a wide collapsed-sidebar window without
        // reserving the hidden sidebar's width a second time.
        return max(PlayerLayoutMetrics.minimumWindowWidth, minimumNavigationWidth + addedWidth)
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        // Attachment is invoked by the configurator's asynchronous main-queue
        // callback, after SwiftUI has committed its native view. A coordinator
        // reused for another window must not carry an old display session.
        mode = .closed
        panel = nil
        panelWidth = 0
        insideReveal = 0
        baseContentWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
        isAnimating = false
        isFullScreen = window.styleMask.contains(.fullScreen)
        insufficientSpace = false
        isClosing = false
        sessionWasOutside = false
        originalFrame = nil
        restorationAfterFullScreen = nil
        sidebarWidthAtOpen = 0
        window.collectionBehavior.insert(.fullScreenPrimary)
        applyMinimum()
        lastStableFrame = window.frame
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observerTokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.windowChanged(note.name) }
            })
        }
        observerTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        })
    }

    func detach() {
        generation += 1
        hideTask?.cancel()
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
        programmaticFrame = false
        nativeFullScreenTransition = false
        deferredRequest = nil
        window = nil
        // Do not publish display state here. SwiftUI calls this method from
        // dismantleNSView while GraphHost.invalidate holds exclusive access;
        // a synchronous @Published setter reenters that same graph and aborts.
        // The next normal attach resets display flags outside graph teardown.
    }

    func request(_ requested: RightPanel?, mainWidth: CGFloat) -> Bool {
        guard let window else { return requested == nil }
        // A content-only substitution must not restart/retarget an in-flight
        // window animation or invalidate its completion generation.
        if let requested, hasPanel, !isClosing { panel = requested; return true }
        if nativeFullScreenTransition {
            // Keep the latest user intent, but let AppKit finish owning the
            // frame before admitting/closing a pane against its new bounds.
            let contentWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
            let navigationWidth = mode == .expandedOutside ? baseContentWidth : contentWidth - insideReveal
            deferredRequest = (requested, max(0, navigationWidth - mainWidth))
            return true
        }
        generation += 1
        let requestGeneration = generation
        hideTask?.cancel()
        if let requested {
            isClosing = false
            if hasPanel {
                panel = requested
                if mode == .expandedInside { insideReveal = addedWidth }
                else if let originalFrame {
                    let target = outsideFrame(from: originalFrame)
                    animateWindow(to: target, generation: requestGeneration)
                }
                return true
            }
            guard let visible = visibleFrame,
                  let plan = WindowPanelGeometry.openingPlan(
                    frame: window.frame, contentSize: window.contentLayoutRect.size,
                    mainWidth: mainWidth, visibleFrame: visible,
                    isFullScreen: isFullScreen || window.styleMask.contains(.fullScreen)) else {
                insufficientSpace = true
                return false
            }
            originalFrame = window.frame
            baseContentWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
            sidebarWidthAtOpen = max(0, baseContentWidth - mainWidth)
            panelWidth = plan.panelWidth
            panel = requested
            if plan.mode == .expandedOutside { isAnimating = true }
            mode = plan.mode
            sessionWasOutside = plan.mode == .expandedOutside
            if mode == .expandedOutside {
                animateWindow(to: plan.frame, generation: requestGeneration)
            } else {
                insideReveal = addedWidth
                applyMinimum()
            }
            return true
        }
        guard hasPanel else { return true }
        isClosing = true
        if sessionWasOutside, let originalFrame, let visible = visibleFrame,
           !isFullScreen, !window.styleMask.contains(.fullScreen) {
            mode = .expandedOutside
            // Lower the constraint before shrinking; never change it merely
            // because the ordinary/immersive page changes.
            applyMinimum()
            animateWindow(to: WindowPanelGeometry.restoredFrame(originalFrame, visibleFrame: visible),
                          generation: requestGeneration, closes: true)
        } else {
            if sessionWasOutside, isFullScreen || window.styleMask.contains(.fullScreen) { restorationAfterFullScreen = originalFrame }
            insideReveal = 0
            hideTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.reduceMotion { try? await Task.sleep(for: .seconds(self.animationDuration)) }
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                self.finishClose()
            }
        }
        return true
    }

    private var visibleFrame: CGRect? {
        visibleFrameForTesting ?? window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    private func outsideFrame(from original: CGRect) -> CGRect {
        guard let visible = visibleFrame else { return original }
        var target = original
        target.size.width += addedWidth
        return WindowPanelGeometry.restoredFrame(target, visibleFrame: visible)
    }

    private func animateWindow(to frame: CGRect, generation expected: Int, closes: Bool = false) {
        guard let window else { return }
        programmaticFrame = true
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                self.programmaticFrame = false
                self.isAnimating = false
                self.lastStableFrame = self.window?.frame
                if closes { self.finishClose() } else { self.applyMinimum() }
                self.applyDeferredRequest()
            }
        }
    }

    private func finishClose() {
        mode = .closed
        panel = nil
        panelWidth = 0
        insideReveal = 0
        originalFrame = nil
        isClosing = false
        sessionWasOutside = false
        isAnimating = false
        applyMinimum()
    }

    private func applyMinimum() {
        guard let window else { return }
        // Full-size content views include native titlebar/toolbar space in
        // contentMinSize. Reserve 640pt for usable content, not for chrome.
        let nativeContentHeight = window.contentRect(forFrameRect: window.frame).height
        let chromeHeight = max(0, nativeContentHeight - window.contentLayoutRect.height)
        let size = NSSize(width: minimumContentWidth,
                          height: PlayerLayoutMetrics.minimumWindowHeight + chromeHeight)
        if window.contentMinSize != size { window.contentMinSize = size }
    }

    private func windowChanged(_ name: Notification.Name) {
        guard let window else { return }
        if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
            nativeFullScreenTransition = true
            generation += 1
            hideTask?.cancel()
            if isAnimating {
                // Supersede our own frame tween at its current value before
                // AppKit takes ownership. Do not calculate a full-screen frame.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    window.animator().setFrame(window.frame, display: true)
                }
            }
            programmaticFrame = false
            isAnimating = false
            if isClosing {
                // A native transition supersedes the close tween as well.
                // Do not leave a retired panel mounted after cancelling its
                // completion, or apply a saved frame during a Space change.
                if sessionWasOutside { restorationAfterFullScreen = originalFrame }
                finishClose()
            } else if name == NSWindow.willEnterFullScreenNotification, hasPanel {
                mode = .expandedInside
                insideReveal = addedWidth
            }
            return
        }
        if name == NSWindow.didEnterFullScreenNotification {
            nativeFullScreenTransition = false
            isFullScreen = true
            if hasPanel {
                if window.contentLayoutRect.width - sidebarWidthAtOpen - addedWidth < PlayerLayoutMetrics.minimumMainWidth {
                    // A smaller full-screen display must never squash controls.
                    // AppKit owns the frame; retire only the inspector region.
                    if sessionWasOutside { restorationAfterFullScreen = originalFrame }
                    finishClose()
                    insufficientSpace = true
                } else { mode = .expandedInside; insideReveal = addedWidth }
            }
            lastStableFrame = window.frame
            applyMinimum()
            applyDeferredRequest()
            return
        }
        if name == NSWindow.didExitFullScreenNotification {
            nativeFullScreenTransition = false
            isFullScreen = false
            lastStableFrame = window.frame
            // The native transition has finished. A pane closed while in
            // full-screen restores its pre-expansion frame only now.
            if let restore = restorationAfterFullScreen, let visible = visibleFrame {
                restorationAfterFullScreen = nil
                generation += 1
                animateWindow(to: WindowPanelGeometry.restoredFrame(restore, visibleFrame: visible), generation: generation)
            } else {
                if hasPanel, sessionWasOutside {
                    // AppKit restores the expanded ordinary frame. Return to
                    // that session's outside geometry so the middle column
                    // retains its pre-panel width instead of shrinking twice.
                    mode = .expandedOutside
                    insideReveal = 0
                    baseContentWidth = max(PlayerLayoutMetrics.minimumWindowWidth,
                        (window.contentView?.bounds.width ?? window.contentLayoutRect.width) - addedWidth)
                }
                applyMinimum()
                screenChanged()
                if !isAnimating { applyDeferredRequest() }
            }
            return
        }
        guard !programmaticFrame, !nativeFullScreenTransition,
              !isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        if sessionWasOutside, hasPanel, var original = originalFrame,
           let old = lastStableFrame {
            // User moves/re-sizes rebase the saved closed frame once, instead
            // of letting a later close jump back to an obsolete position.
            original.origin.x += window.frame.minX - old.minX
            original.origin.y += window.frame.minY - old.minY
            original.size.width = max(PlayerLayoutMetrics.minimumWindowWidth,
                                      window.frame.width - addedWidth)
            original.size.height = window.frame.height
            originalFrame = original
            baseContentWidth = max(PlayerLayoutMetrics.minimumWindowWidth,
                                   (window.contentView?.bounds.width ?? window.contentLayoutRect.width) - addedWidth)
        }
        lastStableFrame = window.frame
        if name == NSWindow.didChangeScreenNotification { screenChanged() }
    }

    private func applyDeferredRequest() {
        guard !nativeFullScreenTransition, let deferredRequest, let window else { return }
        self.deferredRequest = nil
        let mainWidth = (window.contentView?.bounds.width ?? window.contentLayoutRect.width) - deferredRequest.sidebarWidth
        _ = request(deferredRequest.panel, mainWidth: mainWidth)
    }

    private func screenChanged() {
        guard let window, let visible = visibleFrame,
              !isFullScreen, !nativeFullScreenTransition,
              !window.styleMask.contains(.fullScreen), !programmaticFrame else { return }
        let clamped = WindowPanelGeometry.restoredFrame(window.frame, visibleFrame: visible)
        if clamped.width + 0.5 < window.frame.width, hasPanel {
            // A smaller display cannot carry this session safely. Close the
            // pane and explain the constraint, preserving all controls.
            insufficientSpace = true
            _ = request(nil, mainWidth: 0)
        } else if clamped != window.frame {
            generation += 1
            animateWindow(to: clamped, generation: generation)
        }
    }
}
