import CoreGraphics
import Testing
@testable import KumoneCore

@Suite("Window trailing pane geometry")
struct WindowPanelGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)

    @Test func narrowWindowAddsSpaceForThePaneWithoutShrinkingItsMainColumn() throws {
        let original = CGRect(x: 100, y: 100, width: 1100, height: 800)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: CGSize(width: 1100, height: 772),
            mainWidth: 900, visibleFrame: screen, isFullScreen: false
        ))
        #expect(plan.mode == .expandedOutside)
        #expect(plan.panelWidth == 340)
        #expect(plan.frame.origin == original.origin)
        #expect(plan.frame.width - plan.panelWidth - WindowPanelGeometry.dividerWidth == original.width)
        #expect(plan.frame.height == original.height)
    }

    @Test(arguments: [CGSize(width: 1600, height: 900), CGSize(width: 1700, height: 900)])
    func atOrAboveSixteenByNineUsesTheExistingWindow(contentSize: CGSize) throws {
        let original = CGRect(origin: CGPoint(x: 30, y: 40), size: contentSize)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: contentSize,
            mainWidth: 1320, visibleFrame: screen, isFullScreen: false
        ))
        #expect(plan.mode == .expandedInside)
        #expect(plan.frame == original)
        #expect(plan.panelWidth == 340)
    }

    @Test func rightEdgeShortageMovesTheWindowLeftWithinTheVisibleScreen() throws {
        let original = CGRect(x: 600, y: 100, width: 1100, height: 800)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: original.size,
            mainWidth: 900, visibleFrame: screen, isFullScreen: false
        ))
        #expect(plan.mode == .expandedOutside)
        #expect(plan.frame.minX < original.minX)
        #expect(plan.frame.maxX == screen.maxX)
        #expect(screen.contains(plan.frame))
        #expect(WindowPanelGeometry.restoredFrame(original, visibleFrame: screen) == original)
    }

    @Test func aSmallerPaneCanFitBeforeFallingBackInside() throws {
        let original = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let smallScreen = CGRect(x: 0, y: 0, width: 1401, height: 900)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: original.size,
            mainWidth: 900, visibleFrame: smallScreen, isFullScreen: false
        ))
        #expect(plan.mode == .expandedOutside)
        #expect(plan.panelWidth == 300)
        #expect(plan.frame == CGRect(x: 0, y: 0, width: 1401, height: 800))
    }

    @Test func insufficientOutsideSpaceFallsBackInsideWithoutChangingTheFrame() throws {
        let original = CGRect(x: 0, y: 0, width: 1350, height: 900)
        let smallScreen = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: original.size,
            mainWidth: 1150, visibleFrame: smallScreen, isFullScreen: false
        ))
        #expect(plan.mode == .expandedInside)
        #expect(plan.panelWidth == 329)
        #expect(plan.frame == original)
        #expect(1150 - plan.panelWidth - WindowPanelGeometry.dividerWidth == WindowPanelGeometry.minimumMainWidth)
    }

    @Test func insufficientSpaceDeclinesInsteadOfSqueezingOrHidingControls() {
        let original = CGRect(x: 0, y: 0, width: 1100, height: 800)
        #expect(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: original.size,
            mainWidth: 900, visibleFrame: CGRect(x: 0, y: 0, width: 1300, height: 900),
            isFullScreen: false
        ) == nil)
    }

    @Test func fullScreenNeverChangesTheSystemWindowFrame() throws {
        let original = CGRect(x: -1920, y: 0, width: 1800, height: 1100)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: original.size, mainWidth: 1500,
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1200),
            isFullScreen: true
        ))
        #expect(plan.mode == .expandedInside)
        #expect(plan.frame == original)
    }

    @Test func aDisplayLeftOfThePrimaryDisplayUsesItsOwnVisibleCoordinates() throws {
        let leftScreen = CGRect(x: -1920, y: 24, width: 1920, height: 1056)
        let original = CGRect(x: -1150, y: 70, width: 1100, height: 800)
        let plan = try #require(WindowPanelGeometry.openingPlan(
            frame: original, contentSize: original.size,
            mainWidth: 900, visibleFrame: leftScreen, isFullScreen: false
        ))
        #expect(plan.mode == .expandedOutside)
        #expect(plan.frame.maxX == 0)
        #expect(leftScreen.contains(plan.frame))
    }

    @Test func restoringAfterADisplayChangeClampsPositionAndPreservesSizeWhenPossible() {
        let original = CGRect(x: -1800, y: 100, width: 1100, height: 800)
        let restored = WindowPanelGeometry.restoredFrame(original, visibleFrame: screen)
        #expect(restored == CGRect(x: 0, y: 100, width: 1100, height: 800))
        #expect(screen.contains(restored))
    }

    @Test func changedDockAndMenuBarBoundsKeepTheWholeRestoredWindowAccessible() {
        let newVisible = CGRect(x: 70, y: 40, width: 1400, height: 900)
        let original = CGRect(x: 0, y: 0, width: 1700, height: 1000)
        #expect(WindowPanelGeometry.restoredFrame(original, visibleFrame: newVisible) == newVisible)
    }

    @Test func anUnlaidOutWindowCannotChooseAnOpeningMode() {
        #expect(WindowPanelGeometry.openingPlan(
            frame: .zero, contentSize: .zero, mainWidth: 0,
            visibleFrame: screen, isFullScreen: false
        ) == nil)
    }
}
