import XCTest
@testable import GPTPulse

final class NotificationServiceTests: XCTestCase {
    func testNotificationRouteRoundTripsTaskAndThreadIdentifiers() throws {
        let route = TaskNotificationRoute(
            taskID: "thread-1:turn-4",
            threadID: "thread-1"
        )

        let decoded = try XCTUnwrap(TaskNotificationRoute(userInfo: route.userInfo))
        XCTAssertEqual(decoded, route)
    }

    func testNotificationRouteRejectsIncompletePayload() {
        XCTAssertNil(TaskNotificationRoute(userInfo: ["threadID": "thread-1"]))
        XCTAssertNil(TaskNotificationRoute(userInfo: ["taskID": "task-1"]))
        XCTAssertNil(TaskNotificationRoute(userInfo: ["taskID": "", "threadID": "thread-1"]))
    }

    func testInitialPlaceholderAndFirstRealSnapshotDoNotSendNotifications() {
        var tracker = TaskNotificationTransitionTracker()
        let existingTask = makeTask(state: .completed)

        XCTAssertTrue(tracker.notifications(in: .empty).isEmpty)
        XCTAssertTrue(
            tracker.notifications(
                in: TaskSnapshot(
                    tasks: [existingTask],
                    refreshedAt: Date(timeIntervalSince1970: 200),
                    health: []
                )
            ).isEmpty
        )
    }

    func testStateChangeAfterInitialSnapshotProducesNotification() throws {
        var tracker = TaskNotificationTransitionTracker()
        let runningTask = makeTask(state: .running)
        let initialSnapshot = TaskSnapshot(
            tasks: [runningTask],
            refreshedAt: Date(timeIntervalSince1970: 200),
            health: []
        )
        XCTAssertTrue(tracker.notifications(in: initialSnapshot).isEmpty)

        let completedTask = makeTask(state: .completed)
        let notifications = tracker.notifications(
            in: TaskSnapshot(
                tasks: [completedTask],
                refreshedAt: Date(timeIntervalSince1970: 210),
                health: []
            )
        )

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(try XCTUnwrap(notifications.first).task.id, completedTask.id)
        XCTAssertEqual(try XCTUnwrap(notifications.first).kind.rawValue, "completed")
    }

    private func makeTask(state: PulseTaskState) -> PulseTask {
        PulseTask(
            threadId: "thread-1",
            turnId: "turn-1",
            title: "测试任务",
            projectDirectory: "/tmp/project",
            state: state,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            completedAt: state.isTerminal ? Date(timeIntervalSince1970: 110) : nil,
            lastStatus: state.rawValue,
            isUnread: state == .completed
        )
    }
}
