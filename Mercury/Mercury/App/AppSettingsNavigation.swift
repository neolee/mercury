import Foundation

enum AppSettingsTab: String, Hashable {
    case general
    case reader
    case agents
    case digest
}

enum AppSettingsNavigation {
    static let selectedTabDefaultsKey = "App.Settings.SelectedTab"
    static var userDefaults: UserDefaults = .standard

    static func selectedTab() -> AppSettingsTab {
        guard let rawValue = userDefaults.string(forKey: selectedTabDefaultsKey),
              let tab = AppSettingsTab(rawValue: rawValue) else {
            return .general
        }
        return tab
    }

    static func select(_ tab: AppSettingsTab) {
        userDefaults.set(tab.rawValue, forKey: selectedTabDefaultsKey)
        NotificationCenter.default.post(name: .appSettingsSelectedTabDidChange, object: tab.rawValue)
    }

    static func requestDigestTab() {
        select(.digest)
    }

    static func requestAgentsTab() {
        select(.agents)
    }
}

extension Notification.Name {
    static let appSettingsSelectedTabDidChange = Notification.Name("Mercury.AppSettingsSelectedTabDidChange")
}
