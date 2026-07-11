import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var usesChinesePunctuation: Bool {
        locale.identifier.lowercased().hasPrefix("zh")
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        switch self {
        case .system:
            return PulseL10n.text("跟随系统", language: interfaceLanguage)
        case .simplifiedChinese:
            return PulseL10n.text("简体中文", language: interfaceLanguage)
        case .english:
            return "English"
        }
    }

    fileprivate var localizationBundle: Bundle {
        let resourceName: String?
        switch self {
        case .system:
            resourceName = nil
        case .simplifiedChinese:
            resourceName = "zh-Hans"
        case .english:
            resourceName = "en"
        }

        guard let resourceName,
              let path = Bundle.main.path(forResource: resourceName, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

enum PulseL10n {
    static func text(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        let format = language.localizationBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }
}

private struct PulseLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    var pulseLanguage: AppLanguage {
        get { self[PulseLanguageEnvironmentKey.self] }
        set { self[PulseLanguageEnvironmentKey.self] = newValue }
    }
}
