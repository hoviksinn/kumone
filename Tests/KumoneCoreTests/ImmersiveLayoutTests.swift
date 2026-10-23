import Foundation
import Testing
@testable import KumoneCore

@Suite("Immersive artwork and shared lyric presentation")
struct ImmersiveLayoutTests {
    @Test(arguments: [
        CGSize(width: 1021, height: 540),
        CGSize(width: 1101, height: 564),
        CGSize(width: 1300, height: 700),
        CGSize(width: 1600, height: 900),
        CGSize(width: 2038, height: 1320),
        CGSize(width: 2800, height: 900),
    ])
    func supportedWindowsKeepTransportAndColumnsInsideTheSafeArea(size: CGSize) {
        for hasLyrics in [true, false] {
            let metrics = ImmersiveLayoutMetrics(size: size, hasLyrics: hasLyrics)
            #expect(metrics.artworkSide >= ImmersiveLayoutMetrics.minimumTransportWidth)
            #expect(metrics.bandWidth <= size.width)
            #expect(metrics.leftColumnHeight + metrics.verticalInset * 2 <= size.height + 0.001)
            #expect(metrics.lyricsHeight + metrics.verticalInset * 2 <= size.height + 0.001)
            #expect(metrics.artworkSide <= ImmersiveLayoutMetrics.maximumArtworkSide)
            if hasLyrics {
                #expect(metrics.lyricsWidth >= 300)
                #expect(abs(metrics.bandWidth - metrics.artworkSide
                            - metrics.columnSpacing - metrics.lyricsWidth) < 0.001)
            } else {
                #expect(metrics.lyricsWidth == 0)
                #expect(metrics.columnSpacing == 0)
                #expect(metrics.bandWidth == metrics.artworkSide)
            }
        }
    }

    @Test func referenceProportionsAdaptWithoutTreatingPixelsAsPoints() {
        let large = ImmersiveLayoutMetrics(size: CGSize(width: 2038, height: 1320), hasLyrics: true)
        let smaller = ImmersiveLayoutMetrics(size: CGSize(width: 1101, height: 564), hasLyrics: true)
        #expect(large.artworkSide == 720)
        #expect(large.lyricsWidth > large.artworkSide)
        #expect(smaller.artworkSide < large.artworkSide)
        #expect(smaller.columnSpacing < large.columnSpacing)
        #expect(smaller.leftColumnHeight < large.leftColumnHeight)
    }

    @Test func pausedArtworkKeepsItsOriginalLayoutSlot() {
        let metrics = ImmersiveLayoutMetrics(size: CGSize(width: 1500, height: 900), hasLyrics: true)
        let playingSize = metrics.artworkSide
        let pausedVisibleSize = playingSize * ImmersiveLayoutMetrics.pausedArtworkScale
        #expect(abs(pausedVisibleSize / playingSize - 525.0 / 720.0) < 0.000001)
        // The fixed control/document geometry does not depend on transport state.
        #expect(metrics.leftColumnHeight == metrics.artworkSide + ImmersiveLayoutMetrics.controlsHeight)
        #expect(pausedVisibleSize < metrics.artworkSide)
    }

    @Test func vinylTonearmStageFitsTheSameArtworkSlot() {
        for size in [CGSize(width: 1021, height: 540), CGSize(width: 2038, height: 1320)] {
            let metrics = ImmersiveLayoutMetrics(size: size, hasLyrics: true)
            #expect(metrics.vinylDiscSide + 48 <= metrics.artworkSide + 0.001)
            #expect(metrics.vinylDiscSide * (1 + 0.68 * 0.38) <= metrics.artworkSide + 0.001)
        }
    }

    @Test func transientEmptyAndInvalidProposalsDoNotProduceNegativeOrInfiniteFrames() {
        for size in [CGSize.zero, CGSize(width: -1, height: -1),
                     CGSize(width: CGFloat.infinity, height: CGFloat.nan)] {
            let metrics = ImmersiveLayoutMetrics(size: size, hasLyrics: true)
            for value in [metrics.artworkSide, metrics.lyricsWidth, metrics.lyricsHeight,
                          metrics.bandWidth, metrics.columnSpacing, metrics.vinylDiscSide] {
                #expect(value.isFinite)
                #expect(value >= 0)
            }
        }
    }

    @Test func sharedLyricPresentationPreservesAnnotationHierarchy() {
        for presentation in [LyricsPanelPresentation.standard, .immersive] {
            #expect(LyricsVisualParameters.fontSize * presentation.fontScale
                    > LyricsVisualParameters.translationSize * presentation.fontScale)
            #expect(LyricsVisualParameters.translationSize * presentation.fontScale
                    >= LyricsVisualParameters.romajiSize * presentation.fontScale)
            #expect(presentation.lineSpacing >= LyricsVisualParameters.lineSpacing)
        }
        #expect(LyricsPanelPresentation.immersive.fontScale > LyricsPanelPresentation.standard.fontScale)
    }
}
