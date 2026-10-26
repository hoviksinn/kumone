import Foundation
import Testing
@testable import KumoneCore

@Suite("Single-row floating player constraints")
struct PlayerLayoutTests {
    @Test func allSupportedWidthsKeepOneRowAndFixedControls() {
        for width in [CGFloat(820), 900, 1021, 1400, 2400] {
            let bar = PlayerLayoutMetrics.barWidth(in: width)
            #expect(bar >= 780 && bar <= 880)
            #expect(bar + 40 <= width)
            #expect(PlayerBarLayout.wide.height == 56)
        }
    }
    @Test func transientSmallProposalsNeverCompressTheTransport() {
        #expect(PlayerLayoutMetrics.barWidth(in: 0) == 780)
        #expect(PlayerLayoutMetrics.barWidth(in: 440) == 780)
    }
    @Test func ordinaryAndImmersiveShareTheSameWindowRule() {
        #expect(Theme.Layout.minWindowWidth == 1021)
        #expect(Theme.Layout.minWindowHeight == 640)
        #expect(PlayerLayoutMetrics.barClearance == 72)
    }
}
