import Foundation

/// The floating player is always a single row. These are content points, not
/// screenshot pixels; admission of a trailing pane happens before layout.
struct PlayerLayoutMetrics {
    static let minimumBarWidth: CGFloat = 780
    static let maximumBarWidth: CGFloat = 880
    static let barHorizontalMargin: CGFloat = 20
    static let barBottomMargin: CGFloat = 16
    static let barHeight: CGFloat = 56
    static let minimumMainWidth: CGFloat = minimumBarWidth + barHorizontalMargin * 2
    static let minimumPanelWidth: CGFloat = 280
    static let maximumPanelWidth: CGFloat = 380
    static let dividerWidth: CGFloat = 1
    static let minimumSidebarWidth: CGFloat = 200
    static let minimumWindowWidth: CGFloat = minimumMainWidth + minimumSidebarWidth + dividerWidth
    static let minimumWindowHeight: CGFloat = 640

    static func barWidth(in mainWidth: CGFloat) -> CGFloat {
        // During an intermediate zero-size proposal preserve the controls'
        // shape. NSWindow's content minimum prevents this being a user size.
        min(maximumBarWidth, max(minimumBarWidth, mainWidth - barHorizontalMargin * 2))
    }

    static var barClearance: CGFloat { barHeight + barBottomMargin }
}

/// Kept as the presentation input for the shared bar; responsive multi-row
/// modes were removed because they distorted the transport at narrow sizes.
enum PlayerBarLayout: Equatable {
    case wide
    var height: CGFloat { PlayerLayoutMetrics.barHeight }
}
