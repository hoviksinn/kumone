import Foundation
import Testing
@testable import KumoneCore

@Suite("Main content and trailing player layout")
struct PlayerLayoutTests {
    @Test func narrowWindowKeepsContentAndControlsUsable() {
        // Smallest normal window, including the sidebar at its largest width.
        let layout = PlayerLayoutMetrics(detailWidth: 732, showsPanel: true)
        #expect(layout.panelWidth == 280)
        #expect(layout.mainWidth == 451)
        #expect(layout.barWidth == 411)
        #expect(layout.barLayout == .narrow)
        #expect(layout.barClearance == 128)
    }

    @Test func ordinaryWindowReflowsControlsWithoutHidingThem() {
        let layout = PlayerLayoutMetrics(detailWidth: 972, showsPanel: true)
        #expect(abs(layout.panelWidth - 311.04) < 0.001)
        #expect(abs(layout.mainWidth - 659.96) < 0.001)
        #expect(layout.barLayout == .stacked)
        #expect(layout.barClearance == 112)
    }

    @Test func wideWindowCapsPlayerWidth() {
        let layout = PlayerLayoutMetrics(detailWidth: 1572, showsPanel: true)
        #expect(layout.panelWidth == 380)
        #expect(layout.mainWidth == 1191)
        #expect(layout.barWidth == 880)
        #expect(layout.barLayout == .wide)
    }

    @Test func closingPanelReturnsTheEntireColumnToContent() {
        let layout = PlayerLayoutMetrics(detailWidth: 972, showsPanel: false)
        #expect(layout.panelWidth == 0)
        #expect(layout.mainWidth == 972)
        #expect(layout.barWidth == 880)
    }

    @Test func supportedSizesNeverOverlapOrOverflow() {
        for width in stride(from: CGFloat(720), through: 2400, by: 1) {
            for showsPanel in [false, true] {
                let layout = PlayerLayoutMetrics(detailWidth: width, showsPanel: showsPanel)
                let divider: CGFloat = showsPanel ? PlayerLayoutMetrics.dividerWidth : 0
                #expect(abs(layout.mainWidth + layout.panelWidth + divider - width) < 0.001)
                #expect(layout.mainWidth >= PlayerLayoutMetrics.minimumMainWidth)
                #expect(layout.barWidth + PlayerLayoutMetrics.barHorizontalMargin * 2 <= layout.mainWidth)
                #expect(layout.barWidth <= PlayerLayoutMetrics.maximumBarWidth)
            }
        }
    }

    @Test func transientZeroProposalNeverProducesNegativeFrames() {
        let layout = PlayerLayoutMetrics(detailWidth: 0, showsPanel: true)
        #expect(layout.mainWidth == 0)
        #expect(layout.panelWidth == 0)
        #expect(layout.barWidth == 0)
    }
}
