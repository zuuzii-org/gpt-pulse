import Foundation

enum PulsePreferenceKey {
    static let edgeTriggerEnabled = "edgeTriggerEnabled"
    static let disableInFullScreen = "disableInFullScreen"
    static let notificationsEnabled = "notificationsEnabled"
    static let notificationSoundEnabled = "notificationSoundEnabled"
}

@MainActor
final class PulseSettings: ObservableObject {
    @Published var edgeTriggerEnabled: Bool {
        didSet { defaults.set(edgeTriggerEnabled, forKey: PulsePreferenceKey.edgeTriggerEnabled) }
    }

    @Published var disableInFullScreen: Bool {
        didSet { defaults.set(disableInFullScreen, forKey: PulsePreferenceKey.disableInFullScreen) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: PulsePreferenceKey.notificationsEnabled) }
    }

    @Published var notificationSoundEnabled: Bool {
        didSet { defaults.set(notificationSoundEnabled, forKey: PulsePreferenceKey.notificationSoundEnabled) }
    }

    let edgeDwellDuration: TimeInterval = 0.2
    let panelDismissDelay: TimeInterval = 0.3
    let panelWidth: CGFloat = 400

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        edgeTriggerEnabled = defaults.value(
            forKey: PulsePreferenceKey.edgeTriggerEnabled,
            default: true
        )
        disableInFullScreen = defaults.value(
            forKey: PulsePreferenceKey.disableInFullScreen,
            default: true
        )
        notificationsEnabled = defaults.value(
            forKey: PulsePreferenceKey.notificationsEnabled,
            default: true
        )
        notificationSoundEnabled = defaults.value(
            forKey: PulsePreferenceKey.notificationSoundEnabled,
            default: false
        )
    }
}

private extension UserDefaults {
    func value(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
