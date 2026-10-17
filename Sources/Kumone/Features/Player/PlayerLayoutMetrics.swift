import Foundation

/// Geometry shared by the content column, its floating controls and the trailing
/// inspector. The inspector is part of layout: it never covers the song list.
struct PlayerLayoutMetrics {
    static let maximumBarWidth: CGFloat = 880
    static let barHorizontalMargin: CGFloat = 20
    static let barBottomMargin: CGFloat = 16
    static let minimumMainWidth: CGFloat = 440
    static let minimumPanelWidth: CGFloat = 280
    static let maximumPanelWidth: CGFloat = 380
    static let dividerWidth: CGFloat = 1

    let detailWidth: CGFloat
    let showsPanel: Bool

    var panelWidth: CGFloat {
        guard showsPanel else { return 0 }
        let desired = min(Self.maximumPanelWidth,
                          max(Self.minimumPanelWidth, detailWidth * 0.32))
        // During initial layout and live resizing SwiftUI can briefly propose
        // less than the window's supported minimum. Never produce a negative
        // width or squeeze the main content below its usable control width.
        return min(desired, max(0, detailWidth - Self.minimumMainWidth - Self.dividerWidth))
    }

    var mainWidth: CGFloat {
        max(0, detailWidth - panelWidth - (showsPanel ? Self.dividerWidth : 0))
    }

    var barWidth: CGFloat {
        min(Self.maximumBarWidth, max(0, mainWidth - Self.barHorizontalMargin * 2))
    }

    var barLayout: PlayerBarLayout { PlayerBarLayout(width: barWidth) }
    var barClearance: CGFloat { barLayout.height + Self.barBottomMargin }
}

/// Preserve every control at narrow sizes by reflowing instead of hiding it.
enum PlayerBarLayout: Equatable {
    case wide, stacked, narrow

    init(width: CGFloat) {
        if width >= 780 { self = .wide }
        else if width >= 560 { self = .stacked }
        else { self = .narrow }
    }

    var height: CGFloat {
        switch self {
        case .wide: return 56
        case .stacked: return 96
        case .narrow: return 112
        }
    }
}
