import Foundation

@MainActor
final class TaskOpeningService {
    private let navigator: TaskNavigator
    private let markViewed: (PulseTask) -> Void
    private let dismiss: () -> Void

    init(
        navigator: TaskNavigator,
        markViewed: @escaping (PulseTask) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.navigator = navigator
        self.markViewed = markViewed
        self.dismiss = dismiss
    }

    @discardableResult
    func open(task: PulseTask) -> Bool {
        guard navigator.open(threadID: task.threadId) else { return false }

        if task.isUnread {
            markViewed(task)
        }
        dismiss()
        return true
    }

    @discardableResult
    func open(route: TaskNotificationRoute, currentTasks: [PulseTask]) -> Bool {
        if let task = currentTasks.first(where: { $0.id == route.taskID }) {
            return open(task: task)
        }

        guard navigator.open(threadID: route.threadID) else { return false }
        dismiss()
        return true
    }
}
