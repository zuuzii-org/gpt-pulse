import Foundation

struct TaskSnapshot: Codable, Equatable, Sendable {
    let tasks: [PulseTask]
    let refreshedAt: Date
    let health: [AdapterHealth]
    let rateLimits: RateLimitSnapshot?

    static let empty = TaskSnapshot(tasks: [], refreshedAt: .distantPast, health: [])

    init(
        tasks: [PulseTask],
        refreshedAt: Date,
        health: [AdapterHealth],
        rateLimits: RateLimitSnapshot? = nil
    ) {
        self.tasks = tasks
        self.refreshedAt = refreshedAt
        self.health = health
        self.rateLimits = rateLimits
    }

    var activeCount: Int {
        tasks.lazy.filter {
            $0.state == .running ||
                $0.state == .waitingForApproval ||
                $0.state == .waitingForAnswer
        }.count
    }

    var unreadCompletedCount: Int {
        tasks.lazy.filter { $0.state == .completed && $0.isUnread }.count
    }

    var recentCompletedCount: Int {
        tasks.lazy.filter { $0.state.isTerminal }.count
    }

    var hasFailures: Bool {
        tasks.contains { $0.state == .failed || $0.state == .interrupted }
    }

    var actionableHealth: [AdapterHealth] {
        health.filter { $0.status != .healthy && $0.isActionable }
    }

    func tasks(in group: PulseTaskGroup) -> [PulseTask] {
        tasks.filter { $0.state.group == group }
    }
}
