import Foundation
import SQLite3
import XCTest
@testable import GPTPulse

final class CodexAgentActivityObserverTests: XCTestCase {
    func testFirstReadIsImmediateThenRecursivelyCountsOpenActiveAgents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()

        let root = fixture.rolloutURL("root")
        let child = fixture.rolloutURL("child")
        let grandchild = fixture.rolloutURL("grandchild")
        let completed = fixture.rolloutURL("completed")
        let closed = fixture.rolloutURL("closed")

        try fixture.writeRootRollout(
            to: root,
            threadID: "root",
            at: now.addingTimeInterval(-3),
            activities: [
                fixture.activity("child", kind: "started", at: now.addingTimeInterval(-2.5)),
                fixture.activity("completed", kind: "started", at: now.addingTimeInterval(-2.4)),
                fixture.activity("closed", kind: "started", at: now.addingTimeInterval(-2.3)),
            ]
        )
        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-2.5),
            events: [
                fixture.lifecycle("task_started", at: now.addingTimeInterval(-2.4)),
                fixture.activity("grandchild", kind: "started", at: now.addingTimeInterval(-2.2)),
            ]
        )
        try fixture.writeSubagentRollout(
            to: grandchild,
            threadID: "grandchild",
            parentThreadID: "child",
            at: now.addingTimeInterval(-2.2),
            events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-2.1))]
        )
        try fixture.writeSubagentRollout(
            to: completed,
            threadID: "completed",
            parentThreadID: "root",
            at: now.addingTimeInterval(-2.4),
            events: [
                fixture.lifecycle("task_started", at: now.addingTimeInterval(-2.3)),
                fixture.lifecycle("task_complete", at: now.addingTimeInterval(-2)),
            ]
        )
        try fixture.writeSubagentRollout(
            to: closed,
            threadID: "closed",
            parentThreadID: "root",
            at: now.addingTimeInterval(-2.3),
            events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-2.2))]
        )

        let database = try fixture.createDatabase(
            threads: [
                ("root", root, now.addingTimeInterval(-3)),
                ("child", child, now.addingTimeInterval(-2.5)),
                ("grandchild", grandchild, now.addingTimeInterval(-2.2)),
                ("completed", completed, now.addingTimeInterval(-2.4)),
                ("closed", closed, now.addingTimeInterval(-2.3)),
            ],
            edges: [
                ("root", "child", "open"),
                ("child", "grandchild", "open"),
                ("root", "completed", "open"),
                ("root", "closed", "closed"),
            ]
        )
        let databaseBefore = try Data(contentsOf: database)
        let observer = CodexAgentActivityObserver(
            databaseCandidates: [database],
            refreshInterval: 1
        )

        let startedAt = Date()
        let first = await observer.observations(rootStates: ["root": .running], now: now)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.25)
        XCTAssertEqual(first["root"]?.confidence, .provisional)
        XCTAssertNil(first["root"]?.activeCount)

        await observer.waitForCurrentRefreshForTesting()
        let resolved = await observer.observations(rootStates: ["root": .running], now: now)
        XCTAssertEqual(resolved["root"]?.activeCount, 3)
        XCTAssertEqual(resolved["root"]?.confidence, .exact)
        XCTAssertEqual(try Data(contentsOf: database), databaseBefore)

        let terminal = await refresh(
            observer,
            rootStates: ["root": .completed],
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(terminal["root"]?.activeCount, 2)
        XCTAssertEqual(terminal["root"]?.confidence, .exact)
    }

    func testFollowUpOverridesCompletionAndInterruptedThenPartialTerminalCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let root = fixture.rolloutURL("root")
        let child = fixture.rolloutURL("child")

        try fixture.writeRootRollout(
            to: root,
            threadID: "root",
            at: now.addingTimeInterval(-3),
            activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-2.8))]
        )
        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-2.8),
            events: [
                fixture.lifecycle("task_started", at: now.addingTimeInterval(-2.7)),
                fixture.lifecycle("task_complete", at: now.addingTimeInterval(-2.5)),
            ]
        )
        let database = try fixture.createDatabase(
            threads: [
                ("root", root, now.addingTimeInterval(-3)),
                ("child", child, now.addingTimeInterval(-2.8)),
            ],
            edges: [("root", "child", "open")]
        )
        let observer = CodexAgentActivityObserver(
            databaseCandidates: [database],
            refreshInterval: 1
        )

        var result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertEqual(result["root"]?.activeCount, 1)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        try fixture.appendJSON(
            fixture.lifecycle("task_started", at: now.addingTimeInterval(2)),
            to: child
        )
        try fixture.appendLargeIrrelevantLine(byteCount: 80 * 1_024, to: child)
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(
            result["root"]?.observedAt.timeIntervalSince1970,
            Optional(now.addingTimeInterval(3).timeIntervalSince1970)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        let terminalData = try fixture.jsonData(
            fixture.lifecycle("task_complete", at: now.addingTimeInterval(4)),
            newline: false
        )
        let split = terminalData.count / 2
        try fixture.appendData(terminalData.prefix(split), to: child)
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)

        try fixture.appendData(terminalData.suffix(from: split), to: child)
        try fixture.appendData(Data([0x0A]), to: child)
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(7)
        )
        XCTAssertEqual(result["root"]?.activeCount, 1)

        try fixture.appendJSON(
            fixture.activity("child", kind: "interrupted", at: now.addingTimeInterval(8)),
            to: root
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(9)
        )
        XCTAssertEqual(result["root"]?.activeCount, 1)

        try fixture.appendJSON(
            fixture.activity("child", kind: "interacted", at: now.addingTimeInterval(10)),
            to: root
        )
        try fixture.appendJSON(
            fixture.lifecycle("task_started", at: now.addingTimeInterval(11)),
            to: child
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(12)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        try fixture.appendJSON(
            fixture.lifecycle("error", at: now.addingTimeInterval(13)),
            to: child
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(14)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(17)
        )
        XCTAssertEqual(result["root"]?.activeCount, 1)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        try fixture.appendJSON(
            fixture.lifecycle("agent_message", at: now.addingTimeInterval(18)),
            to: child
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(19)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        try fixture.appendJSON(
            fixture.lifecycle("task_complete", at: now.addingTimeInterval(20)),
            to: child
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(21)
        )
        XCTAssertEqual(result["root"]?.activeCount, 1)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        try fixture.appendJSON(
            fixture.lifecycle("task_started", at: now.addingTimeInterval(22)),
            to: child
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(23)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)
    }

    func testActiveChildIsOnlyProvisionalWhenParentRolloutIsUnavailable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let missingRoot = fixture.rolloutURL("missing-root")
        let child = fixture.rolloutURL("child")

        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-2),
            events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-1))]
        )
        let database = try fixture.createDatabase(
            threads: [
                ("root", missingRoot, now.addingTimeInterval(-2)),
                ("child", child, now.addingTimeInterval(-2)),
            ],
            edges: [("root", "child", "open")]
        )
        let observer = CodexAgentActivityObserver(databaseCandidates: [database])

        let result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .provisional)
    }

    func testLargeUnscannedFollowUpNeverReusesOldTerminalAsExact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let root = fixture.rolloutURL("root")
        let child = fixture.rolloutURL("child")
        try fixture.writeRootRollout(
            to: root,
            threadID: "root",
            at: now.addingTimeInterval(-2),
            activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-1.8))]
        )
        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-1.8),
            events: [
                fixture.lifecycle("task_started", at: now.addingTimeInterval(-1.7)),
                fixture.lifecycle("task_complete", at: now.addingTimeInterval(-1.5)),
            ]
        )
        let database = try fixture.createDatabase(
            threads: [
                ("root", root, now.addingTimeInterval(-2)),
                ("child", child, now.addingTimeInterval(-1.8)),
            ],
            edges: [("root", "child", "open")]
        )
        let observer = CodexAgentActivityObserver(
            databaseCandidates: [database],
            refreshInterval: 1
        )
        var result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertEqual(result["root"]?.activeCount, 1)
        XCTAssertEqual(result["root"]?.confidence, .exact)

        try fixture.appendJSON(
            fixture.lifecycle("task_started", at: now.addingTimeInterval(2)),
            to: child
        )
        try fixture.appendLargeIrrelevantLine(byteCount: 1_100_000, to: child)
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .provisional)

        try fixture.appendJSON(
            fixture.lifecycle("task_started", at: now.addingTimeInterval(4)),
            to: child
        )
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)
    }

    func testTailExpandsPastInteractedAndLargePayloadToFindSpawnAndLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let root = fixture.rolloutURL("root")
        let child = fixture.rolloutURL("child")
        try fixture.writeRootRollout(
            to: root,
            threadID: "root",
            at: now.addingTimeInterval(-3),
            activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-2.5))]
        )
        try fixture.appendLargeIrrelevantLine(byteCount: 100 * 1_024, to: root)
        try fixture.appendJSON(
            fixture.activity("child", kind: "interacted", at: now.addingTimeInterval(-1)),
            to: root
        )
        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-2.5),
            events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-2.4))]
        )
        try fixture.appendLargeIrrelevantLine(byteCount: 100 * 1_024, to: child)
        let database = try fixture.createDatabase(
            threads: [
                ("root", root, now.addingTimeInterval(-3)),
                ("child", child, now.addingTimeInterval(-2.5)),
            ],
            edges: [("root", "child", "open")]
        )
        let observer = CodexAgentActivityObserver(
            databaseCandidates: [database],
            refreshInterval: 1
        )

        let result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)
    }

    func testParentGrowthExpandsToFindInterruptedBeforeLargeTail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let root = fixture.rolloutURL("root")
        let child = fixture.rolloutURL("child")
        try fixture.writeRootRollout(
            to: root,
            threadID: "root",
            at: now.addingTimeInterval(-2),
            activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-1.8))]
        )
        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-1.8),
            events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-1.7))]
        )
        let database = try fixture.createDatabase(
            threads: [
                ("root", root, now.addingTimeInterval(-2)),
                ("child", child, now.addingTimeInterval(-1.8)),
            ],
            edges: [("root", "child", "open")]
        )
        let observer = CodexAgentActivityObserver(
            databaseCandidates: [database],
            refreshInterval: 1
        )
        var result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertEqual(result["root"]?.activeCount, 2)

        try fixture.appendJSON(
            fixture.activity("child", kind: "interrupted", at: now.addingTimeInterval(2)),
            to: root
        )
        try fixture.appendLargeIrrelevantLine(byteCount: 80 * 1_024, to: root)
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(result["root"]?.activeCount, 1)
        XCTAssertEqual(result["root"]?.confidence, .exact)
    }

    func testMetadataMismatchCorruptLineAndGraphCycleAreUnavailable() async throws {
        let now = Date()

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let root = fixture.rolloutURL("root")
            let child = fixture.rolloutURL("child")
            try fixture.writeRootRollout(
                to: root,
                threadID: "root",
                at: now.addingTimeInterval(-2),
                activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-1.8))]
            )
            try fixture.writeSubagentRollout(
                to: child,
                threadID: "wrong-child",
                parentThreadID: "root",
                at: now.addingTimeInterval(-1.8),
                events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-1.7))]
            )
            let database = try fixture.createDatabase(
                threads: [
                    ("root", root, now.addingTimeInterval(-2)),
                    ("child", child, now.addingTimeInterval(-1.8)),
                ],
                edges: [("root", "child", "open")]
            )
            let observer = CodexAgentActivityObserver(databaseCandidates: [database])
            let result = await refresh(observer, rootStates: ["root": .running], now: now)
            XCTAssertNil(result["root"]?.activeCount)
            XCTAssertEqual(result["root"]?.confidence, .unavailable)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let root = fixture.rolloutURL("root")
            let child = fixture.rolloutURL("child")
            try fixture.writeRootRollout(
                to: root,
                threadID: "root",
                at: now.addingTimeInterval(-2),
                activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-1.8))]
            )
            try fixture.writeSubagentRollout(
                to: child,
                threadID: "child",
                parentThreadID: "root",
                at: now.addingTimeInterval(-1.8),
                events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-1.7))]
            )
            try fixture.appendData(Data("{broken json}\n".utf8), to: child)
            let database = try fixture.createDatabase(
                threads: [
                    ("root", root, now.addingTimeInterval(-2)),
                    ("child", child, now.addingTimeInterval(-1.8)),
                ],
                edges: [("root", "child", "open")]
            )
            let observer = CodexAgentActivityObserver(databaseCandidates: [database])
            let result = await refresh(observer, rootStates: ["root": .running], now: now)
            XCTAssertNil(result["root"]?.activeCount)
            XCTAssertEqual(result["root"]?.confidence, .unavailable)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let root = fixture.rolloutURL("root")
            let a = fixture.rolloutURL("a")
            let b = fixture.rolloutURL("b")
            try fixture.writeRootRollout(to: root, threadID: "root", at: now, activities: [])
            try fixture.writeSubagentRollout(
                to: a,
                threadID: "a",
                parentThreadID: "root",
                at: now,
                events: []
            )
            try fixture.writeSubagentRollout(
                to: b,
                threadID: "b",
                parentThreadID: "a",
                at: now,
                events: []
            )
            let database = try fixture.createDatabase(
                threads: [("root", root, now), ("a", a, now), ("b", b, now)],
                edges: [("root", "a", "open"), ("a", "b", "open"), ("b", "a", "open")]
            )
            let observer = CodexAgentActivityObserver(databaseCandidates: [database])
            let result = await refresh(observer, rootStates: ["root": .running], now: now)
            XCTAssertNil(result["root"]?.activeCount)
            XCTAssertEqual(result["root"]?.confidence, .unavailable)
        }
    }

    func testOldActiveLifecycleRemainsExactUntilReadFailureKeepsLastCountAsStale() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let root = fixture.rolloutURL("root")
        let child = fixture.rolloutURL("child")
        try fixture.writeRootRollout(
            to: root,
            threadID: "root",
            at: now.addingTimeInterval(-700),
            activities: [fixture.activity("child", kind: "started", at: now.addingTimeInterval(-650))]
        )
        try fixture.writeSubagentRollout(
            to: child,
            threadID: "child",
            parentThreadID: "root",
            at: now.addingTimeInterval(-650),
            events: [fixture.lifecycle("task_started", at: now.addingTimeInterval(-600))]
        )
        let database = try fixture.createDatabase(
            threads: [
                ("root", root, now.addingTimeInterval(-700)),
                ("child", child, now.addingTimeInterval(-650)),
            ],
            edges: [("root", "child", "open")]
        )
        let observer = CodexAgentActivityObserver(
            databaseCandidates: [database],
            refreshInterval: 1
        )
        var result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .exact)
        let lastSuccessfulObservation = try XCTUnwrap(result["root"]?.observedAt)
        XCTAssertEqual(
            lastSuccessfulObservation.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.01
        )

        try FileManager.default.removeItem(at: database)
        result = await refresh(
            observer,
            rootStates: ["root": .running],
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(result["root"]?.activeCount, 2)
        XCTAssertEqual(result["root"]?.confidence, .stale)
    }

    func testMissingDatabaseIsUnavailableInsteadOfZero() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state_5.sqlite")
        let observer = CodexAgentActivityObserver(databaseCandidates: [missing])
        let now = Date()
        let result = await refresh(observer, rootStates: ["root": .running], now: now)
        XCTAssertNil(result["root"]?.activeCount)
        XCTAssertEqual(result["root"]?.confidence, .unavailable)
    }

    private func refresh(
        _ observer: CodexAgentActivityObserver,
        rootStates: [String: PulseTaskState],
        now: Date
    ) async -> [String: AgentActivityObservation] {
        _ = await observer.observations(rootStates: rootStates, now: now)
        await observer.waitForCurrentRefreshForTesting()
        return await observer.observations(rootStates: rootStates, now: now)
    }
}

private final class Fixture {
    typealias ThreadRow = (id: String, rollout: URL, createdAt: Date)
    typealias EdgeRow = (parent: String, child: String, status: String)

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTPulse-AgentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func rolloutURL(_ name: String) -> URL {
        root.appendingPathComponent("\(name).jsonl")
    }

    func writeRootRollout(
        to url: URL,
        threadID: String,
        at date: Date,
        activities: [[String: Any]]
    ) throws {
        var lines = [sessionMetadata(
            threadID: threadID,
            parentThreadID: nil,
            threadSource: "user",
            at: date
        )]
        lines.append(contentsOf: activities)
        try writeJSONLines(lines, to: url)
    }

    func writeSubagentRollout(
        to url: URL,
        threadID: String,
        parentThreadID: String,
        at date: Date,
        events: [[String: Any]]
    ) throws {
        var lines = [sessionMetadata(
            threadID: threadID,
            parentThreadID: parentThreadID,
            threadSource: "subagent",
            at: date
        )]
        lines.append(contentsOf: events)
        try writeJSONLines(lines, to: url)
    }

    func sessionMetadata(
        threadID: String,
        parentThreadID: String?,
        threadSource: String,
        at date: Date
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": threadID,
            "thread_source": threadSource,
            "timestamp": date.ISO8601Format(),
            "source": "vscode",
        ]
        if let parentThreadID {
            payload["parent_thread_id"] = parentThreadID
        }
        return [
            "type": "session_meta",
            "timestamp": date.ISO8601Format(),
            "payload": payload,
        ]
    }

    func lifecycle(_ type: String, at date: Date) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": date.ISO8601Format(),
            "payload": [
                "type": type,
                "turn_id": "turn-\(Int(date.timeIntervalSince1970 * 1_000))",
                "started_at": date.timeIntervalSince1970,
            ],
        ]
    }

    func activity(_ child: String, kind: String, at date: Date) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": date.ISO8601Format(),
            "payload": [
                "type": "sub_agent_activity",
                "agent_thread_id": child,
                "kind": kind,
                "occurred_at_ms": Int64(date.timeIntervalSince1970 * 1_000),
            ],
        ]
    }

    func createDatabase(
        threads: [ThreadRow],
        edges: [EdgeRow]
    ) throws -> URL {
        let url = root.appendingPathComponent("state_5.sqlite")
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        )
        try connection.execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                created_at_ms INTEGER
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT,
                child_thread_id TEXT,
                status TEXT
            )
            """
        )
        for thread in threads {
            try connection.execute(
                "INSERT INTO threads(id, rollout_path, created_at_ms) VALUES (?, ?, ?)",
                bindings: [
                    .text(thread.id),
                    .text(thread.rollout.path),
                    .integer(Int64(thread.createdAt.timeIntervalSince1970 * 1_000)),
                ]
            )
        }
        for edge in edges {
            try connection.execute(
                "INSERT INTO thread_spawn_edges(parent_thread_id, child_thread_id, status) VALUES (?, ?, ?)",
                bindings: [.text(edge.parent), .text(edge.child), .text(edge.status)]
            )
        }
        return url
    }

    func appendLargeIrrelevantLine(byteCount: Int, to url: URL) throws {
        try appendJSON([
            "type": "event_msg",
            "timestamp": Date().ISO8601Format(),
            "payload": [
                "type": "agent_message_delta",
                "ignored": String(repeating: "x", count: max(0, byteCount)),
            ],
        ], to: url)
    }

    func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        var data = Data()
        for object in objects {
            data.append(try jsonData(object, newline: true))
        }
        try data.write(to: url)
    }

    func appendJSON(_ object: [String: Any], to url: URL) throws {
        try appendData(try jsonData(object, newline: true), to: url)
    }

    func jsonData(_ object: [String: Any], newline: Bool) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if newline { data.append(0x0A) }
        return data
    }

    func appendData<D: DataProtocol>(_ data: D, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(data))
    }
}
