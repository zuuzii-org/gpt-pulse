import Foundation
import XCTest
@testable import LLMPulse

final class RolloutJSONLTailParserTests: XCTestCase {
    private let threadId = "thread-1"
    private let turnId = "turn-1"
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testRunningAndCompletedLifecycle() throws {
        let parser = RolloutJSONLTailParser()
        let running = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: [
                    "turn_id": turnId,
                    "started_at": start.timeIntervalSince1970,
                ]),
            ]),
            fileModificationDate: start,
            now: start
        )

        XCTAssertEqual(running?.state, .running)
        XCTAssertEqual(running?.turnId, turnId)

        let completion = start.addingTimeInterval(10)
        let completed = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: [
                    "turn_id": turnId,
                    "started_at": start.timeIntervalSince1970,
                ]),
                event("task_complete", timestamp: completion, payload: [
                    "turn_id": turnId,
                    "completed_at": completion.timeIntervalSince1970,
                ]),
            ]),
            fileModificationDate: completion,
            now: completion
        )

        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(completed?.completedAt, completion)
    }

    func testUnmatchedRequestUserInputWaitsAndOutputResumes() throws {
        let parser = RolloutJSONLTailParser()
        let call = responseItem(
            "function_call",
            timestamp: start.addingTimeInterval(1),
            payload: ["name": "request_user_input", "call_id": "call-1"]
        )

        let waiting = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                call,
            ]),
            fileModificationDate: start.addingTimeInterval(1),
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(waiting?.state, .waitingForAnswer)

        let resumed = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                call,
                responseItem(
                    "function_call_output",
                    timestamp: start.addingTimeInterval(2),
                    payload: ["call_id": "call-1"]
                ),
            ]),
            fileModificationDate: start.addingTimeInterval(2),
            now: start.addingTimeInterval(2)
        )
        XCTAssertEqual(resumed?.state, .running)
    }

    func testInterruptedAndQuietErrorMapping() throws {
        let parser = RolloutJSONLTailParser(failureQuietPeriod: 3)
        let interrupted = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("turn_aborted", timestamp: start.addingTimeInterval(1), payload: [
                    "turn_id": turnId,
                    "reason": "interrupted",
                ]),
            ]),
            fileModificationDate: start.addingTimeInterval(1),
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(interrupted?.state, .interrupted)

        let failed = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("error", timestamp: start.addingTimeInterval(1), payload: [:]),
            ]),
            fileModificationDate: start.addingTimeInterval(1),
            now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(failed?.state, .failed)
    }

    func testFreshActivityWithoutLifecycleStillMapsToRunning() throws {
        let parser = RolloutJSONLTailParser(activeFileFreshness: 10)
        let activityAt = start.addingTimeInterval(20)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("agent_reasoning", timestamp: activityAt, payload: [:]),
            ]),
            fileModificationDate: activityAt,
            now: activityAt.addingTimeInterval(1)
        )

        XCTAssertEqual(status?.state, .running)
        XCTAssertEqual(status?.updatedAt, activityAt)
    }

    func testCompletionDurationRecoversStartWhenStartEventIsOutsideTail() throws {
        let parser = RolloutJSONLTailParser()
        let completion = start.addingTimeInterval(120)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_complete", timestamp: completion, payload: [
                    "turn_id": turnId,
                    "completed_at": completion.timeIntervalSince1970,
                    "duration_ms": 4_000,
                ]),
            ]),
            fileModificationDate: completion,
            now: completion
        )

        XCTAssertEqual(status?.state, .completed)
        XCTAssertEqual(status?.startedAt, completion.addingTimeInterval(-4))
    }

    func testIncrementalOutputClearsPersistedPendingInputCall() throws {
        let parser = RolloutJSONLTailParser()
        let waiting = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                responseItem(
                    "function_call",
                    timestamp: start,
                    payload: ["name": "request_user_input", "call_id": "call-1"]
                ),
                responseItem(
                    "function_call",
                    timestamp: start,
                    payload: ["name": "request_user_input", "call_id": "call-2"]
                ),
            ]),
            fileModificationDate: start,
            now: start
        )
        XCTAssertEqual(waiting?.state, .waitingForAnswer)

        let resumed = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                responseItem(
                    "function_call_output",
                    timestamp: start.addingTimeInterval(1),
                    payload: ["call_id": "call-1"]
                ),
            ]),
            fileModificationDate: start.addingTimeInterval(1),
            now: start.addingTimeInterval(1),
            initialStatus: waiting
        )
        XCTAssertEqual(resumed?.state, .waitingForAnswer)
        XCTAssertEqual(resumed?.pendingInputCallIDs, ["call-2"])

        let fullyResumed = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                responseItem(
                    "function_call_output",
                    timestamp: start.addingTimeInterval(2),
                    payload: ["call_id": "call-2"]
                ),
            ]),
            fileModificationDate: start.addingTimeInterval(2),
            now: start.addingTimeInterval(2),
            initialStatus: resumed
        )
        XCTAssertEqual(fullyResumed?.state, .running)
        XCTAssertTrue(fullyResumed?.pendingInputCallIDs.isEmpty == true)
    }

    func testErrorRequiresLastActivityAndReevaluatesQuietDeadline() throws {
        let parser = RolloutJSONLTailParser(failureQuietPeriod: 3)
        let errorAt = start.addingTimeInterval(1)
        let initial = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("error", timestamp: errorAt, payload: [:]),
            ]),
            fileModificationDate: errorAt,
            now: errorAt
        )
        XCTAssertEqual(initial?.state, .running)

        let quietFailure = parser.reevaluate(
            initial,
            fileModificationDate: errorAt,
            now: errorAt.addingTimeInterval(4)
        )
        XCTAssertEqual(quietFailure?.state, .failed)

        let recovered = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("agent_message", timestamp: errorAt.addingTimeInterval(5), payload: [:]),
            ]),
            fileModificationDate: errorAt.addingTimeInterval(5),
            now: errorAt.addingTimeInterval(5),
            initialStatus: quietFailure
        )
        XCTAssertEqual(recovered?.state, .running)
    }

    func testTokenTelemetryUsesLatestCumulativeSnapshotAndSurvivesNullIncrement() throws {
        let parser = RolloutJSONLTailParser()
        let firstUsage = tokenUsage(
            input: 100,
            cached: 40,
            output: 20,
            reasoning: 5
        )
        let latestUsage = tokenUsage(
            input: 180,
            cached: 90,
            output: 35,
            reasoning: 8
        )
        let initial = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: start.addingTimeInterval(1), payload: [
                    "info": [
                        "total_token_usage": firstUsage,
                        "last_token_usage": firstUsage,
                    ],
                    "rate_limits": NSNull(),
                ]),
                event("token_count", timestamp: start.addingTimeInterval(2), payload: [
                    "info": [
                        "total_token_usage": firstUsage,
                        "last_token_usage": tokenUsage(
                            input: 9_000,
                            cached: 8_000,
                            output: 700,
                            reasoning: 600
                        ),
                    ],
                    "rate_limits": NSNull(),
                ]),
                event("token_count", timestamp: start.addingTimeInterval(3), payload: [
                    "info": [
                        "total_token_usage": latestUsage,
                        "last_token_usage": latestUsage,
                    ],
                    "rate_limits": NSNull(),
                ]),
            ]),
            fileModificationDate: start.addingTimeInterval(3),
            now: start.addingTimeInterval(3)
        )

        XCTAssertEqual(
            initial?.tokenUsage,
            TokenUsageSnapshot(
                totalTokens: 215,
                inputTokens: 180,
                cachedInputTokens: 90,
                outputTokens: 35,
                reasoningOutputTokens: 8
            )
        )

        let afterNullIncrement = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("token_count", timestamp: start.addingTimeInterval(4), payload: [
                    "info": NSNull(),
                    "rate_limits": NSNull(),
                ]),
            ]),
            fileModificationDate: start.addingTimeInterval(4),
            now: start.addingTimeInterval(4),
            initialStatus: initial
        )
        XCTAssertEqual(afterNullIncrement?.tokenUsage, initial?.tokenUsage)

        let reevaluated = parser.reevaluate(
            afterNullIncrement,
            fileModificationDate: start.addingTimeInterval(4),
            now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(reevaluated?.tokenUsage, initial?.tokenUsage)
    }

    func testWeeklyOnlyRateLimitReplacesEarlierAtomicEventAndNullDoesNotEraseIt() throws {
        let parser = RolloutJSONLTailParser()
        let firstRateAt = start.addingTimeInterval(1)
        let weeklyUpdateAt = start.addingTimeInterval(2)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: firstRateAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "plan_type": "pro",
                        "primary": rateWindow(used: 12, minutes: 300, reset: start.addingTimeInterval(300)),
                        "secondary": rateWindow(used: 30, minutes: 10_080, reset: start.addingTimeInterval(600)),
                    ],
                ]),
                event("token_count", timestamp: weeklyUpdateAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": NSNull(),
                        "plan_type": NSNull(),
                        "primary": NSNull(),
                        "secondary": rateWindow(used: 31, minutes: 10_080, reset: start.addingTimeInterval(900)),
                    ],
                ]),
                event("token_count", timestamp: start.addingTimeInterval(3), payload: [
                    "info": NSNull(),
                    "rate_limits": NSNull(),
                ]),
            ]),
            fileModificationDate: start.addingTimeInterval(3),
            now: start.addingTimeInterval(3)
        )

        XCTAssertEqual(status?.rateLimits?.updatedAt, weeklyUpdateAt)
        XCTAssertEqual(status?.rateLimits?.limitID, "codex")
        XCTAssertEqual(status?.rateLimits?.planType, "pro")
        XCTAssertNil(status?.rateLimits?.fiveHour)
        XCTAssertEqual(status?.rateLimits?.weekly?.usedPercent, 31)
        XCTAssertEqual(status?.rateLimits?.weekly?.windowMinutes, 10_080)
        XCTAssertEqual(status?.rateLimits?.weekly?.observedAt, weeklyUpdateAt)
    }

    func testMalformedLegacyFiveHourWindowDoesNotInvalidateWeeklyRolloutData() throws {
        let parser = RolloutJSONLTailParser()
        let observedAt = start.addingTimeInterval(1)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: observedAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "primary": rateWindow(
                            used: 8,
                            minutes: 10_080,
                            reset: start.addingTimeInterval(600)
                        ),
                        "secondary": [
                            "used_percent": 99,
                            "window_minutes": 300,
                        ],
                    ],
                ]),
            ]),
            fileModificationDate: observedAt,
            now: observedAt
        )

        XCTAssertNil(status?.rateLimits?.fiveHour)
        XCTAssertEqual(status?.rateLimits?.weekly?.usedPercent, 8)
        XCTAssertEqual(status?.rateLimits?.updatedAt, observedAt)
    }

    func testUnknownWindowWithoutWeeklyProducesNoRolloutRateLimitSnapshot() throws {
        let parser = RolloutJSONLTailParser()
        let observedAt = start.addingTimeInterval(1)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: observedAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "primary": rateWindow(
                            used: 8,
                            minutes: 1_440,
                            reset: start.addingTimeInterval(600)
                        ),
                        "secondary": NSNull(),
                    ],
                ]),
            ]),
            fileModificationDate: observedAt,
            now: observedAt
        )

        XCTAssertNil(status?.rateLimits)
    }

    func testLegacyFiveHourResetChangeDoesNotCreateWeeklyConflict() throws {
        let parser = RolloutJSONLTailParser()
        let firstAt = start.addingTimeInterval(1)
        let secondAt = start.addingTimeInterval(2)
        let weeklyReset = start.addingTimeInterval(1_200)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: firstAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "primary": rateWindow(used: 40, minutes: 300, reset: start.addingTimeInterval(300)),
                        "secondary": rateWindow(used: 8, minutes: 10_080, reset: weeklyReset),
                    ],
                ]),
                event("token_count", timestamp: secondAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "primary": rateWindow(used: 1, minutes: 300, reset: start.addingTimeInterval(900)),
                        "secondary": rateWindow(used: 9, minutes: 10_080, reset: weeklyReset),
                    ],
                ]),
            ]),
            fileModificationDate: secondAt,
            now: secondAt
        )

        XCTAssertEqual(status?.rateLimits?.updatedAt, secondAt)
        XCTAssertEqual(status?.rateLimits?.weekly?.usedPercent, 9)
        XCTAssertEqual(status?.rateLimits?.fiveHour?.usedPercent, 1)
        XCTAssertNil(status?.rateLimits?.conflictingResetHistoryUntil)
    }

    func testConflictingCompleteResetGroupsInOneRolloutAreMarkedAmbiguous() throws {
        let parser = RolloutJSONLTailParser()
        let firstAt = start.addingTimeInterval(1)
        let secondAt = start.addingTimeInterval(2)
        let secondWeeklyReset = start.addingTimeInterval(1_200)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: firstAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "plan_type": "pro",
                        "primary": rateWindow(used: 5, minutes: 300, reset: start.addingTimeInterval(300)),
                        "secondary": rateWindow(used: 5, minutes: 10_080, reset: start.addingTimeInterval(600)),
                    ],
                ]),
                event("token_count", timestamp: secondAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "plan_type": "pro",
                        "primary": rateWindow(used: 2, minutes: 300, reset: start.addingTimeInterval(900)),
                        "secondary": rateWindow(used: 0, minutes: 10_080, reset: secondWeeklyReset),
                    ],
                ]),
            ]),
            fileModificationDate: secondAt,
            now: secondAt
        )

        XCTAssertEqual(status?.rateLimits?.updatedAt, secondAt)
        XCTAssertEqual(status?.rateLimits?.conflictingResetHistoryUntil, secondWeeklyReset)
        XCTAssertNil(
            status?.rateLimits.flatMap {
                RolloutRateLimitSelector.select([$0], now: secondAt)
            }
        )
    }

    func testPartialDifferentLimitGroupDoesNotReplaceCompleteSnapshot() throws {
        let parser = RolloutJSONLTailParser()
        let initialAt = start.addingTimeInterval(1)
        let switchedAt = start.addingTimeInterval(2)
        let status = parser.parse(
            threadId: threadId,
            defaultStartedAt: start,
            tail: try jsonLines([
                event("task_started", timestamp: start, payload: ["turn_id": turnId]),
                event("token_count", timestamp: initialAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex",
                        "plan_type": "pro",
                        "primary": rateWindow(used: 12, minutes: 300, reset: start.addingTimeInterval(300)),
                        "secondary": rateWindow(used: 30, minutes: 10_080, reset: start.addingTimeInterval(600)),
                    ],
                ]),
                event("token_count", timestamp: switchedAt, payload: [
                    "info": NSNull(),
                    "rate_limits": [
                        "limit_id": "codex_bengalfox",
                        "plan_type": "pro",
                        "primary": rateWindow(used: 7, minutes: 300, reset: start.addingTimeInterval(900)),
                        "secondary": NSNull(),
                    ],
                ]),
            ]),
            fileModificationDate: switchedAt,
            now: switchedAt
        )

        XCTAssertEqual(status?.rateLimits?.updatedAt, initialAt)
        XCTAssertEqual(status?.rateLimits?.limitID, "codex")
        XCTAssertEqual(status?.rateLimits?.fiveHour?.usedPercent, 12)
        XCTAssertEqual(status?.rateLimits?.fiveHour?.observedAt, initialAt)
        XCTAssertEqual(status?.rateLimits?.weekly?.usedPercent, 30)
    }

    private func event(
        _ type: String,
        timestamp: Date,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "timestamp": timestamp.ISO8601Format(),
            "type": "event_msg",
            "payload": payload.merging(["type": type]) { current, _ in current },
        ]
    }

    private func responseItem(
        _ type: String,
        timestamp: Date,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "timestamp": timestamp.ISO8601Format(),
            "type": "response_item",
            "payload": payload.merging(["type": type]) { current, _ in current },
        ]
    }

    private func tokenUsage(
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int
    ) -> [String: Any] {
        [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
            "reasoning_output_tokens": reasoning,
            "total_tokens": input + output,
        ]
    }

    private func rateWindow(
        used: Double,
        minutes: Int,
        reset: Date
    ) -> [String: Any] {
        [
            "used_percent": used,
            "window_minutes": minutes,
            "resets_at": reset.timeIntervalSince1970,
        ]
    }

    private func jsonLines(_ objects: [[String: Any]]) throws -> Data {
        try objects.reduce(into: Data()) { result, object in
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
    }
}
