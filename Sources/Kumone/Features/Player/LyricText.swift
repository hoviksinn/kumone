import SwiftUI

/// The lyric itself, with furigana over the kanji when the reader asked for it
/// and the line has kanji worth annotating.
///
/// Every other case falls through to a plain `Text`, so lyrics that are not
/// Japanese, and the two annotation modes that are not furigana, keep exactly
/// the rendering they had.
struct LyricText: View {
    let line: LyricLine
    let size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = .primary
    var alignment: NSTextAlignment = .left
    var rounded: Bool = false
    /// Per-character opacity for the karaoke wipe, when there is one.
    var alphas: [Double]?

    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        if settings.lyricsAnnotation == .furigana, let furigana = line.furigana {
            RubyText(
                segments: furigana,
                size: size,
                weight: weight,
                color: color,
                rubyColor: color.opacity(0.72),
                alignment: alignment,
                rounded: rounded,
                alphas: alphas
            )
            // The line is glyphs in a `Canvas`, which carries no text for
            // VoiceOver to read. Stand in the plain lyric; the readings are a
            // visual aid and would only clutter it spoken.
            .accessibilityRepresentation { Text(line.text.isEmpty ? "♪" : line.text) }
        } else if let alphas, !alphas.isEmpty {
            wiped(alphas)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
                .foregroundStyle(color)
        }
    }

    /// One concatenated `Text`, so the line still wraps, with the wipe applied
    /// per character.
    private func wiped(_ alphas: [Double]) -> Text {
        var out = Text(verbatim: "")
        for (index, character) in line.text.enumerated() {
            let alpha = index < alphas.count ? alphas[index] : 1
            out = out + Text(verbatim: String(character)).foregroundColor(color.opacity(alpha))
        }
        return out
    }
}

/// A local, display-synchronised karaoke surface. The display link chooses
/// when to draw; only the audio engine chooses which characters are sung.
/// Inactive rows, LRC-only lyrics and the rest of the window have no link.
struct LyricPlaybackText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    var weight: Font.Weight = .bold
    var color: Color = .primary
    var verbatim = true

    var body: some View {
        if isActive, verbatim, let words = line.words, !words.isEmpty {
            DisplayLinkedLyricText(line: line, words: words, size: size, weight: weight, color: color)
        } else {
            LyricText(line: line, size: size, weight: weight, color: color)
        }
    }
}

private struct DisplayLinkedLyricText: View {
    let line: LyricLine
    let words: [LyricWord]
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    @EnvironmentObject private var player: PlayerService
    // This small observer also updates the highlight after seeking while
    // paused, when the display link is intentionally asleep.
    @ObservedObject private var clock = PlayerService.shared.clock
    @State private var displayedAlphas: [Double]?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = 0
    @State private var isVisible = false

    var body: some View {
        LyricText(
            line: line, size: size, weight: weight, color: color,
            alphas: displayedAlphas ?? LyricHighlightTiming.alphas(for: line, words: words, at: player.progress)
        )
        // A focus spring must never become the timing source for a YRC wipe.
        .transaction { $0.animation = nil }
        .background {
            LyricDisplayRefresh(isEnabled: player.isPlaying, onRefresh: requestHighlightRefresh)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            isVisible = true
            requestHighlightRefresh()
        }
        .onDisappear {
            isVisible = false
            cancelRefresh()
        }
        .onChange(of: line) { _, _ in
            cancelRefresh()
            displayedAlphas = nil
            requestHighlightRefresh()
        }
        .onChange(of: player.isPlaying) { _, _ in
            cancelRefresh()
            requestHighlightRefresh()
        }
        .onChange(of: clock.progress) { _, _ in
            if !player.isPlaying {
                // A seek can arrive while a previous paused read is pending.
                // Only the query queued after that seek may paint the result.
                cancelRefresh()
                requestHighlightRefresh()
            }
        }
    }

    private func requestHighlightRefresh() {
        // At most one real engine read is outstanding. If file scheduling or
        // an AutoMix hand-over takes longer than a frame, skip that frame
        // rather than blocking AppKit or growing a display-rate task backlog.
        guard isVisible, refreshTask == nil else { return }
        let generation = refreshGeneration
        refreshTask = Task { @MainActor in
            let time = await player.livePlaybackTimeAsync()
            guard !Task.isCancelled, isVisible, generation == refreshGeneration else { return }
            let next = LyricHighlightTiming.alphas(for: line, words: words, at: time)
            // Gaps between sung words don't need a new SwiftUI rendering pass.
            if displayedAlphas != next { displayedAlphas = next }
            refreshTask = nil
        }
    }

    private func cancelRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }
}
