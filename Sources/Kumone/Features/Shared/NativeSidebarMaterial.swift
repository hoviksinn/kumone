import AppKit
import SwiftUI

/// Restore the native sidebar surface previously supplied by the navigation
/// split. AppKit controls appearance, window activity and Reduce Transparency.
struct NativeSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> Background {
        let view = Background()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.identifier = NSUserInterfaceItemIdentifier("QieTing.SidebarMaterial")
        return view
    }

    func updateNSView(_ view: Background, context: Context) {}

    final class Background: NSVisualEffectView {
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
