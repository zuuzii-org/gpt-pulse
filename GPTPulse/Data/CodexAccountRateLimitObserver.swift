import Foundation

struct CodexAccountRateLimitObservation: Sendable {
    let snapshot: RateLimitSnapshot?
    let health: AdapterHealth
    let fallbackAllowed: Bool

    init(
        snapshot: RateLimitSnapshot?,
        health: AdapterHealth,
        fallbackAllowed: Bool = true
    ) {
        self.snapshot = snapshot
        self.health = health
        self.fallbackAllowed = fallbackAllowed
    }
}

protocol CodexAccountRateLimitObserving: Sendable {
    func observation(now: Date) async -> CodexAccountRateLimitObservation
}

actor CodexAccountRateLimitObserver: CodexAccountRateLimitObserving {
    private let loader: any CodexAccountRateLimitLoading
    private let refreshInterval: TimeInterval
    private let staleInterval: TimeInterval

    private var cachedSnapshot: RateLimitSnapshot?
    private var lastAttemptAt = Date.distantPast
    private var lastSuccessAt: Date?
    private var lastErrorMessage: String?
    private var refreshTask: Task<Void, Never>?

    init(
        loader: any CodexAccountRateLimitLoading,
        refreshInterval: TimeInterval = 30,
        staleInterval: TimeInterval = 5 * 60
    ) {
        let normalizedRefreshInterval = refreshInterval.isFinite
            ? max(0, refreshInterval)
            : 30
        let normalizedStaleInterval = staleInterval.isFinite
            ? max(0, staleInterval)
            : 5 * 60
        self.loader = loader
        self.refreshInterval = normalizedRefreshInterval
        self.staleInterval = max(normalizedRefreshInterval, normalizedStaleInterval)
    }

    func observation(now: Date = .now) -> CodexAccountRateLimitObservation {
        if refreshTask == nil,
           now.timeIntervalSince(lastAttemptAt) >= refreshInterval
        {
            startRefresh(now: now)
        }

        let isFresh = lastSuccessAt.map {
            let age = now.timeIntervalSince($0)
            return age >= -60 && age <= staleInterval
        } ?? false
        let hasUnexpiredOfficialWindow = [
            cachedSnapshot?.fiveHour,
            cachedSnapshot?.weekly,
        ]
        .compactMap { $0 }
        .contains { $0.resetsAt > now }
        let isStaleButAuthoritative = !isFresh
            && hasUnexpiredOfficialWindow
            && (lastErrorMessage != nil || refreshTask != nil)
        let visibleSnapshot = (isFresh || isStaleButAuthoritative) ? cachedSnapshot : nil

        if let lastSuccessAt, visibleSnapshot != nil {
            if let lastErrorMessage {
                return CodexAccountRateLimitObservation(
                    snapshot: visibleSnapshot,
                    health: .degraded(
                        .appServer,
                        message: lastErrorMessage,
                        lastSuccessAt: lastSuccessAt
                    ),
                    fallbackAllowed: false
                )
            }
            if isStaleButAuthoritative {
                return CodexAccountRateLimitObservation(
                    snapshot: visibleSnapshot,
                    health: .degraded(
                        .appServer,
                        message: "Refreshing Codex account limits",
                        lastSuccessAt: lastSuccessAt
                    ),
                    fallbackAllowed: false
                )
            }
            return CodexAccountRateLimitObservation(
                snapshot: visibleSnapshot,
                health: .healthy(.appServer, at: lastSuccessAt),
                fallbackAllowed: false
            )
        }

        return CodexAccountRateLimitObservation(
            snapshot: nil,
            health: .unavailable(
                .appServer,
                message: lastErrorMessage ?? "Connecting to Codex account limits"
            ),
            fallbackAllowed: lastErrorMessage != nil
        )
    }

    func waitForCurrentRefreshForTesting() async {
        let task = refreshTask
        await task?.value
    }

    private func startRefresh(now: Date) {
        lastAttemptAt = now
        let loader = loader
        refreshTask = Task { [weak self] in
            do {
                let snapshot = try await loader.loadRateLimits()
                await self?.finishRefresh(snapshot)
            } catch {
                await self?.failRefresh(error)
            }
        }
    }

    private func finishRefresh(_ snapshot: RateLimitSnapshot) {
        cachedSnapshot = snapshot
        lastSuccessAt = snapshot.updatedAt
        lastAttemptAt = snapshot.updatedAt
        lastErrorMessage = nil
        refreshTask = nil
    }

    private func failRefresh(_ error: Error) {
        lastAttemptAt = .now
        lastErrorMessage = error.localizedDescription
        refreshTask = nil
    }
}
