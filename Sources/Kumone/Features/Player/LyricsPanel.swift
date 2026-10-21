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

// An optional, read-only test observer; the app installs no callback. Position
// ownership remains in this view and never feeds back into the media clock.
typealias LyricsScrollDiagnostics = @MainActor (String, Bool, Bool, UInt64) -> Void
private struct LyricsScrollDiagnosticsKey: EnvironmentKey {
    static var defaultValue: LyricsScrollDiagnostics? { nil }
}
extension EnvironmentValues {
    var lyricsScrollDiagnostics: LyricsScrollDiagnostics? {
        get { self[LyricsScrollDiagnosticsKey.self] }
        set { self[LyricsScrollDiagnosticsKey.self] = newValue }
    }
}

/// No Observable/Published state: cancellation during view teardown must not
/// publish back into the SwiftUI graph being removed.
private final class LyricsScrollRequests {
    var generation: UInt64 = 0
    var pendingReconciliation: UInt64?
    var isAttached = false

    func invalidate() {
        generation &+= 1
        pendingReconciliation = nil
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
    @Environment(\.lyricsScrollDiagnostics) private var scrollDiagnostics

    @State private var activeIndex: Int?
    // Keep the semantic target in the native scroll coordinator rather than
    // issuing a one-shot proxy request that can race pending wheel updates.
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var scrollRequests = LyricsScrollRequests()
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.primary.opacity(presentation == .immersive ? 0 : 0.025))
            .onDisappear {
                resumeTask?.cancel()
                scrollRequests.isAttached = false
                scrollRequests.invalidate()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            GeometryReader { geometry in
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
                    .scrollTargetLayout()
                    .padding(.horizontal, presentation.horizontalPadding)
                    // Keep large decorative insets out of the lazy row
                    // height estimate used for off-screen ID scrolling.
                    // The extra spacing preserves the former gap between
                    // each inset and its adjacent real lyric row.
                    .padding(.top, geometry.size.height * 0.38 + presentation.lineSpacing)
                    .padding(.bottom, geometry.size.height * 0.48 + presentation.lineSpacing)
                    .background(NativeScrollPreferences().frame(width: 0, height: 0))
                }
                .scrollPosition($scrollPosition, anchor: UnitPoint(x: 0.5, y: 0.42))
                // NSScrollView supplies overlay scrollers and their fade
                // timing. Respect the user's "Always" system preference.
                .scrollIndicators(.automatic)
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .tracking, .interacting:
                        scrollRequests.invalidate()
                        isUserScrolling = true
                        resumeTask?.cancel()
                        scrollDiagnostics?("new-user-interaction", scrollPosition.isPositionedByUser,
                                           isUserScrolling, scrollRequests.generation)
                    case .idle where isUserScrolling:
                        scheduleResume()
                    default:
                        break // Programmatic .animating is not user input.
                    }
                }
                .onChange(of: scrollPosition) { _, position in
                    scrollDiagnostics?("native-position-update", position.isPositionedByUser,
                                       isUserScrolling, scrollRequests.generation)
                    reconcileLateUserPosition(position)
                }
                .onChange(of: LyricsFocusState(index: lyricsCursor.activeIndex,
                                              seekRevision: lyricsCursor.seekRevision)) { previous, current in
                    // A single observation keeps an explicit seek from
                    // racing the ordinary next-line spring in this commit.
                    if previous.seekRevision != current.seekRevision {
                        adoptCursor()
                        return
                    }
                    activeIndex = current.index
                    guard !isUserScrolling, let index = current.index else { return }
                    scroll(to: index, animated: true)
                }
                .onChange(of: player.currentTrack?.id) { _, _ in
                    scrollRequests.invalidate()
                    resumeTask?.cancel()
                    isUserScrolling = false
                    activeIndex = nil
                    scrollPosition = ScrollPosition(idType: Int.self)
                }
                .onChange(of: lyrics) { _, _ in
                    adoptCursor()
                }
                .onAppear {
                    scrollRequests.isAttached = true
                    adoptCursor()
                }
                .overlay(alignment: .bottom) {
                    if isUserScrolling {
                        Button {
                            resumeFollowing()
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

    private func adoptCursor() {
        scrollRequests.invalidate()
        resumeTask?.cancel()
        isUserScrolling = false
        activeIndex = lyricsCursor.activeIndex
        let trackID = player.currentTrack?.id
        let seekRevision = lyricsCursor.seekRevision
        let generation = scrollRequests.generation
        // The target layout must be mounted. Re-read the cursor in
        // the deferred turn, rather than applying a stale pre-seek position.
        DispatchQueue.main.async {
            guard scrollRequests.isAttached, !isUserScrolling,
                  scrollRequests.generation == generation,
                  player.currentTrack?.id == trackID,
                  lyricsCursor.seekRevision == seekRevision,
                  let index = lyricsCursor.activeIndex else { return }
            activeIndex = index
            scroll(to: index, animated: false)
        }
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(LyricsVisualParameters.followResumeDelay))
            } catch { return }
            resumeFollowing()
        }
    }

    private func resumeFollowing() {
        scrollRequests.invalidate()
        resumeTask?.cancel()
        isUserScrolling = false
        guard let index = lyricsCursor.activeIndex else { return }
        activeIndex = index
        scroll(to: index, animated: true)
    }

    private func reconcileLateUserPosition(_ position: ScrollPosition) {
        guard position.isPositionedByUser, !isUserScrolling,
              scrollRequests.isAttached, scrollRequests.pendingReconciliation == nil else { return }
        let generation = scrollRequests.generation
        let trackID = player.currentTrack?.id
        let seekRevision = lyricsCursor.seekRevision
        scrollRequests.pendingReconciliation = generation
        scrollDiagnostics?("late-user-write-queued", position.isPositionedByUser,
                           isUserScrolling, generation)
        // A native wheel update from a completed gesture can arrive after the
        // explicit target. Coalesce its binding feedback outside native layout;
        // genuine new interaction invalidates this work before it can run.
        DispatchQueue.main.async {
            guard scrollRequests.pendingReconciliation == generation else { return }
            scrollRequests.pendingReconciliation = nil
            guard scrollRequests.isAttached, !isUserScrolling,
                  scrollRequests.generation == generation,
                  player.currentTrack?.id == trackID,
                  lyricsCursor.seekRevision == seekRevision,
                  let index = lyricsCursor.activeIndex else { return }
            scroll(to: index, animated: false)
            scrollDiagnostics?("late-user-write-reconciled", scrollPosition.isPositionedByUser,
                               isUserScrolling, generation)
        }
    }

    private func scroll(to index: Int, animated: Bool) {
        if animated, !reduceMotion {
            withAnimation(LyricsVisualParameters.scrollAnimation) {
                scrollPosition.scrollTo(id: index, anchor: UnitPoint(x: 0.5, y: 0.42))
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: index, anchor: UnitPoint(x: 0.5, y: 0.42))
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
