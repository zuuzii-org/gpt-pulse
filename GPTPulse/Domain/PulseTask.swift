import Foundation

struct PulseTask: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let threadId: String
    let turnId: String?
    let title: String
    let projectDirectory: String
    let state: PulseTaskState
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let lastStatus: String
    let isUnread: Bool
    let tokenUsage: TokenUsageSnapshot?

    init(
        threadId: String,
        turnId: String? = nil,
        title: String,
        projectDirectory: String,
        state: PulseTaskState,
        startedAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        lastStatus: String,
        isUnread: Bool = false,
        tokenUsage: TokenUsageSnapshot? = nil
    ) {
        self.threadId = threadId
        self.turnId = turnId
        self.id = Self.makeID(threadId: threadId, turnId: turnId)
        self.title = title
        self.projectDirectory = projectDirectory
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastStatus = lastStatus
        self.isUnread = isUnread
        self.tokenUsage = tokenUsage
    }

    var workingDirectory: String { projectDirectory }

    var statusText: String { lastStatus }

    func duration(asOf date: Date = .now) -> TimeInterval {
        max(0, (completedAt ?? date).timeIntervalSince(startedAt))
    }

    static func makeID(threadId: String, turnId: String?) -> String {
        "\(threadId):\(turnId ?? "thread")"
    }
}
