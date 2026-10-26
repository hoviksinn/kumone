import SwiftUI

/// Presentation only: playback and YRC timing never derive from these values.
/// Keep the metrics constant across focus changes so Japanese ruby and mixed
/// language line wrapping cannot jump when a new line starts.
enum LyricsVisualParameters {
    static let fontSize: CGFloat = 27
    static let translationSize: CGFloat = 14
    static let romajiSize: CGFloat = 13
    static let lineSpacing: CGFloat = 24
    static let annotationSpacing: CGFloat = 7
    static let horizontalPadding: CGFloat = 24
    static let followResumeDelay: Double = 3

    static let scrollAnimation = Animation.spring(response: 0.72, dampingFraction: 0.88)
    static let focusAnimation = Animation.spring(response: 0.48, dampingFraction: 0.9)

    static func opacity(distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.58
        case 2: return 0.42
        default: return 0.3
        }
    }

    static func blur(distance: Int) -> CGFloat {
        min(CGFloat(distance) * 0.55, 1.65)
    }
}
