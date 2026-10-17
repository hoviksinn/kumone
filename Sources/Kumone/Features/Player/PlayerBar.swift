import SwiftUI

struct PlayerBar: View {
    var layout: PlayerBarLayout = .wide

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        barContent
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: layout.height)
            .compatGlass(interactive: true, in: barShape)
            .overlay(barShape.strokeBorder(.primary.opacity(isHovering ? 0.1 : 0.06), lineWidth: 0.5))
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : AppAnimation.quick, value: isHovering)
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: layout == .wide ? 28 : 24, style: .continuous)
    }

    @ViewBuilder
    private var barContent: some View {
        switch layout {
        case .wide:
            HStack(spacing: 12) {
                songInfoSection.frame(width: 220, alignment: .leading)
                centerSection.frame(maxWidth: .infinity)
                optionsSection(includeQuality: true)
            }
        case .stacked:
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    songInfoSection.frame(maxWidth: .infinity, alignment: .leading)
                    optionsSection(includeQuality: true)
                }
                HStack(spacing: 12) {
                    transportControls
                    ScrubberLane().frame(maxWidth: .infinity)
                }
                .opacity(player.hasCurrentTrack ? 1 : 0.5)
            }
        case .narrow:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    songInfoSection.frame(maxWidth: .infinity, alignment: .leading)
                    qualityIndicator
                }
                HStack(spacing: 8) {
                    transportControls
                    Spacer(minLength: 0)
                    optionsSection(includeQuality: false)
                }
                ScrubberLane()
                    .frame(maxWidth: .infinity)
                    .opacity(player.hasCurrentTrack ? 1 : 0.5)
            }
        }
    }

    // MARK: - Left: artwork + titles + like

    private var songInfoSection: some View {
        HStack(spacing: 10) {
            artworkButton
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    MarqueeText(text: player.currentTrack?.name ?? String(localized: "未在播放"))
                        .frame(height: 17)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                Text(player.currentTrack?.artistNames ?? "且听")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let track = player.currentTrack {
                LikeButton(trackID: track.id)
            }
        }
    }

    private var artworkButton: some View {
        Button {
            guard player.hasCurrentTrack else { return }
            withAnimation(reduceMotion ? nil : AppAnimation.smooth) {
                player.showNowPlaying = true
            }
        } label: {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .help("打开播放页")
    }

    // MARK: - Queue-order control

    /// The queue-order button cycles `listed → shuffled → autoMix`.

    private var queueOrderIcon: String {
        player.queueOrder.symbolName
    }

    private var queueOrderIsActive: Bool {
        player.queueOrder != .listed
    }

    private var queueOrderHelp: LocalizedStringKey {
        player.queueOrder.controlHelp
    }

    private func cycleQueueOrder() {
        player.cycleQueueOrder()
    }

    // MARK: - Center: transport + scrubber

    private var centerSection: some View {
        VStack(spacing: 3) {
            transportControls
            ScrubberLane()
        }
        .padding(.vertical, 5)
        .opacity(player.hasCurrentTrack ? 1 : 0.5)
    }

    private var transportControls: some View {
        HStack(spacing: 6) {
            if player.isFMMode {
                PlayerIconButton(icon: "trash", size: 12) {
                    player.fmTrash()
                }
                .help("不喜欢，换一首")
            } else {
                // One control for all three queue orders: the third state
                // is a *kind* of shuffle, so it lives inside the shuffle
                // button rather than beside it. The cycle skips it wherever
                // it could do nothing (AutoMix off, order off), which
                // leaves the familiar two-state button untouched there.
                PlayerIconButton(
                    icon: queueOrderIcon, size: 12,
                    isActive: queueOrderIsActive,
                    action: cycleQueueOrder
                )
                .help(queueOrderHelp)
            }

            PlayerIconButton(icon: "backward.fill", size: 14, disabled: player.isFMMode) {
                player.previous()
            }

            playPauseButton

            PlayerIconButton(icon: "forward.fill", size: 14) {
                player.next()
            }

            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .help("私人漫游中")
            } else {
                PlayerIconButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 12,
                    isActive: player.repeatMode != .off
                ) {
                    player.cycleRepeatMode()
                }
                .help("循环模式")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 30, height: 30)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 1)
                if player.isBuffering && player.isPlaying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 2)
        .help(player.isPlaying ? String(localized: "暂停") : String(localized: "播放"))
        .accessibilityLabel(player.isPlaying ? String(localized: "暂停") : String(localized: "播放"))
    }

    // MARK: - Right: quality / panels / volume

    @ViewBuilder
    private var qualityIndicator: some View {
        if let level = player.servedQuality,
           let quality = AudioQuality(rawValue: level) {
            QualityTag(text: quality.badge)
        } else if player.unblockSource != nil {
            QualityTag(text: String(localized: "音源"))
                .help("来自 \(player.unblockSource ?? "")")
        }
    }

    private func optionsSection(includeQuality: Bool) -> some View {
        HStack(spacing: 4) {
            if includeQuality {
                qualityIndicator
                    .padding(.trailing, 2)
            }
            PlayerIconButton(
                icon: "quote.bubble", size: 13,
                isActive: player.activePanel == .lyrics
            ) {
                player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
            }
            .help("歌词")
            PlayerIconButton(
                icon: "inset.filled.bottomthird.square", size: 13,
                isActive: settings.showDesktopLyrics
            ) {
                settings.showDesktopLyrics.toggle()
            }
            .help("桌面歌词")
            PlayerIconButton(
                icon: "list.bullet", size: 13,
                isActive: player.activePanel == .queue,
                disabled: player.isFMMode
            ) {
                player.activePanel = player.activePanel == .queue ? nil : .queue
            }
            .help("播放队列")
            RoutePickerButton(diameter: 26, glyphSize: 13,
                              tint: .secondary, background: .clear)
            VolumeControl()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Icon button

/// How the one queue-order control presents each state. Here rather than on
/// the enum itself so `QueueOrder` stays a pure Core type: three transports
/// (this bar, the now-playing page, the Dock menu) read the same two answers.
extension QueueOrder {
    /// `wand.and.stars` for AutoMix: it reads as "smart shuffle" next to the
    /// plain `shuffle` arrows, and the accent tint the button applies to any
    /// non-listed state carries the rest.
    var symbolName: String {
        switch self {
        case .listed, .shuffled: return "shuffle"
        case .autoMix: return "wand.and.stars"
        }
    }

    /// Tooltip / menu wording for the state the control is *in*.
    var controlHelp: LocalizedStringKey {
        switch self {
        case .listed, .shuffled: return "随机播放"
        case .autoMix: return "AutoMix 顺序"
        }
    }

    /// The Dock menu names all three states — it is a list of them rather than
    /// a button standing in one, so `listed` gets a word of its own.
    var menuTitle: String {
        switch self {
        case .listed: return String(localized: "列表顺序")
        case .shuffled: return String(localized: "随机播放")
        case .autoMix: return String(localized: "AutoMix 顺序")
        }
    }
}

struct PlayerIconButton: View {
    let icon: String
    var size: CGFloat = 14
    var isActive = false
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : AppAnimation.quick, value: isHovering)
        .animation(reduceMotion ? nil : AppAnimation.quick, value: isActive)
    }

    private var backgroundColor: Color {
        let base: Color = colorScheme == .dark ? .white : .black
        if isHovering, !disabled { return base.opacity(0.08) }
        if isActive { return base.opacity(0.05) }
        return .clear
    }
}

// MARK: - Like button

struct LikeButton: View {
    let trackID: Int
    var size: CGFloat = 13

    @EnvironmentObject private var account: AccountStore

    var body: some View {
        let liked = account.isLiked(trackID)
        PlayerIconButton(
            icon: liked ? "heart.fill" : "heart", size: size,
            isActive: liked
        ) {
            Task { await account.toggleLike(trackID: trackID) }
        }
        .help(liked ? String(localized: "取消喜欢") : String(localized: "喜欢"))
    }
}

// MARK: - Scrubber

struct ScrubberLane: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragProgress : clock.progress)
            track
            timeLabel(player.duration)
        }
        .frame(maxWidth: 460)
    }

    private func timeLabel(_ value: TimeInterval) -> some View {
        Text(Formatters.duration(value))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(height: 3.5)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(3.5, width * fraction), height: 3.5)
                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: width * fraction - thumbDiameter / 2)
                    .opacity(isHovering || isDragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.duration > 0 else { return }
                        isDragging = true
                        player.isScrubbing = true
                        dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                    }
                    .onEnded { _ in
                        player.seek(to: dragProgress)
                        isDragging = false
                        player.isScrubbing = false
                    }
            )
        }
        .frame(height: 14)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : AppAnimation.quick) { isHovering = hovering }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72), value: isDragging)
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 12 : (isHovering ? 10 : 8)
    }
}

// MARK: - Volume

struct VolumeControl: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showPopover = false

    var body: some View {
        PlayerIconButton(icon: volumeIcon, size: 13) {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VolumeSlider()
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
        }
        .help("音量")
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

struct VolumeSlider: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(width: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: max(4, height * CGFloat(player.volume)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        player.volume = Float(min(max(1 - value.location.y / height, 0), 1))
                    }
            )
        }
        .frame(width: 22, height: 110)
    }
}
