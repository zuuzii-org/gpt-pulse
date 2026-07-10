import XCTest
@testable import GPTPulse

@MainActor
final class TaskOpeningServiceTests: XCTestCase {
    func testOpeningUnreadCompletedTaskMarksViewedAndDismisses() {
        var markedTask: PulseTask?
        var didDismiss = false
        let navigator = TaskNavigator { _ in true }
        let service = TaskOpeningService(
            navigator: navigator,
            markViewed: { markedTask = $0 },
            dismiss: { didDismiss = true }
        )
        let task = makeTask(isUnread: true)

        XCTAssertTrue(service.open(task: task))
        XCTAssertEqual(markedTask?.id, task.id)
        XCTAssertTrue(didDismiss)
    }

    func testNotificationRouteUsesMatchingTaskAndMarksItViewed() {
        var markedTask: PulseTask?
        let navigator = TaskNavigator { _ in true }
        let service = TaskOpeningService(
            navigator: navigator,
            markViewed: { markedTask = $0 },
            dismiss: {}
        )
        let task = makeTask(isUnread: true)
        let route = TaskNotificationRoute(taskID: task.id, threadID: task.threadId)

        XCTAssertTrue(service.open(route: route, currentTasks: [task]))
        XCTAssertEqual(markedTask?.id, task.id)
    }

    func testFailedNavigationDoesNotMarkOrDismiss() {
        var didMark = false
        var didDismiss = false
        let navigator = TaskNavigator { _ in false }
        let service = TaskOpeningService(
            navigator: navigator,
            markViewed: { _ in didMark = true },
            dismiss: { didDismiss = true }
        )

        XCTAssertFalse(service.open(task: makeTask(isUnread: true)))
        XCTAssertFalse(didMark)
        XCTAssertFalse(didDismiss)
    }

    private func makeTask(isUnread: Bool) -> PulseTask {
        PulseTask(
            threadId: "thread-1",
            turnId: "turn-1",
            title: "测试任务",
            projectDirectory: "/tmp/project",
            state: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            completedAt: Date(timeIntervalSince1970: 110),
            lastStatus: "完成",
            isUnread: isUnread
        )
    }
}
