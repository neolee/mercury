import Foundation
import Testing
@testable import Mercury

@Suite("App Settings Navigation", .serialized)
@MainActor
struct AppSettingsNavigationTests {
    @Test("Digest tab request updates selected tab")
    func requestDigestTabUpdatesSelectedTab() {
        let defaultsSuite = TestUserDefaultsSuite(prefix: "AppSettingsNavigationTests")
        defer { defaultsSuite.cleanup() }

        let key = AppSettingsNavigation.selectedTabDefaultsKey
        let previousDefaults = AppSettingsNavigation.userDefaults
        AppSettingsNavigation.userDefaults = defaultsSuite.defaults
        defer { AppSettingsNavigation.userDefaults = previousDefaults }

        defaultsSuite.defaults.removeObject(forKey: key)
        #expect(AppSettingsNavigation.selectedTab() == .general)

        AppSettingsNavigation.requestDigestTab()

        #expect(AppSettingsNavigation.selectedTab() == .digest)
    }
}
