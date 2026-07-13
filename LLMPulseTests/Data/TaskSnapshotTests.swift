import Foundation
import XCTest
@testable import LLMPulse

final class TaskSnapshotTests: XCTestCase {
    func testOptionalFallbackSourcesAreNotActionableWhenAbsent() {
        let snapshot = TaskSnapshot(
            tasks: [],
            refreshedAt: .now,
            health: [
                .unavailable(.appServer, message: "missing"),
                .unavailable(.pluginJournal, message: "not installed"),
                .healthy(.sqlite),
                .healthy(.rolloutJSONL),
            ]
        )

        XCTAssertTrue(
            snapshot.actionableHealth.filter { $0.status != .healthy }.isEmpty
        )
    }

    func testDegradedPluginJournalRemainsActionable() {
        let snapshot = TaskSnapshot(
            tasks: [],
            refreshedAt: .now,
            health: [.degraded(.pluginJournal, message: "invalid events")]
        )
        XCTAssertEqual(snapshot.actionableHealth.map(\.adapter), [.pluginJournal])
    }

    func testRolloutOnlyRunningStateExpiresAfterCutoff() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let status = TaskStatusRecord(
            threadId: "thread",
            turnId: "turn",
            state: .running,
            startedAt: now.addingTimeInterval(-100_000),
            updatedAt: now.addingTimeInterval(-90_000),
            completedAt: nil,
            lastStatus: "running",
            latestActivityAt: now.addingTimeInterval(-90_000)
        )
        XCTAssertTrue(status.isStaleRunning(at: now, cutoff: 86_400))
    }

    func testRecentCompletedCountIncludesEveryTerminalState() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let states: [PulseTaskState] = [
            .running,
            .waitingForAnswer,
            .completed,
            .failed,
            .interrupted,
        ]
        let tasks = states.enumerated().map { index, state in
            PulseTask(
                threadId: "thread-\(index)",
                title: "Task \(index)",
                projectDirectory: "/tmp/project",
                state: state,
                startedAt: now,
                updatedAt: now,
                lastStatus: state.rawValue
            )
        }
        let snapshot = TaskSnapshot(tasks: tasks, refreshedAt: now, health: [])

        XCTAssertEqual(snapshot.recentCompletedCount, 3)
    }

    func testRateLimitSnapshotCodableKeepsLegacyAndWeeklyOnlyShapes() throws {
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let weekly = RateLimitWindowSnapshot(
            usedPercent: 4,
            windowMinutes: RateLimitWindowDuration.weeklyMinutes,
            resetsAt: observedAt.addingTimeInterval(600_000),
            observedAt: observedAt
        )
        let legacyFiveHour = RateLimitWindowSnapshot(
            usedPercent: 12,
            windowMinutes: RateLimitWindowDuration.legacyFiveHourMinutes,
            resetsAt: observedAt.addingTimeInterval(3_000),
            observedAt: observedAt
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for snapshot in [
            RateLimitSnapshot(
                fiveHour: legacyFiveHour,
                weekly: weekly,
                updatedAt: observedAt,
                planType: "pro",
                limitID: "codex"
            ),
            RateLimitSnapshot(
                fiveHour: nil,
                weekly: weekly,
                updatedAt: observedAt,
                planType: "pro",
                limitID: "codex"
            ),
        ] {
            XCTAssertEqual(
                try decoder.decode(
                    RateLimitSnapshot.self,
                    from: encoder.encode(snapshot)
                ),
                snapshot
            )
        }
    }
}
