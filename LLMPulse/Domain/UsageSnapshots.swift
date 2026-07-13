import Foundation

struct TokenUsageSnapshot: Codable, Equatable, Sendable {
    let totalTokens: Int
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    init(
        totalTokens: Int,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}

struct RateLimitWindowSnapshot: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
    let observedAt: Date?

    init(
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Date,
        observedAt: Date? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

enum RateLimitResetSemantics {
    static let tolerance: TimeInterval = 60

    static func representsSameWindow(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= tolerance
    }
}

enum RateLimitWindowDuration {
    static let legacyFiveHourMinutes = 5 * 60
    static let weeklyMinutes = 7 * 24 * 60
}

struct RateLimitSnapshot: Codable, Equatable, Sendable {
    /// Optional compatibility data retained for a possible future 5h surface.
    /// A missing or malformed legacy window never invalidates weekly limits.
    let fiveHour: RateLimitWindowSnapshot?
    /// Canonical Codex account quota. Data sources reject snapshots that do not
    /// contain this exact weekly window.
    let weekly: RateLimitWindowSnapshot?
    let updatedAt: Date
    let planType: String?
    let limitID: String?
    let conflictingResetHistoryUntil: Date?

    init(
        fiveHour: RateLimitWindowSnapshot?,
        weekly: RateLimitWindowSnapshot?,
        updatedAt: Date,
        planType: String? = nil,
        limitID: String? = nil,
        conflictingResetHistoryUntil: Date? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
        self.planType = planType
        self.limitID = limitID
        self.conflictingResetHistoryUntil = conflictingResetHistoryUntil
    }
}
