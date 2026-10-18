import SwiftUI

/// Full-window playback content. MainWindow owns its native window chrome and
/// stable top strip; this page owns neither another toolbar nor an audio timer.
struct NowPlayingView: View {
    let onOpenDestination: (Destination) -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let metrics = ImmersiveLayoutMetrics(size: geometry.size, hasLyrics: hasLyricsColumn)
            ZStack {
                backdrop
                HStack(spacing: metrics.columnSpacing) {
                    leftColumn(metrics: metrics)
                        .frame(width: metrics.artworkSide)
                    if hasLyricsColumn {
                        LyricsPanel(presentation: .immersive)
                            .frame(width: metrics.lyricsWidth, height: metrics.lyricsHeight)
                            .accessibilityIdentifier("immersiveLyrics")
                    }
                }
                .frame(width: metrics.bandWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(.dark)
        .onExitCommand { player.showNowPlaying = false }
        .accessibilityIdentifier("immersivePlayer")
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // Reserve the lyric column while loading.
    }

    private var artworkImage: PlatformImage? { artworkStore.artwork }
    private var colors: ArtworkColors { artworkStore.colors }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [colors.primary, colors.secondary],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.12), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.clear, .black.opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: colors)
    }

    private func leftColumn(metrics: ImmersiveLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            artworkSlot(metrics: metrics)
                .padding(.bottom, 20)
            metadata
                .frame(height: 48)
                .padding(.bottom, 14)
            NowPlayingScrubber()
                .frame(height: 30)
                .padding(.bottom, 12)
            controls
                .frame(height: 58)
        }
        .frame(width: metrics.artworkSide)
        .accessibilityIdentifier("immersiveControlsColumn")
    }

    private func artworkSlot(metrics: ImmersiveLayoutMetrics) -> some View {
        ZStack {
            if settings.nowPlayingMode == .vinyl {
                VinylTurntableView(
                    artworkImage: artworkImage,
                    isPlaying: player.isPlaying,
                    trackId: player.currentTrack?.id,
                    size: metrics.vinylDiscSide,
                    onTap: { player.togglePlayPause() },
                    onNextTrack: { player.next() },
                    onPreviousTrack: { player.previous() }
                )
                .accessibilityIdentifier("vinylTurntable")
            } else {
                artworkView(size: metrics.artworkSide)
            }
        }
        .frame(width: metrics.artworkSide, height: metrics.artworkSide)
        .scaleEffect(player.isPlaying ? 1 : ImmersiveLayoutMetrics.pausedArtworkScale)
        .animation(reduceMotion ? .easeInOut(duration: 0.15)
                   : .spring(response: 0.5, dampingFraction: 0.92), value: player.isPlaying)
        // This outer slot remains identical when the artwork scales within it.
        .frame(width: metrics.artworkSide, height: metrics.artworkSide)
        .accessibilityIdentifier("immersiveArtworkSlot")
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        if let album = player.currentTrack?.album, album.id > 0, !album.name.isEmpty {
            Button { onOpenDestination(.album(album.id)) } label: {
                artworkSurface(size: size)
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .accessibilityLabel("打开专辑：\(album.name)")
        } else {
            artworkSurface(size: size)
        }
    }

    private func artworkSurface(size: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                }
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
        .animation(.easeIn(duration: 0.25), value: artworkImage != nil)
    }

    private var metadata: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 { VIPBadge() }
                }
                if let track = player.currentTrack {
                    NowPlayingTrackDestinationLinks(
                        track: track, font: .system(size: 13),
                        color: .white.opacity(0.68), onOpenDestination: onOpenDestination
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            HStack(spacing: 4) {
                if let track = player.currentTrack {
                    let liked = account.isLiked(track.id)
                    circleButton(icon: liked ? "heart.fill" : "heart", size: 14,
                                 diameter: 32, tint: liked ? Theme.accent : nil) {
                        Task { await account.toggleLike(trackID: track.id) }
                    }
                    .help(liked ? "取消喜欢" : "喜欢")
                }
                moreMenu
                RoutePickerButton(diameter: 32, glyphSize: 14)
            }
            .fixedSize()
        }
    }

    private var moreMenu: some View {
        Menu {
            if let track = player.currentTrack {
                ForEach(track.artists.filter { $0.id > 0 && !$0.name.isEmpty }) { artist in
                    Button("打开歌手：\(artist.name)") { onOpenDestination(.artist(artist.id)) }
                }
                if track.album.id > 0, !track.album.name.isEmpty {
                    Button("打开专辑：\(track.album.name)") { onOpenDestination(.album(track.album.id)) }
                }
                Divider()
            }
            Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.1), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .help("更多播放操作")
        .accessibilityLabel("更多播放操作")
    }

    /// Fixed hit targets and spacing, with play at the center of the component.
    /// Queue order still exposes listed / shuffled / AutoMix on the same control.
    private var controls: some View {
        HStack(spacing: 18) {
            if player.isFMMode {
                circleButton(icon: "trash", size: 15, diameter: 32) { player.fmTrash() }
                    .help("不再播放这首歌")
            } else {
                circleButton(icon: player.queueOrder.symbolName, size: 15, diameter: 32,
                             tint: player.queueOrder != .listed ? Theme.accent : nil) {
                    player.cycleQueueOrder()
                }
                .help("播放顺序（包括 AutoMix）")
            }
            circleButton(icon: "backward.fill", size: 22, diameter: 40) { player.previous() }
                .disabled(player.isFMMode)
                .opacity(player.isFMMode ? 0.3 : 1)
                .help("上一首")
            playPauseButton
            circleButton(icon: "forward.fill", size: 22, diameter: 40) { player.next() }
                .help("下一首")
            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
            } else {
                circleButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 15,
                             diameter: 32, tint: player.repeatMode != .off ? Theme.accent : nil) {
                    player.cycleRepeatMode()
                }
                .help("循环模式")
            }
        }
        .fixedSize()
    }

    private var playPauseButton: some View {
        Button { player.togglePlayPause() } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                if player.isBuffering && player.isPlaying {
                    ProgressView().controlSize(.small).tint(.black.opacity(0.8))
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .contentTransition(.opacity)
                }
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.pressable)
        .help(player.isPlaying ? "暂停" : "播放")
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }

    private func circleButton(icon: String, size: CGFloat, diameter: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
    }
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
///
/// Whether the line carries furigana is `LyricText`'s decision; the wipe is
/// handed down as per-character opacity so it reads the same either way.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    let weight: Font.Weight
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45

    var body: some View {
        if isActive, verbatim, line.words?.isEmpty == false {
            LyricPlaybackText(
                line: line, isActive: true, size: size, weight: weight,
                color: .white, verbatim: true
            )
        } else {
            LyricText(
                line: line, size: size, weight: weight,
                color: .white.opacity(isActive ? 1 : inactiveOpacity)
            )
        }
    }

    /// One opacity per character of `line.text`: sung characters are bright,
    /// the current one fades in, unsung stay dim.
    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        LyricHighlightTiming.alphas(for: line, words: words, at: time)
    }
}



// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        NowPlayingScrubberRenderer(player: player, clock: player.clock)
    }
}

/// Only this small subtree observes the continuously advancing media clock.
private struct NowPlayingScrubberRenderer: View {
    let player: PlayerService
    @ObservedObject var clock: PlaybackClock

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - thumbDiameter / 2)
                        .opacity(isHovering || isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0, width > 0 else { return }
                            isDragging = true
                            player.isScrubbing = true
                            dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                        }
                        .onEnded { _ in
                            guard isDragging else { return }
                            player.seek(to: dragProgress)
                            isDragging = false
                            player.isScrubbing = false
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(AppAnimation.quick) { isHovering = hovering }
            }

            HStack {
                Text(Formatters.duration(isDragging ? dragProgress : clock.progress))
                Spacer()
                Text(Formatters.duration(player.duration))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .onDisappear {
            if isDragging { player.isScrubbing = false }
        }
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 13 : (isHovering ? 11 : 9)
    }
}
