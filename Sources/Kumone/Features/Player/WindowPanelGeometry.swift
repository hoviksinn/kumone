import CoreGraphics

enum WindowPanelMode: String {
    case closed
    case expandedOutside
    case expandedInside
}

struct WindowPanelPlan {
    let mode: WindowPanelMode
    /// The content width of the trailing pane, excluding its separator.
    let panelWidth: CGFloat
    let frame: CGRect
}

/// Screen-independent decisions for the window's one shared trailing pane.
///
/// `mainWidth` is the available middle column before opening the pane; it does
/// not include the navigation sidebar. Keep the returned plan until closing or
/// an explicit user resize, rather than reconsidering its aspect ratio after
/// the window expands.
struct WindowPanelGeometry {
    static let minimumMainWidth = PlayerLayoutMetrics.minimumMainWidth
    static let minimumPanelWidth = PlayerLayoutMetrics.minimumPanelWidth
    static let idealPanelWidth: CGFloat = 340
    static let maximumPanelWidth = PlayerLayoutMetrics.maximumPanelWidth
    static let dividerWidth = PlayerLayoutMetrics.dividerWidth

    static func openingPlan(
        frame: CGRect,
        contentSize: CGSize,
        mainWidth: CGFloat,
        visibleFrame: CGRect,
        isFullScreen: Bool
    ) -> WindowPanelPlan? {
        guard isUsable(frame), isUsable(visibleFrame),
              contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              mainWidth.isFinite, mainWidth >= minimumMainWidth
        else { return nil }

        let prefersOutside = contentSize.width / contentSize.height < 16.0 / 9.0
        if prefersOutside, !isFullScreen, frame.height <= visibleFrame.height {
            let availablePanelWidth = visibleFrame.width - frame.width - dividerWidth
            if availablePanelWidth >= minimumPanelWidth {
                let panelWidth = min(idealPanelWidth, maximumPanelWidth, availablePanelWidth)
                let expanded = CGRect(
                    x: frame.minX,
                    y: frame.minY,
                    width: frame.width + panelWidth + dividerWidth,
                    height: frame.height
                )
                return WindowPanelPlan(
                    mode: .expandedOutside,
                    panelWidth: panelWidth,
                    frame: restoredFrame(expanded, visibleFrame: visibleFrame)
                )
            }
        }

        // Wide/full-screen windows, or narrow windows on a screen without room
        // to grow, may use existing space only if the single-row player fits.
        let availablePanelWidth = mainWidth - minimumMainWidth - dividerWidth
        guard availablePanelWidth >= minimumPanelWidth else { return nil }
        return WindowPanelPlan(
            mode: .expandedInside,
            panelWidth: min(idealPanelWidth, maximumPanelWidth, availablePanelWidth),
            frame: frame
        )
    }

    /// Restore on the current screen, including after disconnecting a display.
    /// If the original frame no longer fits, keep all window controls on screen.
    /// The UI separately explains screens smaller than the app's minimum size.
    static func restoredFrame(_ original: CGRect, visibleFrame: CGRect) -> CGRect {
        guard isUsable(visibleFrame) else { return original }
        guard isUsable(original) else { return visibleFrame }
        let width = min(original.width, visibleFrame.width)
        let height = min(original.height, visibleFrame.height)
        return CGRect(
            x: min(max(original.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(original.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
