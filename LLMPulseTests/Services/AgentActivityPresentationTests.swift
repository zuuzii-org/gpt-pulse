import Foundation
import XCTest
@testable import LLMPulse

final class AgentActivityPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testExactActiveCountUsesNeutralCompactValue() {
        let presentation = makePresentation(count: 3, confidence: .exact, state: .running)

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.displayText, "Agent 3")
        XCTAssertEqual(presentation.emphasis, .neutral)
        XCTAssertFalse(presentation.showsFreshnessWarning)
        XCTAssertEqual(
            presentation.helpText,
            "当前有 3 个活跃 Agent，包含主 Agent 和所有层级子 Agent；等待授权或回答也计入。"
        )
        XCTAssertEqual(presentation.accessibilityLabel, presentation.helpText)
    }

    func testExactZeroOnActiveTaskIsVisibleWarning() {
        let presentation = makePresentation(count: 0, confidence: .exact, state: .running)

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.displayText, "Agent 0")
        XCTAssertEqual(presentation.emphasis, .warning)
        XCTAssertFalse(presentation.showsFreshnessWarning)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "当前观测到 0 个活跃 Agent；活动任务通常至少包含主 Agent，请稍后刷新。"
        )
    }

    func testTerminalZeroIsHidden() {
        for state in [PulseTaskState.completed, .failed, .interrupted] {
            for confidence in [
                AgentActivityObservation.Confidence.exact,
                .provisional,
                .stale,
            ] {
                let presentation = makePresentation(
                    count: 0,
                    confidence: confidence,
                    state: state
                )

                XCTAssertFalse(
                    presentation.isVisible,
                    "Expected \(state) with \(confidence) to hide a zero badge"
                )
                XCTAssertEqual(presentation.displayText, "")
            }
        }
    }

    func testTerminalPositiveCountIsWarning() {
        let presentation = makePresentation(count: 2, confidence: .exact, state: .completed)

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.displayText, "Agent 2")
        XCTAssertEqual(presentation.emphasis, .warning)
        XCTAssertEqual(presentation.helpText, "主任务已结束，但仍有 2 个 Agent 未结束。")
    }

    func testWaitingTaskRemainsAnActiveNeutralObservation() {
        for state in [PulseTaskState.waitingForApproval, .waitingForAnswer] {
            let presentation = makePresentation(count: 1, confidence: .exact, state: state)

            XCTAssertTrue(presentation.isVisible)
            XCTAssertEqual(presentation.displayText, "Agent 1")
            XCTAssertEqual(presentation.emphasis, .neutral)
        }
    }

    func testProvisionalCountUsesApproximationMarker() {
        let presentation = makePresentation(count: 4, confidence: .provisional, state: .running)

        XCTAssertEqual(presentation.displayText, "Agent ~4")
        XCTAssertEqual(presentation.emphasis, .neutral)
        XCTAssertFalse(presentation.showsFreshnessWarning)
        XCTAssertTrue(presentation.helpText.contains("数据仍在确认中"))
    }

    func testProvisionalPositiveCountAfterTerminalIsWarning() {
        let presentation = makePresentation(
            count: 2,
            confidence: .provisional,
            state: .failed
        )

        XCTAssertEqual(presentation.displayText, "Agent ~2")
        XCTAssertEqual(presentation.emphasis, .warning)
        XCTAssertTrue(presentation.helpText.contains("主任务已结束"))
    }

    func testProvisionalWithoutCountUsesPendingValue() {
        let presentation = makePresentation(count: nil, confidence: .provisional, state: .running)

        XCTAssertEqual(presentation.displayText, "Agent …")
        XCTAssertEqual(presentation.emphasis, .neutral)
        XCTAssertEqual(presentation.accessibilityLabel, "正在确认该任务的 Agent 状态")
    }

    func testStaleCountKeepsValueAndExposesAgeAndWarning() {
        let presentation = makePresentation(
            count: 5,
            confidence: .stale,
            state: .running,
            observedAt: now.addingTimeInterval(-42)
        )

        XCTAssertEqual(presentation.displayText, "Agent 5")
        XCTAssertEqual(presentation.emphasis, .warning)
        XCTAssertTrue(presentation.showsFreshnessWarning)
        XCTAssertEqual(
            presentation.helpText,
            "上次观测到 5 个活跃 Agent，更新于 42 秒前；当前数据可能已过期。"
        )
        XCTAssertEqual(presentation.accessibilityLabel, presentation.helpText)
    }

    func testUnavailableUsesDashInsteadOfZero() {
        let presentation = makePresentation(count: nil, confidence: .unavailable, state: .running)

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.displayText, "Agent —")
        XCTAssertEqual(presentation.emphasis, .unavailable)
        XCTAssertFalse(presentation.showsFreshnessWarning)
        XCTAssertEqual(presentation.accessibilityLabel, "Agent 状态暂时不可用")
    }

    func testNegativeCountIsDefensivelyClampedToZero() {
        let presentation = makePresentation(count: -2, confidence: .exact, state: .running)

        XCTAssertEqual(presentation.displayText, "Agent 0")
        XCTAssertEqual(presentation.emphasis, .warning)
    }

    private func makePresentation(
        count: Int?,
        confidence: AgentActivityObservation.Confidence,
        state: PulseTaskState,
        observedAt: Date? = nil
    ) -> AgentActivityBadgePresentation {
        AgentActivityBadgePresentation(
            observation: AgentActivityObservation(
                activeCount: count,
                confidence: confidence,
                observedAt: observedAt ?? now
            ),
            taskState: state,
            now: now
        )
    }
}
