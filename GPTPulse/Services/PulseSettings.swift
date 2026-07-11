import CryptoKit
import Foundation

enum NotificationAttentionLevel: String, CaseIterable, Identifiable {
    case attentionOnly
    case important
    case all

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .attentionOnly:
            return PulseL10n.text("仅需我处理", language: language)
        case .important:
            return PulseL10n.text("重要状态", language: language)
        case .all:
            return PulseL10n.text("全部", language: language)
        }
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .attentionOnly:
            return PulseL10n.text("等待授权、等待回答和失败时提醒", language: language)
        case .important:
            return PulseL10n.text("再包含完成通知；同批完成会合并", language: language)
        case .all:
            return PulseL10n.text("包含中断在内的所有可识别状态", language: language)
        }
    }
}

enum PulsePreferenceKey {
    static let edgeTriggerEnabled = "edgeTriggerEnabled"
    static let disableInFullScreen = "disableInFullScreen"
    static let notificationsEnabled = "notificationsEnabled"
    static let notificationSoundEnabled = "notificationSoundEnabled"
    static let notificationAttentionLevel = "notificationAttentionLevel"
    static let appLanguage = "appLanguage"
    static let mutedProjectExpirations = "mutedProjectExpirations"
    static let runningSectionExpanded = "runningSectionExpanded"
    static let recentSectionExpanded = "recentSectionExpanded"
}

@MainActor
final class PulseSettings: ObservableObject {
    @Published var appLanguage: AppLanguage {
        didSet { defaults.set(appLanguage.rawValue, forKey: PulsePreferenceKey.appLanguage) }
    }

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

    @Published var notificationAttentionLevel: NotificationAttentionLevel {
        didSet {
            defaults.set(
                notificationAttentionLevel.rawValue,
                forKey: PulsePreferenceKey.notificationAttentionLevel
            )
        }
    }

    @Published var runningSectionExpanded: Bool {
        didSet {
            defaults.set(
                runningSectionExpanded,
                forKey: PulsePreferenceKey.runningSectionExpanded
            )
        }
    }

    @Published var recentSectionExpanded: Bool {
        didSet {
            defaults.set(
                recentSectionExpanded,
                forKey: PulsePreferenceKey.recentSectionExpanded
            )
        }
    }

    @Published private(set) var mutedProjectExpirations: [String: Date]

    let edgeDwellDuration: TimeInterval = 0.2
    let panelDismissDelay: TimeInterval = 0.3
    let statusItemPanelDisplayDuration: TimeInterval = 5
    let panelWidth: CGFloat = 400

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appLanguage = defaults.string(forKey: PulsePreferenceKey.appLanguage)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
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
        notificationAttentionLevel = defaults.string(
            forKey: PulsePreferenceKey.notificationAttentionLevel
        ).flatMap(NotificationAttentionLevel.init(rawValue:)) ?? .attentionOnly
        runningSectionExpanded = defaults.value(
            forKey: PulsePreferenceKey.runningSectionExpanded,
            default: true
        )
        recentSectionExpanded = defaults.value(
            forKey: PulsePreferenceKey.recentSectionExpanded,
            default: true
        )

        let now = Date.now
        mutedProjectExpirations = defaults.dictionary(
            forKey: PulsePreferenceKey.mutedProjectExpirations
        )?.reduce(into: [:]) { result, item in
            guard let timestamp = item.value as? Double else { return }
            let expiration = Date(timeIntervalSince1970: timestamp)
            guard expiration > now else { return }
            let storedKey: String
            if Self.isHashedProjectMuteKey(item.key) {
                storedKey = item.key.lowercased()
            } else if let migratedKey = Self.projectMuteKey(item.key) {
                storedKey = migratedKey
            } else {
                return
            }
            result[storedKey] = max(result[storedKey] ?? .distantPast, expiration)
        } ?? [:]
        persistMutedProjects()
    }

    func isProjectMuted(_ projectDirectory: String, asOf date: Date = .now) -> Bool {
        guard let projectKey = Self.projectMuteKey(projectDirectory),
              let expiration = mutedProjectExpirations[projectKey] else {
            return false
        }
        return expiration > date
    }

    func muteProject(_ projectDirectory: String, until expiration: Date) {
        guard let projectKey = Self.projectMuteKey(projectDirectory) else { return }
        guard expiration > .now else {
            unmuteProject(projectDirectory)
            return
        }
        mutedProjectExpirations[projectKey] = expiration
        persistMutedProjects()
    }

    func unmuteProject(_ projectDirectory: String) {
        guard let projectKey = Self.projectMuteKey(projectDirectory),
              mutedProjectExpirations.removeValue(forKey: projectKey) != nil else {
            return
        }
        persistMutedProjects()
    }

    func clearProjectMutes() {
        guard !mutedProjectExpirations.isEmpty else { return }
        mutedProjectExpirations.removeAll()
        persistMutedProjects()
    }

    func cleanupExpiredProjectMutes(asOf date: Date = .now) {
        let active = mutedProjectExpirations.filter { $0.value > date }
        guard active.count != mutedProjectExpirations.count else { return }
        mutedProjectExpirations = active
        persistMutedProjects()
    }

    private func persistMutedProjects() {
        defaults.set(
            mutedProjectExpirations.mapValues(\.timeIntervalSince1970),
            forKey: PulsePreferenceKey.mutedProjectExpirations
        )
    }

    private static func projectMuteKey(_ projectDirectory: String) -> String? {
        let trimmed = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonicalPath = ProjectDirectoryIdentityResolver.identityDirectory(trimmed)
        guard !canonicalPath.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isHashedProjectMuteKey(_ key: String) -> Bool {
        key.count == 64 && key.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(Int(scalar.value))
                || (65...70).contains(Int(scalar.value))
                || (97...102).contains(Int(scalar.value))
        }
    }
}

private extension UserDefaults {
    func value(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
