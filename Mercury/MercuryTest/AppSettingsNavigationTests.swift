import Foundation
import Testing
@testable import Mercury

@Suite("App Settings Navigation", .serialized)
struct AppSettingsNavigationTests {
    @Test("Digest tab request updates selected tab")
    func requestDigestTabUpdatesSelectedTab() {
        let key = AppSettingsNavigation.selectedTabDefaultsKey
        let previousValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppSettingsNavigation.selectedTab() == .general)

        AppSettingsNavigation.requestDigestTab()

        #expect(AppSettingsNavigation.selectedTab() == .digest)
    }
}
