import Foundation

/// H「アプリアイコンの未読バッジ」— on/off for the whole feature. Default
/// **on**. Same "plain `UserDefaults` key, `UserDefaults.registerOtegamiBadgeDefaults()`
/// seeds the real default at launch" pattern `ImageSettingsStore`/
/// `TranslationSettingsStore` already use elsewhere in this directory.
enum BadgeSettingsStore {
    static let enabledKey = "badge.enabled"
    static let defaultEnabled = true

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

extension UserDefaults {
    static func registerOtegamiBadgeDefaults() {
        standard.register(defaults: [
            BadgeSettingsStore.enabledKey: BadgeSettingsStore.defaultEnabled,
        ])
    }
}
