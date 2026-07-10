import XCTest
@testable import GPTPulse

@MainActor
final class TaskPanelGeometryTests: XCTestCase {
    func testPanelUsesVisibleRightEdgeWhenDockOccupiesScreenRight() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 24, width: 1_360, height: 876)

        let frame = TaskPanelController.panelFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            width: 380
        )

        XCTAssertEqual(frame, CGRect(x: 980, y: 24, width: 380, height: 876))
    }

    func testPanelUsesVisibleHeightWhenDockOccupiesScreenBottom() {
        let screenFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let visibleFrame = CGRect(x: -1_920, y: 72, width: 1_920, height: 1_008)

        let frame = TaskPanelController.panelFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            width: 380
        )

        XCTAssertEqual(frame, CGRect(x: -380, y: 72, width: 380, height: 1_008))
    }
}
