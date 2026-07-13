import Foundation
import XCTest
@testable import LLMPulse

final class RolloutRateLimitSelectorTests: XCTestCase {
    func testSelectsOneCanonicalSnapshotWithoutMixingModelPool() throws {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let canonical = snapshot(
            limitID: "codex",
            fiveHourUsed: 2,
            weeklyUsed: 0,
            fiveHourReset: now.addingTimeInterval(16_514),
            weeklyReset: now.addingTimeInterval(603_314),
            updatedAt: now.addingTimeInterval(-5)
        )
        let modelPool = snapshot(
            limitID: "codex_bengalfox",
            fiveHourUsed: 99,
            weeklyUsed: 88,
            fiveHourReset: now.addingTimeInterval(1_000),
            weeklyReset: now.addingTimeInterval(2_000),
            updatedAt: now
        )

        let selected = try XCTUnwrap(
            RolloutRateLimitSelector.select([modelPool, canonical], now: now)
        )

        XCTAssertEqual(selected, canonical)
        XCTAssertEqual(selected.limitID, "codex")
        XCTAssertEqual(selected.fiveHour?.usedPercent, 2)
        XCTAssertEqual(selected.weekly?.usedPercent, 0)
    }

    func testConflictingCanonicalResetGroupsAreRejectedInsteadOfGuessed() {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let olderGroup = snapshot(
            limitID: "codex",
            fiveHourUsed: 5,
            weeklyUsed: 5,
            fiveHourReset: Date(timeIntervalSince1970: 1_783_759_226),
            weeklyReset: Date(timeIntervalSince1970: 1_784_309_816),
            updatedAt: now.addingTimeInterval(-20)
        )
        let settingsGroup = snapshot(
            limitID: "codex",
            fiveHourUsed: 2,
            weeklyUsed: 0,
            fiveHourReset: Date(timeIntervalSince1970: 1_783_767_714),
            weeklyReset: Date(timeIntervalSince1970: 1_784_354_514),
            updatedAt: now.addingTimeInterval(-10)
        )

        XCTAssertNil(
            RolloutRateLimitSelector.select([olderGroup, settingsGroup], now: now)
        )
    }

    func testFreshOlderGroupCannotHideAStillValidStaleConflict() {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let freshOlderGroup = snapshot(
            limitID: "codex",
            fiveHourUsed: 5,
            weeklyUsed: 5,
            fiveHourReset: Date(timeIntervalSince1970: 1_783_759_226),
            weeklyReset: Date(timeIntervalSince1970: 1_784_309_816),
            updatedAt: now.addingTimeInterval(-10)
        )
        let staleSettingsGroup = snapshot(
            limitID: "codex",
            fiveHourUsed: 2,
            weeklyUsed: 0,
            fiveHourReset: Date(timeIntervalSince1970: 1_783_767_714),
            weeklyReset: Date(timeIntervalSince1970: 1_784_354_514),
            updatedAt: now.addingTimeInterval(-20 * 60)
        )

        XCTAssertNil(
            RolloutRateLimitSelector.select(
                [freshOlderGroup, staleSettingsGroup],
                now: now
            )
        )
    }

    func testResetJitterWithinOneMinuteUsesLatestAtomicSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let earlier = snapshot(
            limitID: nil,
            fiveHourUsed: 70,
            weeklyUsed: 80,
            fiveHourReset: now.addingTimeInterval(3_000),
            weeklyReset: now.addingTimeInterval(300_000),
            updatedAt: now.addingTimeInterval(-20)
        )
        let latest = snapshot(
            limitID: nil,
            fiveHourUsed: 8,
            weeklyUsed: 9,
            fiveHourReset: now.addingTimeInterval(3_030),
            weeklyReset: now.addingTimeInterval(300_030),
            updatedAt: now.addingTimeInterval(-5)
        )

        let selected = try XCTUnwrap(
            RolloutRateLimitSelector.select([earlier, latest], now: now)
        )

        XCTAssertEqual(selected, latest)
        XCTAssertEqual(selected.fiveHour?.usedPercent, 8)
        XCTAssertEqual(selected.weekly?.usedPercent, 9)
    }

    func testMissingOrExpiredWeeklySnapshotsAreRejected() {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let missingWeekly = RateLimitSnapshot(
            fiveHour: window(used: 10, minutes: 300, reset: now.addingTimeInterval(60), observedAt: now),
            weekly: nil,
            updatedAt: now,
            limitID: "codex"
        )
        let expiredWeekly = snapshot(
            limitID: "codex",
            fiveHourUsed: 10,
            weeklyUsed: 20,
            fiveHourReset: now.addingTimeInterval(60),
            weeklyReset: now.addingTimeInterval(-1),
            updatedAt: now
        )

        XCTAssertNil(
            RolloutRateLimitSelector.select(
                [missingWeekly, expiredWeekly],
                now: now
            )
        )
    }

    func testExpiredLegacyFiveHourDoesNotInvalidateWeeklySnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let snapshot = self.snapshot(
            limitID: "codex",
            fiveHourUsed: 10,
            weeklyUsed: 20,
            fiveHourReset: now.addingTimeInterval(-1),
            weeklyReset: now.addingTimeInterval(60),
            updatedAt: now
        )

        XCTAssertEqual(
            try XCTUnwrap(RolloutRateLimitSelector.select([snapshot], now: now)),
            snapshot
        )
    }

    func testWeeklyOnlySnapshotIsAccepted() throws {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let weeklyOnly = RateLimitSnapshot(
            fiveHour: nil,
            weekly: window(
                used: 12,
                minutes: 10_080,
                reset: now.addingTimeInterval(300_000),
                observedAt: now
            ),
            updatedAt: now,
            limitID: "codex"
        )

        XCTAssertEqual(
            try XCTUnwrap(RolloutRateLimitSelector.select([weeklyOnly], now: now)),
            weeklyOnly
        )
    }

    func testLegacyFiveHourDoesNotAffectWeeklyGroupingOrSelection() throws {
        let now = Date(timeIntervalSince1970: 1_783_751_200)
        let weeklyReset = now.addingTimeInterval(300_000)
        let earlier = snapshot(
            limitID: "codex",
            fiveHourUsed: 99,
            weeklyUsed: 10,
            fiveHourReset: now.addingTimeInterval(60),
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-20)
        )
        let latest = snapshot(
            limitID: "codex",
            fiveHourUsed: 1,
            weeklyUsed: 11,
            fiveHourReset: now.addingTimeInterval(9_000),
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-5)
        )

        XCTAssertEqual(
            try XCTUnwrap(
                RolloutRateLimitSelector.select([earlier, latest], now: now)
            ),
            latest
        )
    }

    private func snapshot(
        limitID: String?,
        fiveHourUsed: Double,
        weeklyUsed: Double,
        fiveHourReset: Date,
        weeklyReset: Date,
        updatedAt: Date
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            fiveHour: window(
                used: fiveHourUsed,
                minutes: 300,
                reset: fiveHourReset,
                observedAt: updatedAt
            ),
            weekly: window(
                used: weeklyUsed,
                minutes: 10_080,
                reset: weeklyReset,
                observedAt: updatedAt
            ),
            updatedAt: updatedAt,
            planType: "pro",
            limitID: limitID
        )
    }

    private func window(
        used: Double,
        minutes: Int,
        reset: Date,
        observedAt: Date
    ) -> RateLimitWindowSnapshot {
        RateLimitWindowSnapshot(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: reset,
            observedAt: observedAt
        )
    }
}
