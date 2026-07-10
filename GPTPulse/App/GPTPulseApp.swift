import AppKit
import SwiftUI

@main
struct GPTPulseApp: App {
    @NSApplicationDelegateAdaptor(GPTPulseAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                launchAtLogin: appDelegate.launchAtLogin,
                requestNotificationAuthorization: {
                    await appDelegate.requestNotificationAuthorization()
                }
            )
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class GPTPulseAppDelegate: NSObject, NSApplicationDelegate {
    let settings = PulseSettings()
    let launchAtLogin = LaunchAtLoginService()

    private let monitor = TaskMonitor.makeLive()
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator(
            monitor: monitor,
            settings: settings,
            launchAtLogin: launchAtLogin
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func requestNotificationAuthorization() async {
        await coordinator?.requestNotificationAuthorization()
    }
}
