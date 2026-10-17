import AppKit
import QuartzCore
import SwiftUI

/// A display link attached to the actual lyric view, rather than the main
/// display. AppKit follows the window between a ProMotion panel and external
/// displays; the callback never advances the audio clock itself.
struct LyricDisplayRefresh: NSViewRepresentable {
    let isEnabled: Bool
    let onRefresh: () -> Void

    func makeNSView(context: Context) -> RefreshView {
        let view = RefreshView()
        view.onRefresh = onRefresh
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: RefreshView, context: Context) {
        view.onRefresh = onRefresh
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: RefreshView, coordinator: ()) {
        view.stop()
    }

    final class RefreshView: NSView {
        var onRefresh: () -> Void = {}
        var isEnabled = false {
            didSet { link?.isPaused = !isEnabled }
        }

        private var link: CADisplayLink?
        private var screenObserver: NSObjectProtocol?
        private let target = WeakTarget()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            target.view = self
            let link = displayLink(target: target, selector: #selector(WeakTarget.refresh(_:)))
            self.link = link
            updateFrameRateRange()
            link.isPaused = !isEnabled
            link.add(to: .main, forMode: .common)
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrameRateRange() }
            }
        }

        func stop() {
            link?.invalidate()
            link = nil
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
                self.screenObserver = nil
            }
        }

        private func updateFrameRateRange() {
            let maximum = Float(max(30, window?.screen?.maximumFramesPerSecond ?? 120))
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        }

        deinit {
            link?.invalidate()
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        }

        // CADisplayLink retains its target. A weak proxy prevents a view/link
        // cycle, even if SwiftUI removes the view during a rapid track change.
        @MainActor
        private final class WeakTarget: NSObject {
            weak var view: RefreshView?

            @objc func refresh(_ link: CADisplayLink) {
                view?.onRefresh()
            }
        }
    }
}
