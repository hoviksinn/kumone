import Foundation
import Testing

@testable import KumoneCore

@Suite struct LyricHighlightTimingTests {
    private let words = [LyricWord(text: "且听", start: 10, duration: 2)]
    private var line: LyricLine {
        LyricLine(id: 0, time: 10, text: "且听", words: words)
    }

    private func expect(_ actual: [Double], _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        for (actual, expected) in zip(actual, expected) {
            #expect(abs(actual - expected) < 0.000001, sourceLocation: sourceLocation)
        }
    }

    @Test func samplesRealWordBoundariesAndPartialCharacters() {
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 9), [0.28, 0.28])
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 10.5), [0.64, 0.28])
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 11.5), [1, 0.64])
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 12), [1, 1])
    }

    @Test func repeatedPausedSamplesAndBackwardSeekHaveNoAccumulatedAnimationState() {
        for _ in 0..<20 {
            expect(LyricHighlightTiming.alphas(for: line, words: words, at: 11.5), [1, 0.64])
        }
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 10.25), [0.46, 0.28])
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 30), [1, 1])
        expect(LyricHighlightTiming.alphas(for: line, words: words, at: 0), [0.28, 0.28])
    }

    @Test func equivalentAudioTimesAtSixtyAndOneTwentyHertzAgree() {
        // These are sampling cadences, not a claim that a real display ran at
        // either rate. A skipped/doubled frame cannot shift the lyric clock.
        let sixty = (0...120).map { tick in
            LyricHighlightTiming.alphas(for: line, words: words, at: 10 + Double(tick) / 60)
        }
        let oneTwenty = (0...240).map { tick in
            LyricHighlightTiming.alphas(for: line, words: words, at: 10 + Double(tick) / 120)
        }
        for tick in sixty.indices { expect(sixty[tick], oneTwenty[tick * 2]) }
        expect(sixty[30], [0.64, 0.28])
        expect(sixty[90], [1, 0.64])
    }

    @Test func parsedYrcWhitespaceDoesNotShiftTheFirstVisibleCharacter() throws {
        let parsed = LyricsParser.parseYRC("[10000,5000](10000,1000,0) (11000,2000,0)且听(13000,1000,0) ")
        let parsedLine = try #require(parsed.first)
        let parsedWords = try #require(parsedLine.words)
        #expect(parsedLine.text == "且听")
        expect(LyricHighlightTiming.alphas(for: parsedLine, words: parsedWords, at: 11.5), [0.64, 0.28])
    }

    @Test func mixedScriptsAndEmojiStayAlignedByDisplayedCharacter() {
        let mixedWords = [LyricWord(text: "聴A👨‍👩‍👧‍👦", start: 0, duration: 3)]
        let mixedLine = LyricLine(id: 0, time: 0, text: "聴A👨‍👩‍👧‍👦", words: mixedWords)
        expect(LyricHighlightTiming.alphas(for: mixedLine, words: mixedWords, at: 1.5), [1, 0.64, 0.28])
    }

    @Test func zeroDurationSyllableChangesExactlyAtItsAudioTimestamp() {
        let instantWords = [LyricWord(text: "あ", start: 5, duration: 0)]
        let instantLine = LyricLine(id: 0, time: 5, text: "あ", words: instantWords)
        expect(LyricHighlightTiming.alphas(for: instantLine, words: instantWords, at: 4.99), [0.28])
        expect(LyricHighlightTiming.alphas(for: instantLine, words: instantWords, at: 5), [1])
    }

    @Test func gapsDoNotInventSungCharacters() {
        let gapWords = [LyricWord(text: "你", start: 0, duration: 1), LyricWord(text: "好", start: 4, duration: 1)]
        let gapLine = LyricLine(id: 0, time: 0, text: "你好", words: gapWords)
        expect(LyricHighlightTiming.alphas(for: gapLine, words: gapWords, at: 1.5), [1, 0.28])
        expect(LyricHighlightTiming.alphas(for: gapLine, words: gapWords, at: 3.5), [1, 0.28])
        expect(LyricHighlightTiming.alphas(for: gapLine, words: gapWords, at: 4.5), [1, 0.64])
    }

    @Test func immersiveFacadeRetainsItsExistingTimingContract() {
        expect(LyricMainText.alphas(for: line, words: words, at: 10.5), [0.64, 0.28])
        expect(LyricMainText.alphas(for: line, words: words, at: 11.5), [1, 0.64])
    }
}
