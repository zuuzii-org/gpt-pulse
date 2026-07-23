import Foundation
import SQLite3
import XCTest
@testable import LLMPulse

final class CodexSQLiteTaskAdapterTests: XCTestCase {
    func testReadsOnlyVerifiedDesktopRootsWithoutMutatingStateDatabase() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state_9.sqlite")

        let desktopRollout = directory.appendingPathComponent("desktop.jsonl")
        let vscodeRollout = directory.appendingPathComponent("vscode.jsonl")
        let childRollout = directory.appendingPathComponent("child.jsonl")
        try writeMetadata(
            to: desktopRollout,
            id: "desktop",
            originator: "codex_work_desktop"
        )
        try writeMetadata(to: vscodeRollout, id: "vscode", originator: "Codex VS Code")
        try writeMetadata(
            to: childRollout,
            id: "child",
            originator: "Codex Desktop",
            source: ["subagent": ["depth": 1]],
            threadSource: "subagent",
            parentThreadId: "desktop"
        )

        try createStateDatabase(
            at: databaseURL,
            rows: [
                ("desktop", desktopRollout, "user"),
                ("vscode", vscodeRollout, "user"),
                ("child", childRollout, "subagent"),
            ]
        )
        let bytesBefore = try Data(contentsOf: databaseURL)

        let result = try CodexSQLiteTaskAdapter(
            databaseCandidates: [databaseURL]
        ).loadDesktopRootThreads()

        XCTAssertEqual(result.records.map(\.threadId), ["desktop"])
        XCTAssertNil(result.records.first?.tokenUsage)
        XCTAssertEqual(result.unverifiedCandidateCount, 1)
        XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
    }

    func testReadsTokensUsedAsTotalOnlySnapshotWhenColumnExists() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state_9.sqlite")
        let rolloutURL = directory.appendingPathComponent("desktop.jsonl")
        try writeMetadata(to: rolloutURL, id: "desktop", originator: "Codex Desktop")
        try createStateDatabase(
            at: databaseURL,
            rows: [("desktop", rolloutURL, "user")]
        )

        do {
            let connection = try SQLiteConnection(
                url: databaseURL,
                flags: SQLITE_OPEN_READWRITE
            )
            try connection.execute(
                "ALTER TABLE threads ADD COLUMN tokens_used INTEGER NOT NULL DEFAULT 0"
            )
            try connection.execute(
                "UPDATE threads SET tokens_used = 123456 WHERE id = 'desktop'"
            )
        }

        let result = try CodexSQLiteTaskAdapter(
            databaseCandidates: [databaseURL]
        ).loadDesktopRootThreads()

        XCTAssertEqual(
            result.records.first?.tokenUsage,
            TokenUsageSnapshot(totalTokens: 123_456)
        )
    }

    func testRejectsIncompatibleSchemaWithoutMigration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state_10.sqlite")
        do {
            let connection = try SQLiteConnection(
                url: databaseURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            )
            try connection.execute("CREATE TABLE threads(id TEXT PRIMARY KEY)")
        }
        let bytesBefore = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(
            try CodexSQLiteTaskAdapter(databaseCandidates: [databaseURL])
                .loadDesktopRootThreads()
        )
        XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
    }

    func testFallsBackToNextReadOnlyCandidateWhenNewestSchemaIsIncompatible() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incompatibleURL = directory.appendingPathComponent("state_10.sqlite")
        let compatibleURL = directory.appendingPathComponent("state_9.sqlite")
        let rolloutURL = directory.appendingPathComponent("desktop.jsonl")
        try writeMetadata(to: rolloutURL, id: "desktop", originator: "Codex Desktop")

        do {
            let connection = try SQLiteConnection(
                url: incompatibleURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            )
            try connection.execute("CREATE TABLE threads(id TEXT PRIMARY KEY)")
        }
        try createStateDatabase(
            at: compatibleURL,
            rows: [("desktop", rolloutURL, "user")]
        )

        let result = try CodexSQLiteTaskAdapter(
            databaseCandidates: [incompatibleURL, compatibleURL]
        ).loadDesktopRootThreads()
        XCTAssertEqual(result.records.map(\.threadId), ["desktop"])
    }

    private func createStateDatabase(
        at url: URL,
        rows: [(id: String, rollout: URL, threadSource: String)]
    ) throws {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        try connection.execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                created_at_ms INTEGER,
                updated_at_ms INTEGER,
                source TEXT NOT NULL,
                thread_source TEXT,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                archived INTEGER NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT PRIMARY KEY NOT NULL,
                status TEXT NOT NULL
            )
            """
        )

        for row in rows {
            try connection.execute(
                """
                INSERT INTO threads(
                    id, rollout_path, created_at, updated_at,
                    created_at_ms, updated_at_ms, source, thread_source,
                    cwd, title, archived
                ) VALUES (?, ?, 1700000000, 1700000010, 1700000000000, 1700000010000,
                          'vscode', ?, '/tmp/project', 'Task', 0)
                """,
                bindings: [
                    .text(row.id),
                    .text(row.rollout.path),
                    .text(row.threadSource),
                ]
            )
        }
        try connection.execute(
            "INSERT INTO thread_spawn_edges VALUES ('desktop', 'child', 'running')"
        )
    }

    private func writeMetadata(
        to url: URL,
        id: String,
        originator: String,
        source: Any = "vscode",
        threadSource: String = "user",
        parentThreadId: String? = nil
    ) throws {
        var payload: [String: Any] = [
            "id": id,
            "originator": originator,
            "source": source,
            "thread_source": threadSource,
            "cwd": "/tmp/project",
            "timestamp": "2026-07-10T10:00:00Z",
        ]
        payload["parent_thread_id"] = parentThreadId
        let object: [String: Any] = [
            "type": "session_meta",
            "payload": payload,
            "timestamp": "2026-07-10T10:00:00Z",
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(to: url)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
