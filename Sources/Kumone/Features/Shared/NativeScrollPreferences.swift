import AppKit
import SwiftUI

/// Leave thumb drawing, fading and dragging to AppKit. In particular, the
/// system's Always setting must keep its native legacy scroller style.
struct NativeScrollPreferences: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.applyPreferences() }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.stopObserving()
    }

    final class Probe: NSView {
        // Injectable for native policy tests; production always reads AppKit.
        var preferredStyle: () -> NSScroller.Style = { NSScroller.preferredScrollerStyle }
        private var styleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPreferences() }
            }
            DispatchQueue.main.async { [weak self] in self?.applyPreferences() }
        }

        func applyPreferences() {
            guard let scrollView = enclosingScrollView else { return }
            let style = preferredStyle()
            if scrollView.scrollerStyle != style { scrollView.scrollerStyle = style }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
            // autohidesScrollers removes an unneeded legacy bar when content
            // fits; it does not fade an overflowing legacy bar on idle. Native
            // overlay timing belongs to AppKit, while Always stays legacy.
            // Keep the containing ScrollView's enabled axes. Do not enable a
            // horizontal scrollbar on a vertical lyric document, or flash a
            // thumb every time automatic lyric following scrolls the view.
        }

        func stopObserving() {
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
                self.styleObserver = nil
            }
        }

        deinit {
            if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
        }
    }
}
