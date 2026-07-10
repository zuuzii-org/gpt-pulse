import XCTest
@testable import GPTPulse

@MainActor
final class TaskNavigatorTests: XCTestCase {
    func testBuildsCodexThreadURL() {
        let url = TaskNavigator.taskURL(threadID: "019abc-123")

        XCTAssertEqual(url?.absoluteString, "codex://threads/019abc-123")
    }

    func testEncodesSafeNonASCIIThreadIdentifier() {
        let url = TaskNavigator.taskURL(threadID: "任务 1")

        XCTAssertEqual(url?.scheme, "codex")
        XCTAssertEqual(url?.host, "threads")
        XCTAssertEqual(url?.path, "/任务 1")
    }

    func testRejectsEmptyOrPathLikeIdentifier() {
        XCTAssertNil(TaskNavigator.taskURL(threadID: "  "))
        XCTAssertNil(TaskNavigator.taskURL(threadID: "abc/def"))
        XCTAssertNil(TaskNavigator.taskURL(threadID: "abc\\def"))
    }

    func testOpenUsesGeneratedURL() {
        var openedURL: URL?
        let navigator = TaskNavigator { url in
            openedURL = url
            return true
        }

        XCTAssertTrue(navigator.open(threadID: "thread-42"))
        XCTAssertEqual(openedURL?.absoluteString, "codex://threads/thread-42")
    }
}
