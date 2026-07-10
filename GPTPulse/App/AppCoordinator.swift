import AppKit

@MainActor
final class AppCoordinator {
    private let monitor: TaskMonitor
    private let settings: PulseSettings
    private let launchAtLogin: LaunchAtLoginService
    private var notificationService: NotificationService!
    private var taskOpeningService: TaskOpeningService!

    private var panelController: TaskPanelController!
    private var statusItemController: StatusItemController!
    private var edgeTriggerService: EdgeTriggerService!
    private var notificationObserver: TaskNotificationObserver!
    private var settingsWindowController: SettingsWindowController!

    init(
        monitor: TaskMonitor,
        settings: PulseSettings,
        launchAtLogin: LaunchAtLoginService
    ) {
        self.monitor = monitor
        self.settings = settings
        self.launchAtLogin = launchAtLogin

        let navigator = TaskNavigator()

        let sidebar = TaskSidebarView(
            monitor: monitor,
            onOpenTask: { [weak self] task in self?.openTask(task) ?? false },
            onMarkViewed: { [weak monitor] task in monitor?.markViewed(task: task) },
            onDismiss: { [weak self] in self?.panelController.hide() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        panelController = TaskPanelController(
            width: settings.panelWidth,
            dismissDelay: settings.panelDismissDelay,
            rootView: sidebar
        )

        taskOpeningService = TaskOpeningService(
            navigator: navigator,
            markViewed: { [weak monitor] task in monitor?.markViewed(task: task) },
            dismiss: { [weak self] in self?.panelController.hide() }
        )
        notificationService = NotificationService(settings: settings) { [weak self] route in
            self?.openNotification(route)
        }
        settingsWindowController = SettingsWindowController(
            settings: settings,
            launchAtLogin: launchAtLogin,
            requestNotificationAuthorization: { [weak self] in
                await self?.requestNotificationAuthorization()
            }
        )

        statusItemController = StatusItemController(monitor: monitor)
        statusItemController.onTogglePanel = { [weak self] in self?.togglePanel() }
        statusItemController.onRefresh = { [weak monitor] in monitor?.refresh() }
        statusItemController.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItemController.onQuit = { NSApp.terminate(nil) }
        panelController.setOutsideDismissExcludedView(statusItemController.button)

        edgeTriggerService = EdgeTriggerService(settings: settings)
        edgeTriggerService.isPanelVisible = { [weak self] in
            self?.panelController.isVisible ?? false
        }
        edgeTriggerService.onTrigger = { [weak self] screen in
            self?.panelController.show(on: screen)
        }
        edgeTriggerService.onPointerMove = { [weak self] location in
            self?.panelController.handlePointerMove(to: location)
        }

        notificationObserver = TaskNotificationObserver(
            monitor: monitor,
            notificationService: notificationService
        )
    }

    func start() {
        monitor.start()
        notificationObserver.start()

#if DEBUG
        let isPanelUITest = ProcessInfo.processInfo.arguments.contains("--show-panel-for-ui-test")
        if isPanelUITest {
            panelController.preventsAutomaticDismiss = true
            if let screen = NSScreen.main {
                panelController.show(on: screen)
            }
        } else {
            edgeTriggerService.start()
        }
#else
        edgeTriggerService.start()
#endif

        Task {
            await notificationService.requestAuthorizationIfNeeded()
        }
    }

    func stop() {
        edgeTriggerService.stop()
        notificationObserver.stop()
        panelController.hide()
        monitor.stop()
    }

    func requestNotificationAuthorization() async {
        await notificationService.requestAuthorizationIfNeeded()
    }

    private func togglePanel() {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.containing(location) ?? NSScreen.main
        guard let screen else { return }
        panelController.toggle(on: screen)
    }

    private func openTask(_ task: PulseTask) -> Bool {
        taskOpeningService.open(task: task)
    }

    private func openNotification(_ route: TaskNotificationRoute) {
        taskOpeningService.open(route: route, currentTasks: monitor.snapshot.tasks)
    }

    private func openSettings() {
        panelController.hide()
        launchAtLogin.refresh()
        settingsWindowController.present()
    }
}
