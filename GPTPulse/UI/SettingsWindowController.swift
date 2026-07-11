import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var hasPresented = false
    private var languageCancellable: AnyCancellable?

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
        window.title = PulseL10n.text("GPT Pulse 设置", language: settings.appLanguage)
        window.setContentSize(NSSize(width: 580, height: 600))
        window.contentMinSize = NSSize(width: 540, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("GPTPulse.SettingsWindow")

        super.init(window: window)
        window.delegate = self
        languageCancellable = settings.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak window] language in
                window?.title = PulseL10n.text("GPT Pulse 设置", language: language)
            }
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
