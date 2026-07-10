import Foundation
import XCTest
@testable import GPTPulse

final class ReceiptStoreTests: XCTestCase {
    func testBaselinePersistsAndViewedReceiptUsesTurnIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ReceiptStore(databaseURL: databaseURL)

        let initial = try await store.snapshot(now: baseline)
        XCTAssertEqual(initial.baselineAt, baseline)
        XCTAssertTrue(initial.viewedTaskIDs.isEmpty)
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        let databasePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(databasePermissions.intValue & 0o777, 0o600)

        let task = PulseTask(
            threadId: "thread-1",
            turnId: "turn-2",
            title: "Task",
            projectDirectory: "/tmp/project",
            state: .completed,
            startedAt: baseline,
            updatedAt: baseline.addingTimeInterval(5),
            completedAt: baseline.addingTimeInterval(5),
            lastStatus: "completed",
            isUnread: true
        )
        try await store.markViewed(task, at: baseline.addingTimeInterval(6))

        let reopened = ReceiptStore(databaseURL: databaseURL)
        let snapshot = try await reopened.snapshot(now: baseline.addingTimeInterval(60))
        XCTAssertEqual(snapshot.baselineAt, baseline)
        XCTAssertEqual(snapshot.viewedTaskIDs, ["thread-1:turn-2"])
    }

    func testFailedWriteInvalidatesCacheSoNextHealthProbeFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        let store = ReceiptStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.snapshot(now: now)

        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: false)
        let task = PulseTask(
            threadId: "thread",
            title: "Task",
            projectDirectory: "/tmp",
            state: .completed,
            startedAt: now,
            updatedAt: now,
            completedAt: now,
            lastStatus: "completed"
        )

        do {
            try await store.markViewed(task, at: now)
            XCTFail("Expected receipt write to fail")
        } catch {}

        do {
            _ = try await store.snapshot(now: now)
            XCTFail("Expected the next health probe to reopen and fail")
        } catch {}
    }
}
