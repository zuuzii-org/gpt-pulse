import Foundation

struct ModelUsageSnapshot: Equatable, Codable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let observedRequestCount: Int
    let observedAt: Date

    init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int,
        observedRequestCount: Int,
        observedAt: Date
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.observedRequestCount = observedRequestCount
        self.observedAt = observedAt
    }
}
