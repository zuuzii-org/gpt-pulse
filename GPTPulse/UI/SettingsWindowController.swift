import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var hasPresented = false

    init(
        settings: PulseSettings,
        launchAtLogin: LaunchAtLoginService,
        requestNotificationAuthorization: @escaping @MainActor () async -> Void
    ) {
        let rootView = SettingsView(
            settings: settings,
            launchAtLogin: launchAtLogin,
            requestNotificationAuthorization: requestNotificationAuthorization
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "GPT Pulse 设置"
        window.setContentSize(NSSize(width: 580, height: 540))
        window.contentMinSize = NSSize(width: 540, height: 500)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("GPTPulse.SettingsWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }

        if !hasPresented {
            window.center()
            hasPresented = true
        }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
