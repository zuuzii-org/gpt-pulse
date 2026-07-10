import Combine
import Foundation
import UserNotifications

enum PulseNotificationKind: String {
    case waitingForApproval
    case waitingForAnswer
    case completed
    case failed
    case interrupted

    init?(state: PulseTaskState) {
        switch state {
        case .waitingForApproval:
            self = .waitingForApproval
        case .waitingForAnswer:
            self = .waitingForAnswer
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .interrupted:
            self = .interrupted
        case .running:
            return nil
        }
    }

    var title: String {
        switch self {
        case .waitingForApproval:
            return "Codex 等待授权"
        case .waitingForAnswer:
            return "Codex 等待你的回答"
        case .completed:
            return "任务已完成"
        case .failed:
            return "任务执行失败"
        case .interrupted:
            return "任务已中断"
        }
    }
}

struct TaskNotificationRoute: Equatable, Sendable {
    let taskID: String
    let threadID: String

    init(taskID: String, threadID: String) {
        self.taskID = taskID
        self.threadID = threadID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let taskID = userInfo["taskID"] as? String,
              !taskID.isEmpty,
              let threadID = userInfo["threadID"] as? String,
              !threadID.isEmpty else {
            return nil
        }

        self.init(taskID: taskID, threadID: threadID)
    }

    var userInfo: [String: String] {
        ["taskID": taskID, "threadID": threadID]
    }
}

@MainActor
final class NotificationService {
    private let center: UNUserNotificationCenter
    private let settings: PulseSettings
    private let delegateBridge: NotificationDelegateBridge

    init(
        settings: PulseSettings,
        onOpenTask: @escaping @MainActor (TaskNotificationRoute) -> Void,
        center: UNUserNotificationCenter = .current()
    ) {
        self.settings = settings
        self.center = center
        delegateBridge = NotificationDelegateBridge { route in
            Task { @MainActor in
                onOpenTask(route)
            }
        }
        center.delegate = delegateBridge
    }

    func requestAuthorizationIfNeeded() async {
        guard settings.notificationsEnabled else { return }

        let currentSettings = await center.notificationSettings()
        guard currentSettings.authorizationStatus == .notDetermined else { return }

        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func post(task: PulseTask, kind: PulseNotificationKind) async {
        guard settings.notificationsEnabled else { return }

        let notificationSettings = await center.notificationSettings()
        guard notificationSettings.authorizationStatus == .authorized
                || notificationSettings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.subtitle = task.title
        content.body = task.displayStatusText.isEmpty
            ? task.projectDirectory
            : task.displayStatusText
        content.categoryIdentifier = "GPT_PULSE_TASK"
        content.threadIdentifier = task.threadId
        content.userInfo = TaskNotificationRoute(
            taskID: task.id,
            threadID: task.threadId
        ).userInfo
        content.sound = settings.notificationSoundEnabled ? .default : nil

        let timestamp = Int(task.updatedAt.timeIntervalSince1970 * 1_000)
        let request = UNNotificationRequest(
            identifier: "gpt-pulse.\(kind.rawValue).\(task.id).\(timestamp)",
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }
}

@MainActor
final class TaskNotificationObserver {
    private let monitor: TaskMonitor
    private let notificationService: NotificationService
    private var transitionTracker = TaskNotificationTransitionTracker()
    private var cancellable: AnyCancellable?

    init(monitor: TaskMonitor, notificationService: NotificationService) {
        self.monitor = monitor
        self.notificationService = notificationService
    }

    func start() {
        guard cancellable == nil else { return }

        cancellable = monitor.$snapshot
            .sink { [weak self] snapshot in
                self?.handle(snapshot)
            }
    }

    func stop() {
        cancellable = nil
        transitionTracker = TaskNotificationTransitionTracker()
    }

    private func handle(_ snapshot: TaskSnapshot) {
        for notification in transitionTracker.notifications(in: snapshot) {
            Task {
                await notificationService.post(
                    task: notification.task,
                    kind: notification.kind
                )
            }
        }
    }
}

struct TaskNotificationTransitionTracker {
    private var previousStates: [String: PulseTaskState] = [:]
    private var hasSeededInitialSnapshot = false

    mutating func notifications(
        in snapshot: TaskSnapshot
    ) -> [(task: PulseTask, kind: PulseNotificationKind)] {
        guard snapshot.refreshedAt != .distantPast else { return [] }

        let currentStates = Dictionary(
            uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.state) }
        )

        defer {
            previousStates = currentStates
            hasSeededInitialSnapshot = true
        }

        guard hasSeededInitialSnapshot else { return [] }

        return snapshot.tasks.compactMap { task in
            guard previousStates[task.id] != task.state,
                  let kind = PulseNotificationKind(state: task.state) else {
                return nil
            }
            return (task, kind)
        }
    }
}

private final class NotificationDelegateBridge: NSObject, UNUserNotificationCenterDelegate {
    private let openTask: @Sendable (TaskNotificationRoute) -> Void

    init(openTask: @escaping @Sendable (TaskNotificationRoute) -> Void) {
        self.openTask = openTask
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard let route = TaskNotificationRoute(
            userInfo: response.notification.request.content.userInfo
        ) else {
            return
        }

        openTask(route)
    }
}
