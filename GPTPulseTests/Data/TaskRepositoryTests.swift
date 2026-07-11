import Foundation
import SQLite3
import XCTest
@testable import GPTPulse

final class TaskRepositoryTests: XCTestCase {
    func testNewCompletionIsUnreadThenReceiptMarksItReadWithoutRemovingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let completion = baseline.addingTimeInterval(10)
        let rolloutURL = sessions.appendingPathComponent("rollout.jsonl")
        try writeRollout(to: rolloutURL, startedAt: baseline, completedAt: completion)
        try writeSessionIndex(to: root.appendingPathComponent("session_index.jsonl"))
        let journalURL = root.appendingPathComponent("events.jsonl")
        try writeJSONLines([
            [
                "session_id": "thread-1",
                "turn_id": "turn-1",
                "cwd": "/tmp/project",
                "hook_event_name": "Stop",
                "timestamp": completion.addingTimeInterval(0.5).ISO8601Format(),
            ],
        ], to: journalURL)

        let receipts = ReceiptStore(databaseURL: root.appendingPathComponent("receipts.sqlite"))
        _ = try await receipts.snapshot(now: baseline)
        let repository = TaskRepository(
            appServerProbe: AppServerCapabilityProbe(
                controlSocketURL: root.appendingPathComponent("missing.sock")
            ),
            sqliteAdapter: CodexSQLiteTaskAdapter(databaseCandidates: []),
            rolloutAdapter: CodexRolloutAdapter(
                sessionsDirectory: sessions,
                sessionIndexURL: root.appendingPathComponent("session_index.jsonl"),
                lookback: 10_000 * 24 * 60 * 60,
                discoveryInterval: 0
            ),
            journalReader: PluginEventJournalReader(
                journalURL: journalURL
            ),
            receiptStore: receipts
        )

        var snapshot = await repository.snapshot(now: completion.addingTimeInterval(1))
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.title, "Indexed title")
        XCTAssertEqual(snapshot.tasks.first?.state, .completed)
        XCTAssertEqual(snapshot.tasks.first?.isUnread, true)

        let task = try XCTUnwrap(snapshot.tasks.first)
        try await repository.markViewed(task, at: completion.addingTimeInterval(2))
        snapshot = await repository.snapshot(now: completion.addingTimeInterval(3))
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.isUnread, false)
    }

    func testRolloutBreakdownWinsSQLiteFallbackAndRateLimitUsesLatestAtomicSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let breakdownURL = sessions.appendingPathComponent("breakdown.jsonl")
        let fallbackURL = sessions.appendingPathComponent("fallback.jsonl")
        let alternatePoolURL = sessions.appendingPathComponent("alternate-pool.jsonl")
        let staleHighWaterURL = sessions.appendingPathComponent("stale-high-water.jsonl")
        try writeRollout(
            to: breakdownURL,
            threadId: "breakdown",
            turnId: "turn-breakdown",
            startedAt: now.addingTimeInterval(-60),
            completedAt: now.addingTimeInterval(-20),
            tokenUsage: tokenUsage(input: 180, cached: 90, output: 35, reasoning: 8),
            rateUsed: 12,
            telemetryAt: now.addingTimeInterval(-30)
        )
        try writeRollout(
            to: fallbackURL,
            threadId: "fallback",
            turnId: "turn-fallback",
            startedAt: now.addingTimeInterval(-50),
            completedAt: now.addingTimeInterval(-10),
            tokenUsage: nil,
            rateUsed: 27,
            telemetryAt: now.addingTimeInterval(-15)
        )
        try writeRollout(
            to: alternatePoolURL,
            threadId: "alternate-pool",
            turnId: "turn-alternate-pool",
            startedAt: now.addingTimeInterval(-45),
            completedAt: now.addingTimeInterval(-5),
            tokenUsage: nil,
            rateUsed: 0,
            telemetryAt: now.addingTimeInterval(-8)
        )
        try writeRollout(
            to: staleHighWaterURL,
            threadId: "stale-high-water",
            turnId: "turn-stale-high-water",
            startedAt: now.addingTimeInterval(-25 * 60),
            completedAt: now.addingTimeInterval(-20 * 60),
            tokenUsage: nil,
            rateUsed: 95,
            telemetryAt: now.addingTimeInterval(-20 * 60)
        )

        let databaseURL = root.appendingPathComponent("state_5.sqlite")
        try createStateDatabase(
            at: databaseURL,
            rows: [
                ("breakdown", breakdownURL, 9_999),
                ("fallback", fallbackURL, 777),
            ]
        )
        let receipts = ReceiptStore(databaseURL: root.appendingPathComponent("receipts.sqlite"))
        _ = try await receipts.snapshot(now: now.addingTimeInterval(-120))
        let repository = makeRepository(
            root: root,
            sessions: sessions,
            sqliteCandidates: [databaseURL],
            receiptStore: receipts
        )

        let snapshot = await repository.snapshot(now: now)
        let breakdown = try XCTUnwrap(snapshot.tasks.first { $0.threadId == "breakdown" })
        XCTAssertEqual(
            breakdown.tokenUsage,
            TokenUsageSnapshot(
                totalTokens: 215,
                inputTokens: 180,
                cachedInputTokens: 90,
                outputTokens: 35,
                reasoningOutputTokens: 8
            )
        )
        let fallback = try XCTUnwrap(snapshot.tasks.first { $0.threadId == "fallback" })
        XCTAssertEqual(fallback.tokenUsage, TokenUsageSnapshot(totalTokens: 777))
        XCTAssertEqual(snapshot.rateLimits?.updatedAt, now.addingTimeInterval(-8))
        XCTAssertEqual(snapshot.rateLimits?.fiveHour?.usedPercent, 0)
        XCTAssertEqual(snapshot.rateLimits?.weekly?.usedPercent, 0)
    }

    func testAccountRateLimitsOverrideRolloutTelemetryAsOneGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_783_751_200)
        try writeRollout(
            to: sessions.appendingPathComponent("wrong-rollout-group.jsonl"),
            threadId: "wrong-rollout-group",
            turnId: "turn-wrong-rollout-group",
            startedAt: now.addingTimeInterval(-60),
            completedAt: now.addingTimeInterval(-5),
            rateUsed: 40,
            telemetryAt: now.addingTimeInterval(-10)
        )

        let official = RateLimitSnapshot(
            fiveHour: RateLimitWindowSnapshot(
                usedPercent: 2,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_783_767_714),
                observedAt: now
            ),
            weekly: RateLimitWindowSnapshot(
                usedPercent: 0,
                windowMinutes: 10_080,
                resetsAt: Date(timeIntervalSince1970: 1_784_354_514),
                observedAt: now
            ),
            updatedAt: now,
            planType: "pro",
            limitID: "codex"
        )
        let receipts = ReceiptStore(databaseURL: root.appendingPathComponent("receipts.sqlite"))
        _ = try await receipts.snapshot(now: now.addingTimeInterval(-120))
        let repository = makeRepository(
            root: root,
            sessions: sessions,
            sqliteCandidates: [],
            receiptStore: receipts,
            accountRateLimitObserver: StaticRateLimitObserver(snapshot: official)
        )

        let snapshot = await repository.snapshot(now: now)

        XCTAssertEqual(snapshot.rateLimits, official)
        XCTAssertEqual(
            snapshot.health.first { $0.adapter == .appServer },
            .healthy(.appServer, at: now)
        )
    }

    func testInitialAccountLimitConnectionDoesNotExposeRolloutFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_783_751_200)
        try writeRollout(
            to: sessions.appendingPathComponent("rollout-fallback.jsonl"),
            threadId: "rollout-fallback",
            turnId: "turn-rollout-fallback",
            startedAt: now.addingTimeInterval(-60),
            completedAt: now.addingTimeInterval(-5),
            rateUsed: 40,
            telemetryAt: now.addingTimeInterval(-10)
        )
        let receipts = ReceiptStore(databaseURL: root.appendingPathComponent("receipts.sqlite"))
        _ = try await receipts.snapshot(now: now.addingTimeInterval(-120))
        let repository = makeRepository(
            root: root,
            sessions: sessions,
            sqliteCandidates: [],
            receiptStore: receipts,
            accountRateLimitObserver: ConnectingRateLimitObserver()
        )

        let snapshot = await repository.snapshot(now: now)

        XCTAssertNil(snapshot.rateLimits)
    }

    func testTerminalRetentionCapsAtTwentyWithUnreadPriorityAndKeepsActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_700_200_000)
        let baseline = now.addingTimeInterval(-2 * 60 * 60)
        for index in 0..<20 {
            let completion = now.addingTimeInterval(-Double(100 + index))
            try writeRollout(
                to: sessions.appendingPathComponent("unread-\(index).jsonl"),
                threadId: "unread-\(index)",
                turnId: "turn-unread-\(index)",
                startedAt: completion.addingTimeInterval(-10),
                completedAt: completion
            )
        }

        let viewedCompletion = now.addingTimeInterval(-10)
        try writeRollout(
            to: sessions.appendingPathComponent("viewed.jsonl"),
            threadId: "viewed",
            turnId: "turn-viewed",
            startedAt: viewedCompletion.addingTimeInterval(-10),
            completedAt: viewedCompletion
        )
        let expiredCompletion = now.addingTimeInterval(-(25 * 60 * 60))
        try writeRollout(
            to: sessions.appendingPathComponent("expired.jsonl"),
            threadId: "expired",
            turnId: "turn-expired",
            startedAt: expiredCompletion.addingTimeInterval(-10),
            completedAt: expiredCompletion
        )
        try writeRunningRollout(
            to: sessions.appendingPathComponent("active.jsonl"),
            threadId: "active",
            turnId: "turn-active",
            startedAt: now.addingTimeInterval(-5)
        )

        let receipts = ReceiptStore(databaseURL: root.appendingPathComponent("receipts.sqlite"))
        _ = try await receipts.snapshot(now: baseline)
        try await receipts.markViewed(
            PulseTask(
                threadId: "viewed",
                turnId: "turn-viewed",
                title: "Viewed",
                projectDirectory: "/tmp/project",
                state: .completed,
                startedAt: viewedCompletion.addingTimeInterval(-10),
                updatedAt: viewedCompletion,
                completedAt: viewedCompletion,
                lastStatus: "completed"
            ),
            at: viewedCompletion.addingTimeInterval(1)
        )
        let repository = makeRepository(
            root: root,
            sessions: sessions,
            sqliteCandidates: [],
            receiptStore: receipts
        )

        let snapshot = await repository.snapshot(now: now)
        XCTAssertEqual(snapshot.recentCompletedCount, 20)
        XCTAssertEqual(snapshot.tasks.filter { $0.state.isTerminal }.count, 20)
        XCTAssertNotNil(snapshot.tasks.first { $0.threadId == "active" })
        XCTAssertNil(snapshot.tasks.first { $0.threadId == "viewed" })
        XCTAssertNil(snapshot.tasks.first { $0.threadId == "expired" })
        XCTAssertEqual(snapshot.tasks.filter(\.isUnread).count, 20)
    }

    func testTerminalTasksWithActiveAgentsBypassRetentionAndCountCap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_700_300_000)
        for index in 0..<20 {
            let completion = now.addingTimeInterval(-Double(100 + index))
            try writeRollout(
                to: sessions.appendingPathComponent("ordinary-\(index).jsonl"),
                threadId: "ordinary-\(index)",
                turnId: "turn-ordinary-\(index)",
                startedAt: completion.addingTimeInterval(-10),
                completedAt: completion
            )
        }

        let cappedCompletion = now.addingTimeInterval(-1_000)
        try writeRollout(
            to: sessions.appendingPathComponent("active-capped.jsonl"),
            threadId: "active-capped",
            turnId: "turn-active-capped",
            startedAt: cappedCompletion.addingTimeInterval(-10),
            completedAt: cappedCompletion
        )
        let expiredCompletion = now.addingTimeInterval(-25 * 60 * 60)
        try writeRollout(
            to: sessions.appendingPathComponent("active-expired.jsonl"),
            threadId: "active-expired",
            turnId: "turn-active-expired",
            startedAt: expiredCompletion.addingTimeInterval(-10),
            completedAt: expiredCompletion
        )

        let receipts = ReceiptStore(databaseURL: root.appendingPathComponent("receipts.sqlite"))
        _ = try await receipts.snapshot(now: now.addingTimeInterval(-30 * 60 * 60))
        let observer = StaticAgentActivityObserver(observationsByThread: [
            "active-capped": AgentActivityObservation(
                activeCount: 2,
                confidence: .exact,
                observedAt: now
            ),
            "active-expired": AgentActivityObservation(
                activeCount: 1,
                confidence: .exact,
                observedAt: now
            ),
        ])
        let repository = makeRepository(
            root: root,
            sessions: sessions,
            sqliteCandidates: [],
            receiptStore: receipts,
            agentActivityObserver: observer
        )

        let snapshot = await repository.snapshot(now: now)

        XCTAssertEqual(snapshot.tasks.filter { $0.state.isTerminal }.count, 22)
        XCTAssertEqual(
            snapshot.tasks.first { $0.threadId == "active-capped" }?.agentActivity?.activeCount,
            2
        )
        XCTAssertEqual(
            snapshot.tasks.first { $0.threadId == "active-expired" }?.agentActivity?.activeCount,
            1
        )
    }

    private func writeRollout(
        to url: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        try writeRollout(
            to: url,
            threadId: "thread-1",
            turnId: "turn-1",
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func writeRollout(
        to url: URL,
        threadId: String,
        turnId: String,
        startedAt: Date,
        completedAt: Date,
        tokenUsage: [String: Any]? = nil,
        rateUsed: Double? = nil,
        telemetryAt: Date? = nil
    ) throws {
        var objects: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": startedAt.ISO8601Format(),
                "payload": [
                    "id": threadId,
                    "session_id": threadId,
                    "originator": "Codex Desktop",
                    "source": "vscode",
                    "thread_source": "user",
                    "cwd": "/tmp/project",
                    "timestamp": startedAt.ISO8601Format(),
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": startedAt.ISO8601Format(),
                "payload": [
                    "type": "task_started",
                    "turn_id": turnId,
                    "started_at": startedAt.timeIntervalSince1970,
                ],
            ],
        ]
        if tokenUsage != nil || rateUsed != nil {
            let eventAt = telemetryAt ?? completedAt.addingTimeInterval(-1)
            var telemetryPayload: [String: Any] = [
                "type": "token_count",
                "info": NSNull(),
                "rate_limits": NSNull(),
            ]
            if let tokenUsage {
                telemetryPayload["info"] = [
                    "total_token_usage": tokenUsage,
                    "last_token_usage": tokenUsage,
                ]
            }
            if let rateUsed {
                telemetryPayload["rate_limits"] = [
                    "limit_id": "codex",
                    "plan_type": "pro",
                    "primary": [
                        "used_percent": rateUsed,
                        "window_minutes": 300,
                        "resets_at": eventAt.addingTimeInterval(300).timeIntervalSince1970,
                    ],
                    "secondary": [
                        "used_percent": rateUsed * 2,
                        "window_minutes": 10_080,
                        "resets_at": eventAt.addingTimeInterval(600).timeIntervalSince1970,
                    ],
                ]
            }
            objects.append([
                "type": "event_msg",
                "timestamp": eventAt.ISO8601Format(),
                "payload": telemetryPayload,
            ])
        }
        objects.append(
            [
                "type": "event_msg",
                "timestamp": completedAt.ISO8601Format(),
                "payload": [
                    "type": "task_complete",
                    "turn_id": turnId,
                    "completed_at": completedAt.timeIntervalSince1970,
                ],
            ]
        )
        try writeJSONLines(objects, to: url)
    }

    private func writeRunningRollout(
        to url: URL,
        threadId: String,
        turnId: String,
        startedAt: Date
    ) throws {
        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": startedAt.ISO8601Format(),
                "payload": [
                    "id": threadId,
                    "session_id": threadId,
                    "originator": "Codex Desktop",
                    "source": "vscode",
                    "thread_source": "user",
                    "cwd": "/tmp/project",
                    "timestamp": startedAt.ISO8601Format(),
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": startedAt.ISO8601Format(),
                "payload": [
                    "type": "task_started",
                    "turn_id": turnId,
                    "started_at": startedAt.timeIntervalSince1970,
                ],
            ],
        ], to: url)
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

    private func createStateDatabase(
        at url: URL,
        rows: [(id: String, rollout: URL, tokensUsed: Int64)]
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
                source TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                archived INTEGER NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        for row in rows {
            try connection.execute(
                """
                INSERT INTO threads(
                    id, rollout_path, created_at, updated_at, source,
                    cwd, title, archived, tokens_used
                ) VALUES (?, ?, 1700100000, 1700100010, 'vscode',
                          '/tmp/project', 'Task', 0, ?)
                """,
                bindings: [
                    .text(row.id),
                    .text(row.rollout.path),
                    .integer(row.tokensUsed),
                ]
            )
        }
    }

    private func makeRepository(
        root: URL,
        sessions: URL,
        sqliteCandidates: [URL],
        receiptStore: ReceiptStore,
        accountRateLimitObserver: (any CodexAccountRateLimitObserving)? = nil,
        agentActivityObserver: (any CodexAgentActivityObserving)? = nil
    ) -> TaskRepository {
        TaskRepository(
            appServerProbe: AppServerCapabilityProbe(
                controlSocketURL: root.appendingPathComponent("missing.sock")
            ),
            sqliteAdapter: CodexSQLiteTaskAdapter(databaseCandidates: sqliteCandidates),
            rolloutAdapter: CodexRolloutAdapter(
                sessionsDirectory: sessions,
                sessionIndexURL: root.appendingPathComponent("missing-index.jsonl"),
                lookback: 10_000 * 24 * 60 * 60,
                discoveryInterval: 0
            ),
            journalReader: PluginEventJournalReader(
                journalURL: root.appendingPathComponent("missing-events.jsonl")
            ),
            receiptStore: receiptStore,
            accountRateLimitObserver: accountRateLimitObserver,
            agentActivityObserver: agentActivityObserver
        )
    }

    private func writeSessionIndex(to url: URL) throws {
        try writeJSONLines([
            [
                "id": "thread-1",
                "thread_name": "Indexed title",
                "updated_at": "2026-07-10T10:00:00Z",
            ],
        ], to: url)
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let data = try objects.reduce(into: Data()) { result, object in
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
        try data.write(to: url)
    }
}

private struct StaticRateLimitObserver: CodexAccountRateLimitObserving {
    let snapshot: RateLimitSnapshot

    func observation(now: Date) async -> CodexAccountRateLimitObservation {
        CodexAccountRateLimitObservation(
            snapshot: snapshot,
            health: .healthy(.appServer, at: now)
        )
    }
}

private struct ConnectingRateLimitObserver: CodexAccountRateLimitObserving {
    func observation(now: Date) async -> CodexAccountRateLimitObservation {
        CodexAccountRateLimitObservation(
            snapshot: nil,
            health: .unavailable(.appServer, message: "Connecting"),
            fallbackAllowed: false
        )
    }
}

private struct StaticAgentActivityObserver: CodexAgentActivityObserving {
    let observationsByThread: [String: AgentActivityObservation]

    func observations(
        rootStates: [String: PulseTaskState],
        now: Date
    ) async -> [String: AgentActivityObservation] {
        observationsByThread.filter { rootStates[$0.key] != nil }
    }
}
