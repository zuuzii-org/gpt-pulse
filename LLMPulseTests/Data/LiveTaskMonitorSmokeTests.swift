import Foundation
import XCTest
@testable import LLMPulse

/// Opt-in smoke coverage for the real local adapters assembled by
/// `TaskMonitor.makeLive`. The default test run skips this class so CI never
/// inspects a developer machine by accident.
@MainActor
final class LiveTaskMonitorSmokeTests: XCTestCase {
    private static let optInEnvironmentKey = "LLM_PULSE_RUN_LIVE_SMOKE"

    func testLiveMonitorRefreshesWithoutExposingTaskContent() async throws {
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 to run the local read-only adapter smoke test"
            )
        }

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-pulse-live-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let liveCodexPaths = CodexPaths.live()
        let isolatedCodexPaths = CodexPaths(
            codexHome: liveCodexPaths.codexHome,
            stateDatabaseCandidates: liveCodexPaths.stateDatabaseCandidates,
            appServerControlSocketURL: liveCodexPaths.appServerControlSocketURL,
            sessionsDirectory: liveCodexPaths.sessionsDirectory,
            sessionIndexURL: liveCodexPaths.sessionIndexURL,
            pluginJournalURL: liveCodexPaths.pluginJournalURL,
            compatibilityPluginJournalURLs: liveCodexPaths.compatibilityPluginJournalURLs,
            receiptsDatabaseURL: fixtureRoot.appendingPathComponent("receipts.sqlite")
        )
        let monitor = TaskMonitor.makeLive(codexPaths: isolatedCodexPaths)

        await monitor.refreshNow()

        let snapshot = monitor.hubSnapshot
        XCTAssertFalse(snapshot.models.isEmpty, "Live Hub returned no model profiles")
        XCTAssertTrue(
            snapshot.models.contains { $0.identity.profileID == .codex },
            "Live Hub omitted the required Codex profile"
        )
        XCTAssertEqual(
            Set(snapshot.models.map(\.identity.profileID)).count,
            snapshot.models.count,
            "Live Hub returned duplicate profile identifiers"
        )
        XCTAssertTrue(
            snapshot.models.allSatisfy { model in
                model.tasks.allSatisfy { $0.profileID == model.identity.profileID }
            },
            "Live Hub returned a task under the wrong profile"
        )

        // Privacy contract: diagnostics contain only a stable profile ID,
        // aggregate counts, and adapter/status pairs. Never print task titles,
        // project paths, session IDs, health messages, or raw source content.
        for model in snapshot.models {
            let summary = PulseHubSummary(snapshot: PulseHubSnapshot(
                models: [model],
                refreshedAt: snapshot.refreshedAt
            ))
            let health = model.health
                .map { "\($0.adapter.rawValue):\(healthStatusName($0.status))" }
                .sorted()
                .joined(separator: ",")
            let healthSummary = health.isEmpty ? "none" : health
            print(
                "LLM_PULSE_LIVE_SMOKE "
                    + "profile=\(model.identity.profileID.rawValue) "
                    + "active=\(summary.activeCount) "
                    + "recent=\(summary.recentCompletedCount) "
                    + "waiting=\(summary.waitingActionCount) "
                    + "health=\(healthSummary)"
            )
        }
    }

    private func healthStatusName(_ status: AdapterHealth.Status) -> String {
        switch status {
        case .healthy: "healthy"
        case .degraded: "degraded"
        case .unavailable: "unavailable"
        }
    }
}
