import AppKit
import SwiftUI

/// Apply only to a real navigation Button/NavigationLink. The modifier does
/// not add gestures or change text layout, so inline metadata keeps its
/// wrapping/truncation and the control retains native keyboard activation.
private struct NavigationTextLinkModifier: ViewModifier {
    let color: Color
    @State private var hovering = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(hovering || focused ? Theme.accent : color)
            .brightness(hovering || focused ? 0.1 : 0)
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.14), value: focused)
            .onHover { hovering = $0 }
            .pointingHandCursor()
    }
}

/// Cards already own their typography and scaling. Add the same pointer,
/// focus and brightness cues without turning their static subtitle into a
/// second destination or adding a nested button.
private struct NavigationCardLinkModifier: ViewModifier {
    @State private var hovering = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .brightness(hovering ? 0.065 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.standard)
                    .strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .onHover { hovering = $0 }
            .pointingHandCursor()
    }
}

extension View {
    func navigationTextLink(color: Color = .secondary) -> some View {
        modifier(NavigationTextLinkModifier(color: color))
    }

    func navigationCardLink() -> some View {
        modifier(NavigationCardLinkModifier())
    }

    /// AppKit owns the cursor rectangle's lifetime. No global cursor push/pop
    /// or disappearance handler can overwrite a neighbouring control's cursor.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.background {
            PointingHandCursorRegion(isEnabled: isEnabled)
                .allowsHitTesting(false)
        }
    }
}

private struct PointingHandCursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        guard view.isEnabled != isEnabled else { return }
        view.isEnabled = isEnabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var isEnabled = true

        // This view supplies cursor rectangles without intercepting the
        // Button/NavigationLink's mouse, keyboard or accessibility actions.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
    }
}
