import Foundation
import XCTest
@testable import GPTPulse

final class StatusItemPresentationTests: XCTestCase {
    func testUsesSnapshotActiveAndRecentCompletedCounts() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "waiting", state: .waitingForAnswer),
                makeTask(id: "completed-unread", state: .completed, isUnread: true),
                makeTask(id: "completed-viewed", state: .completed, isUnread: false),
                makeTask(id: "failed", state: .failed),
                makeTask(id: "interrupted", state: .interrupted),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.activeCount, 2)
        XCTAssertEqual(presentation.recentCompletedCount, 4)
        XCTAssertEqual(presentation.title, "● 2\n✓ 4")
        XCTAssertTrue(presentation.hasFailures)
    }

    func testAccessibilityAndTooltipUseExpandedChineseLabels() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "completed", state: .completed),
                makeTask(id: "failed", state: .failed),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(
            presentation.accessibilityLabel,
            "GPT Pulse，正在运行 1 个任务，最近完成 2 个任务，存在失败"
        )
        XCTAssertEqual(
            presentation.toolTip,
            "GPT Pulse · 正在运行 1 · 最近完成 2 · 存在失败"
        )
    }

    private func makeTask(
        id: String,
        state: PulseTaskState,
        isUnread: Bool = false
    ) -> PulseTask {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return PulseTask(
            threadId: id,
            turnId: "turn-\(id)",
            title: id,
            projectDirectory: "/tmp/\(id)",
            state: state,
            startedAt: now,
            updatedAt: now,
            completedAt: state == .completed ? now : nil,
            lastStatus: state.rawValue,
            isUnread: isUnread
        )
    }
}
