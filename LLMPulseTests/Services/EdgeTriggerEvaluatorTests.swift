import CoreGraphics
import XCTest
@testable import LLMPulse

final class EdgeTriggerEvaluatorTests: XCTestCase {
    private let primary = EdgeScreenGeometry(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    func testTriggersAfterDwellOnMiddleOfExposedRightEdge() {
        var evaluator = EdgeTriggerEvaluator(dwellDuration: 0.2)

        XCTAssertNil(evaluator.evaluate(sample(at: 10)))
        XCTAssertNil(evaluator.evaluate(sample(at: 10.19)))
        XCTAssertEqual(evaluator.evaluate(sample(at: 10.2)), primary)
        XCTAssertNil(evaluator.evaluate(sample(at: 11)))
    }

    func testDoesNotTriggerOutsideMiddleSixtyPercent() {
        var evaluator = EdgeTriggerEvaluator(dwellDuration: 0.2)
        let location = CGPoint(x: primary.frame.maxX - 1, y: 100)

        XCTAssertNil(evaluator.evaluate(sample(at: 1, location: location)))
        XCTAssertNil(evaluator.evaluate(sample(at: 2, location: location)))
        XCTAssertNil(evaluator.candidateScreenID)
    }

    func testMouseButtonPressResetsDwell() {
        var evaluator = EdgeTriggerEvaluator(dwellDuration: 0.2)

        XCTAssertNil(evaluator.evaluate(sample(at: 1)))
        XCTAssertNil(evaluator.evaluate(sample(at: 1.15, mouseButtonPressed: true)))
        XCTAssertNil(evaluator.evaluate(sample(at: 1.25)))
        XCTAssertNil(evaluator.evaluate(sample(at: 1.4)))
        XCTAssertEqual(evaluator.evaluate(sample(at: 1.45)), primary)
    }

    func testDoesNotTriggerAtInternalDisplaySeam() {
        let rightDisplay = EdgeScreenGeometry(
            id: 2,
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        )
        var evaluator = EdgeTriggerEvaluator(dwellDuration: 0.2)
        let location = CGPoint(x: primary.frame.maxX - 1, y: 450)

        let screens = [primary, rightDisplay]
        XCTAssertNil(evaluator.evaluate(sample(at: 1, location: location, screens: screens)))
        XCTAssertNil(evaluator.evaluate(sample(at: 2, location: location, screens: screens)))
    }

    func testTriggersOnRightmostDisplay() {
        let rightDisplay = EdgeScreenGeometry(
            id: 2,
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        )
        var evaluator = EdgeTriggerEvaluator(dwellDuration: 0.2)
        let location = CGPoint(x: rightDisplay.frame.maxX - 1, y: 540)
        let screens = [primary, rightDisplay]

        XCTAssertNil(evaluator.evaluate(sample(at: 1, location: location, screens: screens)))
        XCTAssertEqual(
            evaluator.evaluate(sample(at: 1.2, location: location, screens: screens)),
            rightDisplay
        )
    }

    func testFullScreenSuppressesTrigger() {
        var evaluator = EdgeTriggerEvaluator(dwellDuration: 0.2)

        XCTAssertNil(evaluator.evaluate(sample(at: 1, fullScreen: true)))
        XCTAssertNil(evaluator.evaluate(sample(at: 2, fullScreen: true)))
        XCTAssertNil(evaluator.candidateScreenID)
    }

    private func sample(
        at uptime: TimeInterval,
        location: CGPoint? = nil,
        screens: [EdgeScreenGeometry]? = nil,
        mouseButtonPressed: Bool = false,
        panelVisible: Bool = false,
        fullScreen: Bool = false
    ) -> EdgeTriggerSample {
        EdgeTriggerSample(
            location: location ?? CGPoint(x: primary.frame.maxX - 1, y: 450),
            screens: screens ?? [primary],
            uptime: uptime,
            mouseButtonPressed: mouseButtonPressed,
            panelVisible: panelVisible,
            isFullScreen: { _ in fullScreen }
        )
    }
}
