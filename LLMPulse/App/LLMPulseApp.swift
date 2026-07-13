import AppKit
import SwiftUI

@main
struct LLMPulseApp: App {
    @NSApplicationDelegateAdaptor(LLMPulseAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                launchAtLogin: appDelegate.launchAtLogin,
                requestNotificationAuthorization: {
                    await appDelegate.requestNotificationAuthorization()
                }
            )
            .environment(\.locale, appDelegate.settings.appLanguage.locale)
            .environment(\.pulseLanguage, appDelegate.settings.appLanguage)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class LLMPulseAppDelegate: NSObject, NSApplicationDelegate {
    let settings = PulseSettings()
    let launchAtLogin = LaunchAtLoginService()

    private lazy var monitor = TaskMonitor.makeLive()
    private var coordinator: AppCoordinator?
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit-test hosts must not inspect installed applications, migrate
        // support data, start background polling, or terminate before XCTest
        // finishes bootstrapping.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        launchTask = Task { [weak self] in
            guard let self else { return }
            let result = await AppBundleNameMigrator.live(
                loginItemManager: launchAtLogin
            ).run()
            guard !Task.isCancelled else { return }

            switch result {
            case .terminateAfterRelaunch:
                launchTask = nil
                NSApp.terminate(nil)
            case let .continueLaunch(issues):
                if !issues.isEmpty {
                    presentMigrationIssues(issues)
                }
                guard !issues.contains(where: \.blocksLaunch) else {
                    launchTask = nil
                    NSApp.terminate(nil)
                    return
                }
                startCoordinator()
            }
        }
    }

    private func startCoordinator() {
        guard coordinator == nil else { return }
        let coordinator = AppCoordinator(
            monitor: monitor,
            settings: settings,
            launchAtLogin: launchAtLogin
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        launchTask = nil
        coordinator?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func requestNotificationAuthorization() async {
        await coordinator?.requestNotificationAuthorization()
    }

    private func presentMigrationIssues(_ issues: [AppBundleNameMigrationIssue]) {
        guard let firstIssue = issues.first else { return }
        let language = settings.appLanguage
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = firstIssue.title(language: language)
        alert.informativeText = issues
            .map { $0.message(language: language) }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: PulseL10n.text("好", language: language))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
