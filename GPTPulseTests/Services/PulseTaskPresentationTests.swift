import Foundation
import XCTest
@testable import GPTPulse

final class PulseTaskPresentationTests: XCTestCase {
    func testProjectDisplayNameUsesNearestGitRoot() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let repository = temporaryRoot.appendingPathComponent("gpt-pulse", isDirectory: true)
        let nestedDirectory = repository
            .appendingPathComponent("GPTPulse", isDirectory: true)
            .appendingPathComponent("UI", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertEqual(makeTask(projectDirectory: nestedDirectory.path).projectDisplayName, "gpt-pulse")
    }

    func testProjectDisplayNameFallsBackToWorkingDirectoryAndHandlesMissingPath() {
        XCTAssertEqual(
            makeTask(projectDirectory: "/a/nonexistent/path/中文项目/").projectDisplayName,
            "中文项目"
        )
        XCTAssertEqual(makeTask(projectDirectory: "").projectDisplayName, "未识别项目")
        XCTAssertEqual(makeTask(projectDirectory: "/").projectDisplayName, "未识别项目")
    }

    func testCompactTokenCountUsesStableUnitsWithoutDoubleCountingSubsets() {
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(nil), "—")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(-1), "0")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(999), "999")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(1_000), "1k")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(132_900), "132.9k")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(999_999), "1m")
        XCTAssertEqual(TokenUsageSnapshot.compactTokenCount(1_250_000), "1.3m")
    }

    func testRemainingPercentClampsAndExpiresAtReset() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(60)

        XCTAssertEqual(
            RateLimitWindowSnapshot(
                usedPercent: 12.5,
                windowMinutes: 300,
                resetsAt: future
            ).remainingPercent(asOf: now),
            87.5
        )
        XCTAssertEqual(
            RateLimitWindowSnapshot(
                usedPercent: 120,
                windowMinutes: 300,
                resetsAt: future
            ).remainingPercent(asOf: now),
            0
        )
        XCTAssertEqual(
            RateLimitWindowSnapshot(
                usedPercent: -5,
                windowMinutes: 300,
                resetsAt: future
            ).remainingPercent(asOf: now),
            100
        )
        XCTAssertNil(
            RateLimitWindowSnapshot(
                usedPercent: 12.5,
                windowMinutes: 300,
                resetsAt: now
            ).remainingPercent(asOf: now)
        )
    }

    func testQuotaResetDescriptionUsesCompactResetLabel() {
        let calendar = Calendar.autoupdatingCurrent
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
            .addingTimeInterval(60 * 60)
        let reset = now.addingTimeInterval(2 * 60 * 60)
        let description = reset.pulseQuotaResetDescription(asOf: now)

        XCTAssertNotNil(
            description.range(
                of: #"^重置 \d{2}:\d{2}$"#,
                options: .regularExpression
            )
        )
    }

    private func makeTask(projectDirectory: String) -> PulseTask {
        PulseTask(
            threadId: UUID().uuidString,
            title: "Session",
            projectDirectory: projectDirectory,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            lastStatus: "running"
        )
    }
}
