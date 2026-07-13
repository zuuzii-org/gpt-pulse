import XCTest
@testable import LLMPulse

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

    func testStatusClickStaysVisibleForFiveSecondsWhilePointerRemainsOutside() throws {
        var state = makeDismissState()
        let effects = state.present(
            source: .statusItemClick,
            at: 100,
            pointerInside: false
        )
        let request = try XCTUnwrap(scheduledTimer(in: effects))

        XCTAssertEqual(request.delay, 5, accuracy: 0.000_001)
        XCTAssertTrue(state.pointerMoved(inside: false, at: 104.9).isEmpty)

        let earlyEffects = state.timerFired(
            token: request.token,
            at: 104.99,
            pointerInside: false
        )
        XCTAssertEqual(
            try XCTUnwrap(scheduledTimer(in: earlyEffects)).delay,
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            state.timerFired(
                token: request.token,
                at: 105,
                pointerInside: false
            ),
            [.hide]
        )
        XCTAssertEqual(state.phase, .hidden)
    }

    func testPointerEntryConvertsStatusClickGraceIntoHoverHold() throws {
        var state = makeDismissState()
        let initial = state.present(
            source: .statusItemClick,
            at: 100,
            pointerInside: false
        )
        let clickTimer = try XCTUnwrap(scheduledTimer(in: initial))

        XCTAssertEqual(
            state.pointerMoved(inside: true, at: 101),
            [.cancelTimer]
        )
        XCTAssertEqual(state.phase, .hoverHeld)
        XCTAssertTrue(
            state.timerFired(
                token: clickTimer.token,
                at: 105,
                pointerInside: true
            ).isEmpty
        )
    }

    func testFiveSecondTimerKeepsPanelVisibleWhenPointerReachedWithoutSample() throws {
        var state = makeDismissState()
        let request = try XCTUnwrap(
            scheduledTimer(
                in: state.present(
                    source: .statusItemClick,
                    at: 100,
                    pointerInside: false
                )
            )
        )

        XCTAssertEqual(
            state.timerFired(
                token: request.token,
                at: 105,
                pointerInside: true
            ),
            [.cancelTimer]
        )
        XCTAssertEqual(state.phase, .hoverHeld)
    }

    func testPointerLeaveAfterHoverUsesExistingDismissDelay() throws {
        var state = makeDismissState()
        _ = state.present(source: .statusItemClick, at: 100, pointerInside: false)
        _ = state.pointerMoved(inside: true, at: 101)

        let leaveEffects = state.pointerMoved(inside: false, at: 102)
        let leaveTimer = try XCTUnwrap(scheduledTimer(in: leaveEffects))
        XCTAssertEqual(leaveTimer.delay, 0.3, accuracy: 0.000_001)

        XCTAssertEqual(
            state.timerFired(
                token: leaveTimer.token,
                at: 102.3,
                pointerInside: false
            ),
            [.hide]
        )
    }

    func testPointerReentryCancelsLeaveDismissal() throws {
        var state = makeDismissState()
        _ = state.present(source: .edgeHover, at: 100, pointerInside: true)
        let leaveTimer = try XCTUnwrap(
            scheduledTimer(in: state.pointerMoved(inside: false, at: 101))
        )

        XCTAssertEqual(
            state.pointerMoved(inside: true, at: 101.1),
            [.cancelTimer]
        )
        XCTAssertEqual(state.phase, .hoverHeld)
        XCTAssertTrue(
            state.timerFired(
                token: leaveTimer.token,
                at: 101.3,
                pointerInside: true
            ).isEmpty
        )
    }

    func testEdgePresentationNeverInheritsFiveSecondClickTimer() throws {
        var state = makeDismissState()

        XCTAssertEqual(
            state.present(source: .edgeHover, at: 100, pointerInside: true),
            [.cancelTimer]
        )
        XCTAssertEqual(state.phase, .hoverHeld)

        let request = try XCTUnwrap(
            scheduledTimer(in: state.pointerMoved(inside: false, at: 106))
        )
        XCTAssertEqual(request.delay, 0.3, accuracy: 0.000_001)
    }

    func testOldTimerCannotHideNewPresentation() throws {
        var state = makeDismissState()
        let firstTimer = try XCTUnwrap(
            scheduledTimer(
                in: state.present(
                    source: .statusItemClick,
                    at: 100,
                    pointerInside: false
                )
            )
        )
        _ = state.reset()
        let secondTimer = try XCTUnwrap(
            scheduledTimer(
                in: state.present(
                    source: .statusItemClick,
                    at: 101,
                    pointerInside: false
                )
            )
        )

        XCTAssertNotEqual(firstTimer.token, secondTimer.token)
        XCTAssertTrue(
            state.timerFired(
                token: firstTimer.token,
                at: 105,
                pointerInside: false
            ).isEmpty
        )
        XCTAssertNotEqual(state.phase, .hidden)
    }

    private func makeDismissState() -> TaskPanelAutomaticDismissState {
        TaskPanelAutomaticDismissState(
            statusClickDisplayDuration: 5,
            pointerExitDismissDelay: 0.3
        )
    }

    private func scheduledTimer(
        in effects: [TaskPanelAutomaticDismissState.Effect]
    ) -> (token: UInt64, delay: TimeInterval)? {
        for effect in effects {
            if case let .scheduleTimer(token, delay) = effect {
                return (token: token, delay: delay)
            }
        }
        return nil
    }
}

