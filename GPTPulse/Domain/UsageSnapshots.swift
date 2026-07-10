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
}

struct RateLimitSnapshot: Codable, Equatable, Sendable {
    let fiveHour: RateLimitWindowSnapshot?
    let weekly: RateLimitWindowSnapshot?
    let updatedAt: Date
    let planType: String?

    init(
        fiveHour: RateLimitWindowSnapshot?,
        weekly: RateLimitWindowSnapshot?,
        updatedAt: Date,
        planType: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
        self.planType = planType
    }
}
