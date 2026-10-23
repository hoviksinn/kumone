import SwiftUI

import AppKit

/// A non-interactive artwork tint layered above opaque system surfaces. The low
/// opacity keeps system materials and controls readable.
struct MainWindowAmbientBackground: View {
    let colors: ArtworkColors
    let intensity: Double

    @Environment(\.colorScheme) private var colorScheme

    private var gradientOpacity: Double {
        MainWindowAmbientOpacity.gradient(
            isDark: colorScheme == .dark,
            intensity: intensity
        )
    }

    private var glowOpacity: Double {
        MainWindowAmbientOpacity.glow(
            isDark: colorScheme == .dark,
            intensity: intensity
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(gradientOpacity)

            RadialGradient(
                colors: [colors.primary.opacity(glowOpacity), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 680
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(
            Platform.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.6),
            value: colors
        )
        .animation(
            Platform.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.6),
            value: intensity
        )
    }
}

enum MainWindowAmbientOpacity {
    static func gradient(isDark: Bool, intensity: Double) -> Double {
        (isDark ? 0.14 : 0.08) * intensity
    }

    static func glow(isDark: Bool, intensity: Double) -> Double {
        (isDark ? 0.18 : 0.12) * intensity
    }
}

/// Stable public titlebar configuration, independent of page/artwork state.
/// The real page/sidebar background extends behind native controls; no extra
/// opaque titlebar mask or system-button view manipulation is installed.
@MainActor
final class MainWindowAmbientAppearanceController {
    private var isUpdatingLayout = false

    func updateLayout(in window: NSWindow) {
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        defer { isUpdatingLayout = false }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    }
}
