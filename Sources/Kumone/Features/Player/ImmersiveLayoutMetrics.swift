import Foundation

/// Pure presentation geometry. Transport state only scales artwork inside its
/// reserved square; it never moves the scrubber, controls or lyric document.
struct ImmersiveLayoutMetrics {
    static let pausedArtworkScale: CGFloat = 525.0 / 720.0
    static let maximumArtworkSide: CGFloat = 720
    static let controlsHeight: CGFloat = 182
    static let minimumTransportWidth: CGFloat = 276

    let size: CGSize
    let hasLyrics: Bool

    private var width: CGFloat { size.width.isFinite ? max(0, size.width) : 0 }
    private var height: CGFloat { size.height.isFinite ? max(0, size.height) : 0 }

    var verticalInset: CGFloat { min(height / 2, min(48, max(12, height * 0.04))) }
    private var availableHeight: CGFloat { max(0, height - verticalInset * 2) }
    private var availableWidth: CGFloat {
        let inset = min(width / 2, min(145, max(24, width * 0.07)))
        return min(1740, max(0, width - inset * 2))
    }

    var columnSpacing: CGFloat {
        hasLyrics ? min(188, max(40, width * 0.092), availableWidth * 0.15) : 0
    }

    var artworkSide: CGFloat {
        let preferred = hasLyrics ? max(0, availableWidth - columnSpacing) * 0.47 : availableWidth
        return max(0, min(Self.maximumArtworkSide, preferred,
                          availableHeight - Self.controlsHeight))
    }

    var lyricsWidth: CGFloat {
        hasLyrics ? max(0, availableWidth - artworkSide - columnSpacing) : 0
    }

    var bandWidth: CGFloat { artworkSide + columnSpacing + lyricsWidth }
    var lyricsHeight: CGFloat { availableHeight }
    var leftColumnHeight: CGFloat { artworkSide + Self.controlsHeight }

    /// VinylTurntableView's public size is the disc, while its tonearm stage is
    /// 48pt wider and 0.68 * 0.38 discs taller. Keep that whole stage in the slot.
    var vinylDiscSide: CGFloat {
        max(0, min(artworkSide - 48, artworkSide / (1 + 0.68 * 0.38)))
    }
}
