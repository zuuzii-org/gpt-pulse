import Foundation
import XCTest
@testable import GPTPulse

final class CodexAccountRateLimitObserverTests: XCTestCase {
    func testFirstObservationIsImmediateAndRepeatedReadsShareOneRefresh() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let loader = ControlledRateLimitLoader()
        let observer = CodexAccountRateLimitObserver(
            loader: loader,
            refreshInterval: 30,
            staleInterval: 300
        )

        let startedAt = Date()
        let first = await observer.observation(now: now)
        let second = await observer.observation(now: now)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.25)
        XCTAssertNil(first.snapshot)
        XCTAssertNil(second.snapshot)
        XCTAssertFalse(first.fallbackAllowed)
        XCTAssertFalse(second.fallbackAllowed)
        XCTAssertEqual(first.health.status, .unavailable)
        XCTAssertEqual(second.health.status, .unavailable)

        let didStart = await loader.waitUntilCallCount(1)
        guard didStart else {
            return XCTFail("Expected the initial refresh to start")
        }
        let callCount = await loader.callCount()
        XCTAssertEqual(callCount, 1)

        await loader.succeedNext(with: snapshot(observedAt: now))
        await observer.waitForCurrentRefreshForTesting()
    }

    func testSuccessfulRefreshIsCachedAndReportedHealthy() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = snapshot(observedAt: now)
        let loader = ControlledRateLimitLoader()
        let observer = CodexAccountRateLimitObserver(
            loader: loader,
            refreshInterval: 30,
            staleInterval: 300
        )

        _ = await observer.observation(now: now)
        let didStart = await loader.waitUntilCallCount(1)
        guard didStart else {
            return XCTFail("Expected the initial refresh to start")
        }
        await loader.succeedNext(with: expected)
        await observer.waitForCurrentRefreshForTesting()

        let firstCached = await observer.observation(now: now.addingTimeInterval(1))
        let secondCached = await observer.observation(now: now.addingTimeInterval(2))
        let callCount = await loader.callCount()

        XCTAssertEqual(firstCached.snapshot, expected)
        XCTAssertEqual(secondCached.snapshot, expected)
        XCTAssertEqual(firstCached.health.status, .healthy)
        XCTAssertEqual(firstCached.health.adapter, .appServer)
        XCTAssertEqual(firstCached.health.lastSuccessAt, now)
        XCTAssertNil(firstCached.health.message)
        XCTAssertFalse(firstCached.fallbackAllowed)
        XCTAssertEqual(callCount, 1)
    }

    func testFailedRefreshKeepsRecentSuccessfulSnapshotAndReportsDegraded() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = snapshot(observedAt: now)
        let loader = ControlledRateLimitLoader()
        let observer = CodexAccountRateLimitObserver(
            loader: loader,
            refreshInterval: 10,
            staleInterval: 60
        )

        _ = await observer.observation(now: now)
        let didStartInitialRefresh = await loader.waitUntilCallCount(1)
        guard didStartInitialRefresh else {
            return XCTFail("Expected the initial refresh to start")
        }
        await loader.succeedNext(with: expected)
        await observer.waitForCurrentRefreshForTesting()

        let refreshAt = now.addingTimeInterval(11)
        let whileRefreshing = await observer.observation(now: refreshAt)
        XCTAssertEqual(whileRefreshing.snapshot, expected)
        XCTAssertEqual(whileRefreshing.health.status, .healthy)

        let didStartFollowUpRefresh = await loader.waitUntilCallCount(2)
        guard didStartFollowUpRefresh else {
            return XCTFail("Expected the follow-up refresh to start")
        }
        await loader.failNext()
        await observer.waitForCurrentRefreshForTesting()

        let afterFailure = await observer.observation(now: refreshAt)
        XCTAssertEqual(afterFailure.snapshot, expected)
        XCTAssertEqual(afterFailure.health.status, .degraded)
        XCTAssertEqual(afterFailure.health.adapter, .appServer)
        XCTAssertEqual(afterFailure.health.lastSuccessAt, now)
        XCTAssertEqual(afterFailure.health.message, "fixture failure")
        XCTAssertFalse(afterFailure.fallbackAllowed)

        let afterCacheInterval = await observer.observation(
            now: now.addingTimeInterval(61)
        )
        XCTAssertEqual(afterCacheInterval.snapshot, expected)
        XCTAssertEqual(afterCacheInterval.health.status, .degraded)
        XCTAssertFalse(afterCacheInterval.fallbackAllowed)
    }

    private func snapshot(observedAt: Date) -> RateLimitSnapshot {
        RateLimitSnapshot(
            fiveHour: RateLimitWindowSnapshot(
                usedPercent: 13,
                windowMinutes: 300,
                resetsAt: observedAt.addingTimeInterval(3_600),
                observedAt: observedAt
            ),
            weekly: RateLimitWindowSnapshot(
                usedPercent: 2,
                windowMinutes: 10_080,
                resetsAt: observedAt.addingTimeInterval(7 * 24 * 60 * 60),
                observedAt: observedAt
            ),
            updatedAt: observedAt,
            planType: "pro",
            limitID: "codex"
        )
    }
}

private actor ControlledRateLimitLoader: CodexAccountRateLimitLoading {
    private var callDates: [Date] = []
    private var pending: [CheckedContinuation<RateLimitSnapshot, Error>] = []

    func loadRateLimits() async throws -> RateLimitSnapshot {
        callDates.append(.now)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    func callCount() -> Int {
        callDates.count
    }

    func waitUntilCallCount(_ expectedCount: Int) async -> Bool {
        for _ in 0 ..< 10_000 {
            if callDates.count >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func succeedNext(with snapshot: RateLimitSnapshot) {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(returning: snapshot)
    }

    func failNext() {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(throwing: FixtureError.failed)
    }
}

private enum FixtureError: LocalizedError, Sendable {
    case failed

    var errorDescription: String? { "fixture failure" }
}
