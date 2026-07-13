import Darwin
import Foundation
import SQLite3
import XCTest
@testable import LLMPulse

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

    func testBatchMarkViewedPersistsEveryReceipt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        let store = ReceiptStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        _ = try await store.snapshot(now: now)
        let tasks = [
            task(threadId: "thread-1", turnId: "turn-1", at: now),
            task(threadId: "thread-2", turnId: nil, at: now),
        ]

        try await store.markViewed(tasks, at: now.addingTimeInterval(1))

        let cached = try await store.snapshot(now: now.addingTimeInterval(2))
        XCTAssertEqual(cached.viewedTaskIDs, Set(tasks.map(\.id)))
        let reopened = ReceiptStore(databaseURL: databaseURL)
        let persisted = try await reopened.snapshot(now: now.addingTimeInterval(3))
        XCTAssertEqual(persisted.viewedTaskIDs, Set(tasks.map(\.id)))
    }

    func testBatchFailureRollsBackAndInvalidatesCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        let store = ReceiptStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_200_000)
        _ = try await store.snapshot(now: now)

        do {
            let connection = try SQLiteConnection(
                url: databaseURL,
                flags: SQLITE_OPEN_READWRITE
            )
            try connection.execute(
                """
                CREATE TRIGGER reject_batch_receipt
                BEFORE INSERT ON receipts
                WHEN NEW.task_id = 'reject:turn'
                BEGIN
                    SELECT RAISE(ABORT, 'forced batch failure');
                END
                """
            )
        }

        do {
            try await store.markViewed(
                [
                    task(threadId: "good", turnId: "turn", at: now),
                    task(threadId: "reject", turnId: "turn", at: now),
                ],
                at: now.addingTimeInterval(1)
            )
            XCTFail("Expected batch receipt write to fail")
        } catch {}

        do {
            let connection = try SQLiteConnection(
                url: databaseURL,
                flags: SQLITE_OPEN_READWRITE
            )
            try connection.execute(
                """
                INSERT INTO receipts(task_id, thread_id, turn_id, viewed_at)
                VALUES ('sentinel:turn', 'sentinel', 'turn', 1700200002)
                """
            )
        }
        let refreshed = try await store.snapshot(now: now.addingTimeInterval(2))
        XCTAssertEqual(refreshed.viewedTaskIDs, ["sentinel:turn"])
        XCTAssertFalse(refreshed.viewedTaskIDs.contains("good:turn"))
    }

    func testUnmarkViewedRestoresUnreadIdentityAndLeavesOtherReceipts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        let store = ReceiptStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        let restored = task(threadId: "restored", turnId: "turn", at: now)
        let retained = task(threadId: "retained", turnId: "turn", at: now)
        _ = try await store.snapshot(now: now)
        try await store.markViewed([restored, retained], at: now.addingTimeInterval(1))

        try await store.unmarkViewed([restored])

        let cached = try await store.snapshot(now: now.addingTimeInterval(2))
        XCTAssertFalse(cached.viewedTaskIDs.contains(restored.id))
        XCTAssertTrue(cached.viewedTaskIDs.contains(retained.id))
        let reopened = ReceiptStore(databaseURL: databaseURL)
        let persisted = try await reopened.snapshot(now: now.addingTimeInterval(3))
        XCTAssertEqual(persisted.viewedTaskIDs, [retained.id])
        XCTAssertEqual(persisted.baselineAt, now)
        XCTAssertTrue(
            (restored.completedAt ?? .distantPast) >= persisted.baselineAt
                && !persisted.viewedTaskIDs.contains(restored.id)
        )
    }

    func testFailedUnmarkInvalidatesCacheSoNextHealthProbeFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        let store = ReceiptStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_400_000)
        let viewed = task(threadId: "thread", turnId: "turn", at: now)
        _ = try await store.snapshot(now: now)
        try await store.markViewed(viewed, at: now)

        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: false)
        do {
            try await store.unmarkViewed(viewed)
            XCTFail("Expected receipt delete to fail")
        } catch {}

        do {
            _ = try await store.snapshot(now: now)
            XCTFail("Expected the next health probe to reopen and fail")
        } catch {}
    }

    func testReceiptDatabaseSymlinkIsRejectedWithoutTouchingTarget() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("support", isDirectory: true)
        let target = root.appendingPathComponent("target.sqlite")
        let databaseURL = directory.appendingPathComponent("receipts.sqlite")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: databaseURL,
            withDestinationURL: target
        )

        do {
            _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
            XCTFail("Expected a receipt symlink to fail closed")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
        XCTAssertNotNil(
            try FileManager.default.destinationOfSymbolicLink(atPath: databaseURL.path)
        )
    }

    func testReceiptDatabaseHardLinkIsRejectedBeforeSQLiteOpen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.sqlite")
        let databaseURL = root.appendingPathComponent("receipts.sqlite")
        _ = try await ReceiptStore(databaseURL: target).snapshot()
        try FileManager.default.linkItem(at: target, to: databaseURL)

        do {
            _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
            XCTFail("Expected a hard-linked receipt database to fail closed")
        } catch let DataAdapterError.sqlite(message) {
            XCTAssertEqual(message, "Receipt file failed safety validation")
        } catch {
            XCTFail("Unexpected receipt error: \(error)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let linkCount = try XCTUnwrap(attributes[.referenceCount] as? NSNumber)
        XCTAssertEqual(linkCount.intValue, 2)
    }

    func testReceiptStoreRejectsMismatchedDirectoryOwnerEvidence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("receipts.sqlite")
        _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()

        do {
            _ = try await ReceiptStore(
                databaseURL: databaseURL,
                currentUserID: geteuid() &+ 1
            ).snapshot()
            XCTFail("Expected mismatched receipt directory owner to fail closed")
        } catch let DataAdapterError.sqlite(message) {
            XCTAssertEqual(message, "Receipt directory failed safety validation")
        } catch {
            XCTFail("Unexpected receipt error: \(error)")
        }
    }

    func testReceiptStoreRejectsGroupWritableDirectoryBeforeCreatingDatabase() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o770]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770],
            ofItemAtPath: root.path
        )
        let databaseURL = root.appendingPathComponent("receipts.sqlite")

        do {
            _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
            XCTFail("Expected group-writable receipt directory to fail closed")
        } catch let DataAdapterError.sqlite(message) {
            XCTAssertEqual(message, "Receipt directory failed safety validation")
        } catch {
            XCTFail("Unexpected receipt error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testReceiptStoreRejectsGroupWritableDatabase() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("receipts.sqlite")
        _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o660],
            ofItemAtPath: databaseURL.path
        )

        do {
            _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
            XCTFail("Expected group-writable receipt database to fail closed")
        } catch let DataAdapterError.sqlite(message) {
            XCTAssertEqual(message, "Receipt file failed safety validation")
        } catch {
            XCTFail("Unexpected receipt error: \(error)")
        }
    }

    func testReceiptDirectorySymlinkIsRejectedWithoutCreatingTargetFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: supportDirectory,
            withDestinationURL: targetDirectory
        )

        do {
            _ = try await ReceiptStore(
                databaseURL: supportDirectory.appendingPathComponent("receipts.sqlite")
            ).snapshot()
            XCTFail("Expected a receipt directory symlink to fail closed")
        } catch {}

        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path).isEmpty
        )
    }

    func testReceiptJournalSymlinkIsRejectedBeforeSQLiteOpen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("receipts.sqlite")
        _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
        let target = root.appendingPathComponent("journal-target")
        let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: journalURL,
            withDestinationURL: target
        )

        do {
            _ = try await ReceiptStore(databaseURL: databaseURL).snapshot()
            XCTFail("Expected a receipt journal symlink to fail closed")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
    }

    private func task(
        threadId: String,
        turnId: String?,
        at date: Date
    ) -> PulseTask {
        PulseTask(
            threadId: threadId,
            turnId: turnId,
            title: "Task",
            projectDirectory: "/tmp/project",
            state: .completed,
            startedAt: date.addingTimeInterval(-1),
            updatedAt: date,
            completedAt: date,
            lastStatus: "completed",
            isUnread: true
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
