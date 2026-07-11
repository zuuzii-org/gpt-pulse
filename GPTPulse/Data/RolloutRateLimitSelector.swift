import Foundation

/// Conservative compatibility fallback for rollout telemetry.
///
/// Rollout files can contain several account/model pools at the same time. This
/// selector never combines windows from different events and refuses to guess
/// when more than one reset generation is still plausible.
enum RolloutRateLimitSelector {
    private static let freshnessInterval: TimeInterval = 15 * 60
    private static let futureTolerance: TimeInterval = 60
    private static let resetHorizonTolerance: TimeInterval = 5 * 60

    static func select(
        _ snapshots: [RateLimitSnapshot],
        now: Date
    ) -> RateLimitSnapshot? {
        let valid = snapshots.filter { isValid($0, now: now) }
        let canonical = valid.filter { $0.limitID?.lowercased() == "codex" }

        let pool: [RateLimitSnapshot]
        if !canonical.isEmpty {
            pool = canonical
        } else {
            // Legacy telemetry without limit_id is safe only when there is no
            // identified model-specific pool competing with it.
            guard !valid.contains(where: { $0.limitID != nil }) else { return nil }
            pool = valid.filter { $0.limitID == nil }
        }
        guard !pool.isEmpty else { return nil }

        var groups: [[RateLimitSnapshot]] = []
        for snapshot in pool.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let index = groups.firstIndex(where: { group in
                guard let representative = group.first else { return false }
                return hasSameResetTuple(snapshot, representative)
            }) {
                groups[index].append(snapshot)
            } else {
                groups.append([snapshot])
            }
        }

        guard groups.count == 1 else { return nil }
        let fresh = groups[0].filter { snapshot in
            let age = now.timeIntervalSince(oldestObservation(in: snapshot))
            return age >= -futureTolerance && age <= freshnessInterval
        }
        let eligible = fresh.isEmpty ? groups[0] : fresh
        return eligible.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return totalUsedPercent(lhs) < totalUsedPercent(rhs)
        }
    }

    private static func isValid(_ snapshot: RateLimitSnapshot, now: Date) -> Bool {
        guard snapshot.conflictingResetHistoryUntil.map({ $0 <= now }) ?? true,
              let fiveHour = snapshot.fiveHour,
              let weekly = snapshot.weekly,
              isValid(fiveHour, expectedMinutes: 300, snapshot: snapshot, now: now),
              isValid(weekly, expectedMinutes: 10_080, snapshot: snapshot, now: now)
        else {
            return false
        }
        return true
    }

    private static func isValid(
        _ window: RateLimitWindowSnapshot,
        expectedMinutes: Int,
        snapshot: RateLimitSnapshot,
        now: Date
    ) -> Bool {
        guard window.windowMinutes == expectedMinutes,
              window.usedPercent.isFinite,
              (0...100).contains(window.usedPercent),
              window.resetsAt > now
        else {
            return false
        }
        let observedAt = window.observedAt ?? snapshot.updatedAt
        let maximumReset = observedAt.addingTimeInterval(
            TimeInterval(expectedMinutes * 60) + resetHorizonTolerance
        )
        return window.resetsAt <= maximumReset
    }

    private static func oldestObservation(in snapshot: RateLimitSnapshot) -> Date {
        [
            snapshot.fiveHour?.observedAt,
            snapshot.weekly?.observedAt,
        ]
        .compactMap { $0 }
        .min() ?? snapshot.updatedAt
    }

    private static func hasSameResetTuple(
        _ lhs: RateLimitSnapshot,
        _ rhs: RateLimitSnapshot
    ) -> Bool {
        guard let lhsFiveHour = lhs.fiveHour,
              let lhsWeekly = lhs.weekly,
              let rhsFiveHour = rhs.fiveHour,
              let rhsWeekly = rhs.weekly
        else {
            return false
        }
        return RateLimitResetSemantics.representsSameWindow(
            lhsFiveHour.resetsAt,
            rhsFiveHour.resetsAt
        ) && RateLimitResetSemantics.representsSameWindow(
            lhsWeekly.resetsAt,
            rhsWeekly.resetsAt
        )
    }

    private static func totalUsedPercent(_ snapshot: RateLimitSnapshot) -> Double {
        (snapshot.fiveHour?.usedPercent ?? 0) + (snapshot.weekly?.usedPercent ?? 0)
    }
}
