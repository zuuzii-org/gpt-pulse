import Foundation

enum PulseTaskState: String, Codable, CaseIterable, Sendable {
    case running
    case waitingForApproval
    case waitingForAnswer
    case completed
    case failed
    case interrupted

    var group: PulseTaskGroup {
        switch self {
        case .waitingForApproval, .waitingForAnswer:
            return .waitingForAction
        case .running:
            return .running
        case .failed, .interrupted:
            return .failed
        case .completed:
            return .completedUnread
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted:
            return true
        case .running, .waitingForApproval, .waitingForAnswer:
            return false
        }
    }
}

enum PulseTaskGroup: String, Codable, CaseIterable, Sendable {
    case waitingForAction
    case running
    case failed
    case completedUnread

    static let displayOrder: [PulseTaskGroup] = [
        .waitingForAction,
        .running,
        .failed,
        .completedUnread,
    ]
}
