import CoreGraphics

enum HorizontalModelSwipeDirection: Equatable, Sendable {
    case previous
    case next
}

struct HorizontalModelSwipeSample: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case none
        case began
        case changed
        case ended
        case cancelled
    }

    let deltaX: CGFloat
    let deltaY: CGFloat
    let phase: Phase
    let momentumPhase: Phase
    let hasPreciseScrollingDeltas: Bool
    let isShiftModified: Bool

    init(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: Phase,
        momentumPhase: Phase = .none,
        hasPreciseScrollingDeltas: Bool = true,
        isShiftModified: Bool = false
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.isShiftModified = isShiftModified
    }
}

struct HorizontalModelSwipeResult: Equatable, Sendable {
    enum EventDisposition: Equatable, Sendable {
        case passThrough
        case consume
    }

    let eventDisposition: EventDisposition
    let selectionDirection: HorizontalModelSwipeDirection?

    static let passThrough = HorizontalModelSwipeResult(
        eventDisposition: .passThrough,
        selectionDirection: nil
    )

    static let consume = HorizontalModelSwipeResult(
        eventDisposition: .consume,
        selectionDirection: nil
    )

    static func select(
        _ direction: HorizontalModelSwipeDirection
    ) -> HorizontalModelSwipeResult {
        HorizontalModelSwipeResult(
            eventDisposition: .consume,
            selectionDirection: direction
        )
    }
}

struct HorizontalModelSwipeState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case detecting(gestureID: UInt64, accumulatedX: CGFloat, accumulatedY: CGFloat)
        case locked(
            gestureID: UInt64,
            direction: HorizontalModelSwipeDirection,
            accumulatedX: CGFloat
        )
        case rejected(gestureID: UInt64)
        case committed(gestureID: UInt64)
    }

    private(set) var phase: Phase = .idle

    private let axisLockThreshold: CGFloat
    private let horizontalDominanceRatio: CGFloat
    private let commitThreshold: CGFloat
    private var nextGestureID: UInt64 = 0

    init(
        axisLockThreshold: CGFloat = 10,
        horizontalDominanceRatio: CGFloat = 1.3,
        commitThreshold: CGFloat = 66
    ) {
        precondition(axisLockThreshold > 0)
        precondition(horizontalDominanceRatio > 1)
        precondition(commitThreshold >= axisLockThreshold)
        self.axisLockThreshold = axisLockThreshold
        self.horizontalDominanceRatio = horizontalDominanceRatio
        self.commitThreshold = commitThreshold
    }

    mutating func handle(
        _ sample: HorizontalModelSwipeSample
    ) -> HorizontalModelSwipeResult {
        guard sample.hasPreciseScrollingDeltas, !sample.isShiftModified else {
            if sample.phase == .began {
                phase = .idle
            }
            return .passThrough
        }

        let isMomentum = sample.momentumPhase != .none
        if !isMomentum, sample.phase == .began {
            beginGesture()
        }

        let result: HorizontalModelSwipeResult
        if isMomentum {
            result = handleMomentum(sample)
        } else {
            result = handlePhysicalGesture(sample)
        }

        if sample.phase == .cancelled || sample.momentumPhase == .cancelled {
            phase = .idle
        } else if sample.momentumPhase == .ended {
            phase = .idle
        } else if sample.phase == .ended {
            switch phase {
            case .detecting:
                phase = .idle
            case .idle, .locked, .rejected, .committed:
                break
            }
        }

        return result
    }

    mutating func reset() {
        phase = .idle
    }

    private mutating func beginGesture() {
        nextGestureID &+= 1
        phase = .detecting(
            gestureID: nextGestureID,
            accumulatedX: 0,
            accumulatedY: 0
        )
    }

    private mutating func handlePhysicalGesture(
        _ sample: HorizontalModelSwipeSample
    ) -> HorizontalModelSwipeResult {
        switch phase {
        case .idle:
            return .passThrough

        case let .detecting(gestureID, accumulatedX, accumulatedY):
            return updateDetection(
                gestureID: gestureID,
                accumulatedX: accumulatedX + sample.deltaX,
                accumulatedY: accumulatedY + sample.deltaY
            )

        case let .locked(gestureID, direction, accumulatedX):
            return updateLockedGesture(
                gestureID: gestureID,
                direction: direction,
                accumulatedX: accumulatedX + sample.deltaX
            )

        case .rejected:
            return .passThrough

        case .committed:
            return .consume
        }
    }

    private mutating func handleMomentum(
        _ sample: HorizontalModelSwipeSample
    ) -> HorizontalModelSwipeResult {
        switch phase {
        case let .locked(gestureID, direction, accumulatedX):
            return updateLockedGesture(
                gestureID: gestureID,
                direction: direction,
                accumulatedX: accumulatedX + sample.deltaX
            )
        case .committed:
            return .consume
        case .idle, .detecting, .rejected:
            // Momentum may finish a gesture that was already locked, but it
            // must never establish a new horizontal gesture on its own.
            return .passThrough
        }
    }

    private mutating func updateDetection(
        gestureID: UInt64,
        accumulatedX: CGFloat,
        accumulatedY: CGFloat
    ) -> HorizontalModelSwipeResult {
        let absoluteX = abs(accumulatedX)
        let absoluteY = abs(accumulatedY)
        guard max(absoluteX, absoluteY) >= axisLockThreshold else {
            phase = .detecting(
                gestureID: gestureID,
                accumulatedX: accumulatedX,
                accumulatedY: accumulatedY
            )
            return .passThrough
        }

        if absoluteX >= absoluteY * horizontalDominanceRatio {
            let direction: HorizontalModelSwipeDirection = accumulatedX < 0
                ? .next
                : .previous
            return updateLockedGesture(
                gestureID: gestureID,
                direction: direction,
                accumulatedX: accumulatedX
            )
        }

        if absoluteY >= absoluteX * horizontalDominanceRatio {
            phase = .rejected(gestureID: gestureID)
        } else {
            phase = .detecting(
                gestureID: gestureID,
                accumulatedX: accumulatedX,
                accumulatedY: accumulatedY
            )
        }
        return .passThrough
    }

    private mutating func updateLockedGesture(
        gestureID: UInt64,
        direction: HorizontalModelSwipeDirection,
        accumulatedX: CGFloat
    ) -> HorizontalModelSwipeResult {
        let reachedCommitThreshold: Bool
        switch direction {
        case .previous:
            reachedCommitThreshold = accumulatedX >= commitThreshold
        case .next:
            reachedCommitThreshold = accumulatedX <= -commitThreshold
        }

        guard reachedCommitThreshold else {
            phase = .locked(
                gestureID: gestureID,
                direction: direction,
                accumulatedX: accumulatedX
            )
            return .consume
        }

        phase = .committed(gestureID: gestureID)
        return .select(direction)
    }
}
