import AppKit
import SwiftUI

/// Inert native markers let hosted regression tests inspect the actual view
/// tree. They never intercept input, own timers, or observe playback.
struct WindowChromeProbe: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ nsView: ProbeView, context: Context) {}
    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The production containers remain unchanged; tests replace only network-
/// loading leaves and turn off launch integration for this one hosted window.
struct MainWindowTestConfiguration {
    let leaf: (Destination?) -> AnyView
    let panelCoordinator: WindowPanelCoordinator
    var initialColumnVisibility: NavigationSplitViewVisibility = .detailOnly
    var liveColumnVisibility: Binding<NavigationSplitViewVisibility>?
}
