import Foundation

struct AgentActivityObservation: Codable, Equatable, Sendable {
    enum Confidence: String, Codable, Equatable, Sendable {
        case exact
        case provisional
        case stale
        case unavailable
    }

    let activeCount: Int?
    let confidence: Confidence
    let observedAt: Date

    init(
        activeCount: Int?,
        confidence: Confidence,
        observedAt: Date
    ) {
        self.activeCount = activeCount
        self.confidence = confidence
        self.observedAt = observedAt
    }
}
