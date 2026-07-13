import XCTest
@testable import LLMPulse

final class HorizontalModelSwipeStateTests: XCTestCase {
    func testNonPreciseAndShiftModifiedEventsPassThrough() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: -80, phase: .began, precise: false)),
            .passThrough
        )
        XCTAssertEqual(state.phase, .idle)

        XCTAssertEqual(
            state.handle(sample(x: -80, phase: .began, shifted: true)),
            .passThrough
        )
        XCTAssertEqual(state.phase, .idle)
    }

    func testHorizontalAxisLocksAtTenPointsAndCommitsAtSixtySix() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: -4, y: -2, phase: .began)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(sample(x: -5, y: -1, phase: .changed)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(sample(x: -1, phase: .changed)),
            .consume
        )
        XCTAssertEqual(
            state.handle(sample(x: -55, phase: .changed)),
            .consume
        )
        XCTAssertEqual(
            state.handle(sample(x: -1, phase: .changed)),
            .select(.next)
        )
    }

    func testPositiveHorizontalDeltaSelectsPreviousPage() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: 66, phase: .began)),
            .select(.previous)
        )
    }

    func testHorizontalDominanceUsesOnePointThreeRatio() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: 13, y: 10, phase: .began)),
            .consume
        )
        guard case let .locked(_, direction, accumulatedX) = state.phase else {
            return XCTFail("Expected a horizontally locked gesture")
        }
        XCTAssertEqual(direction, .previous)
        XCTAssertEqual(accumulatedX, 13)
    }

    func testVerticalGesturePassesThroughForItsWholeLifecycle() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: 1, y: 6, phase: .began)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(sample(x: 1, y: 5, phase: .changed)),
            .passThrough
        )
        guard case .rejected = state.phase else {
            return XCTFail("Expected the gesture to remain vertically rejected")
        }

        XCTAssertEqual(
            state.handle(sample(x: -100, phase: .changed)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(momentum(x: -100, phase: .began)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(momentum(phase: .ended)),
            .passThrough
        )
        XCTAssertEqual(state.phase, .idle)
    }

    func testAmbiguousDiagonalDoesNotLockUntilOneAxisDominates() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: 10, y: 10, phase: .began)),
            .passThrough
        )
        guard case .detecting = state.phase else {
            return XCTFail("Expected ambiguous movement to stay in detection")
        }

        XCTAssertEqual(
            state.handle(sample(y: 5, phase: .changed)),
            .passThrough
        )
        guard case .rejected = state.phase else {
            return XCTFail("Expected later vertical dominance to reject the gesture")
        }
    }

    func testCommittedGestureSelectsAtMostOnceIncludingMomentum() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: -66, phase: .began)),
            .select(.next)
        )
        XCTAssertEqual(
            state.handle(sample(x: -80, phase: .changed)),
            .consume
        )
        XCTAssertEqual(
            state.handle(momentum(x: -80, phase: .began)),
            .consume
        )
        XCTAssertEqual(
            state.handle(momentum(x: -80, phase: .changed)),
            .consume
        )
        XCTAssertEqual(
            state.handle(momentum(phase: .ended)),
            .consume
        )
        XCTAssertEqual(state.phase, .idle)
    }

    func testMomentumCannotStartHorizontalSelection() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(momentum(x: -100, phase: .began)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(momentum(x: -100, phase: .changed)),
            .passThrough
        )
        XCTAssertEqual(
            state.handle(momentum(x: -100, phase: .ended)),
            .passThrough
        )
        XCTAssertEqual(state.phase, .idle)
    }

    func testMomentumCanFinishAnAlreadyLockedGesture() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: -20, phase: .began)),
            .consume
        )
        XCTAssertEqual(
            state.handle(sample(x: -20, phase: .ended)),
            .consume
        )
        XCTAssertEqual(
            state.handle(momentum(x: -20, phase: .began)),
            .consume
        )
        XCTAssertEqual(
            state.handle(momentum(x: -6, phase: .changed)),
            .select(.next)
        )
        XCTAssertEqual(
            state.handle(momentum(x: -20, phase: .changed)),
            .consume
        )
    }

    func testNewPhysicalGestureCanSelectAfterPriorMomentumEnds() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: -66, phase: .began)),
            .select(.next)
        )
        _ = state.handle(momentum(phase: .ended))

        XCTAssertEqual(
            state.handle(sample(x: 66, phase: .began)),
            .select(.previous)
        )
    }

    func testCancellationAndExplicitResetDiscardGesture() {
        var state = HorizontalModelSwipeState()

        XCTAssertEqual(
            state.handle(sample(x: -20, phase: .began)),
            .consume
        )
        XCTAssertEqual(
            state.handle(sample(phase: .cancelled)),
            .consume
        )
        XCTAssertEqual(state.phase, .idle)

        _ = state.handle(sample(x: -20, phase: .began))
        state.reset()
        XCTAssertEqual(
            state.handle(momentum(x: -100, phase: .began)),
            .passThrough
        )
    }

    private func sample(
        x: CGFloat = 0,
        y: CGFloat = 0,
        phase: HorizontalModelSwipeSample.Phase,
        precise: Bool = true,
        shifted: Bool = false
    ) -> HorizontalModelSwipeSample {
        HorizontalModelSwipeSample(
            deltaX: x,
            deltaY: y,
            phase: phase,
            hasPreciseScrollingDeltas: precise,
            isShiftModified: shifted
        )
    }

    private func momentum(
        x: CGFloat = 0,
        y: CGFloat = 0,
        phase: HorizontalModelSwipeSample.Phase
    ) -> HorizontalModelSwipeSample {
        HorizontalModelSwipeSample(
            deltaX: x,
            deltaY: y,
            phase: .none,
            momentumPhase: phase
        )
    }
}
