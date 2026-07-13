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
        guard navigator.open(task: task) else { return false }

        if task.isUnread {
            markViewed(task)
        }
        dismiss()
        return true
    }

    @discardableResult
    func open(route: TaskNotificationRoute, currentTasks: [PulseTask]) -> Bool {
        if let task = currentTasks.first(where: route.matches) {
            return open(task: task)
        }

        guard route.allowsCodexFallback,
              navigator.open(threadID: route.threadID) else { return false }
        dismiss()
        return true
    }
}
