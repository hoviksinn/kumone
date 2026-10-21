import AppKit
import SwiftUI

/// The window owns the trailing column. This view fills that column instead
/// of placing a second floating card over the library.
enum LyricsPanelPresentation: Equatable {
    case standard, immersive

    var fontScale: CGFloat { self == .immersive ? 1.22 : 1 }
    var lineSpacing: CGFloat { LyricsVisualParameters.lineSpacing * fontScale }
    var horizontalPadding: CGFloat { self == .immersive ? 28 : LyricsVisualParameters.horizontalPadding }
}

/// Read-only bounds of actual lyric components. The application installs no
/// reader; tests resolve these public anchors without changing scrolling or
/// observing the audio clock. No native row view or publisher is added.
enum LyricsViewportElement: Hashable {
    case line(id: Int, text: String)
    case followPlayback
}

struct LyricsViewportAnchorKey: PreferenceKey {
    typealias Value = [LyricsViewportElement: Anchor<CGRect>]
    static var defaultValue: Value { [:] }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct LyricsFocusState: Equatable {
    let index: Int?
    let seekRevision: UInt64
}

struct LyricsPanel: View {
    var presentation: LyricsPanelPresentation = .standard
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        LyricsPanelContent(presentation: presentation, lyricsCursor: player.lyricsCursor)
    }
}

/// The presentation modes share focus, real media time, scrolling and ruby
/// layout. Only glyph sizes and spacing differ in the larger immersive column.
private struct LyricsPanelContent: View {
    let presentation: LyricsPanelPresentation
    @EnvironmentObject private var player: PlayerService
    @ObservedObject var lyricsCursor: LyricsCursor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.primary.opacity(presentation == .immersive ? 0 : 0.025))
            .onDisappear { resumeTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: presentation.lineSpacing) {
                            ForEach(lyrics.lines) { line in
                                LyricsPanelLine(
                                    line: line,
                                    activeIndex: activeIndex,
                                    presentation: presentation,
                                    onSeek: { player.seek(to: line.time) }
                                )
                                .anchorPreference(key: LyricsViewportAnchorKey.self, value: .bounds) { anchor in
                                    [.line(id: line.id, text: line.text): anchor]
                                }
                                .id(line.id)
                            }
                        }
                        .padding(.horizontal, presentation.horizontalPadding)
                        // Keep large decorative insets out of the lazy row
                        // height estimate used for off-screen ID scrolling.
                        // The extra spacing preserves the former gap between
                        // each inset and its adjacent real lyric row.
                        .padding(.top, geometry.size.height * 0.38 + presentation.lineSpacing)
                        .padding(.bottom, geometry.size.height * 0.48 + presentation.lineSpacing)
                        .background(NativeScrollPreferences().frame(width: 0, height: 0))
                    }
                    // NSScrollView supplies overlay scrollers and their fade
                    // timing. Respect the user's "Always" system preference.
                    .scrollIndicators(.automatic)
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting:
                            isUserScrolling = true
                            resumeTask?.cancel()
                        case .idle where isUserScrolling:
                            scheduleResume(proxy: proxy)
                        default:
                            break // Programmatic .animating is not user input.
                        }
                    }
                    .onChange(of: LyricsFocusState(index: lyricsCursor.activeIndex,
                                                  seekRevision: lyricsCursor.seekRevision)) { previous, current in
                        // A single observation keeps an explicit seek from
                        // racing the ordinary next-line spring in this commit.
                        if previous.seekRevision != current.seekRevision {
                            adoptCursor(proxy: proxy)
                            return
                        }
                        activeIndex = current.index
                        guard !isUserScrolling, let index = current.index else { return }
                        scroll(to: index, proxy: proxy, animated: true)
                    }
                    .onChange(of: player.currentTrack?.id) { _, _ in
                        resumeTask?.cancel()
                        isUserScrolling = false
                        activeIndex = nil
                    }
                    .onChange(of: lyrics) { _, _ in
                        adoptCursor(proxy: proxy)
                    }
                    .onAppear { adoptCursor(proxy: proxy) }
                    .overlay(alignment: .bottom) {
                        if isUserScrolling {
                            Button {
                                resumeFollowing(proxy: proxy)
                            } label: {
                                Label("跟随播放", systemImage: "arrow.down.to.line.compact")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .background(.regularMaterial, in: Capsule())
                            .anchorPreference(key: LyricsViewportAnchorKey.self, value: .bounds) { anchor in
                                [.followPlayback: anchor]
                            }
                            .padding(.bottom, 20)
                            .transition(.opacity)
                        }
                    }
                }
            }
        } else if player.lyrics?.isInstrumental == true {
            EmptyStateView(icon: "music.quarternote.3", title: "纯音乐", subtitle: "请欣赏")
        } else if player.hasCurrentTrack {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("歌词加载中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(icon: "quote.bubble", title: "暂无歌词")
        }
    }

    private func adoptCursor(proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        isUserScrolling = false
        activeIndex = lyricsCursor.activeIndex
        let trackID = player.currentTrack?.id
        let seekRevision = lyricsCursor.seekRevision
        // ScrollViewReader needs a laid-out document. Re-read the cursor in
        // the deferred turn, rather than applying a stale pre-seek position.
        DispatchQueue.main.async {
            guard player.currentTrack?.id == trackID,
                  lyricsCursor.seekRevision == seekRevision,
                  let index = lyricsCursor.activeIndex else { return }
            activeIndex = index
            scroll(to: index, proxy: proxy, animated: false)
        }
    }

    private func scheduleResume(proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(LyricsVisualParameters.followResumeDelay))
            } catch { return }
            resumeFollowing(proxy: proxy)
        }
    }

    private func resumeFollowing(proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        isUserScrolling = false
        guard let index = lyricsCursor.activeIndex else { return }
        activeIndex = index
        scroll(to: index, proxy: proxy, animated: true)
    }

    private func scroll(to index: Int, proxy: ScrollViewProxy, animated: Bool) {
        if animated, !reduceMotion {
            withAnimation(LyricsVisualParameters.scrollAnimation) {
                proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.42))
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.42))
            }
        }
    }
}

private struct LyricsPanelLine: View {
    let line: LyricLine
    let activeIndex: Int?
    let presentation: LyricsPanelPresentation
    let onSeek: () -> Void

    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isActive: Bool { line.id == activeIndex }
    private var distance: Int { activeIndex.map { abs(line.id - $0) } ?? 2 }

    var body: some View {
        let visualOpacity = isHovering ? 1 : LyricsVisualParameters.opacity(distance: distance)
        let visualBlur: CGFloat = isHovering || reduceMotion ? 0 : LyricsVisualParameters.blur(distance: distance)
        let visualScale: CGFloat = isActive || reduceMotion ? 1 : 0.97
        let visualOffset: CGFloat = isActive || reduceMotion ? 0 : (line.id < (activeIndex ?? 0) ? -2 : 2)

        Button(action: onSeek) {
            VStack(alignment: .leading, spacing: LyricsVisualParameters.annotationSpacing) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: LyricsVisualParameters.romajiSize * presentation.fontScale, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.72))
                }
                // Font metrics and ruby geometry stay identical when focus
                // moves. Depth/scale are rendering effects, never reflow.
                LyricPlaybackText(
                    line: line,
                    isActive: isActive,
                    size: LyricsVisualParameters.fontSize * presentation.fontScale,
                    weight: .bold,
                    color: .primary,
                    verbatim: settings.verbatimLyrics
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: LyricsVisualParameters.translationSize * presentation.fontScale, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.66))
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .visualEffect { content, _ in
                content
                    .opacity(visualOpacity)
                    .blur(radius: visualBlur)
                    .scaleEffect(visualScale, anchor: .leading)
                    .offset(y: visualOffset)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint("从这一句开始播放")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : LyricsVisualParameters.focusAnimation, value: activeIndex)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}
