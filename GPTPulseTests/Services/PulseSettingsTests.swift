import XCTest
@testable import GPTPulse

@MainActor
final class PulseSettingsTests: XCTestCase {
    func testUsesProductDefaultsForNewInstall() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)

        XCTAssertTrue(settings.edgeTriggerEnabled)
        XCTAssertTrue(settings.disableInFullScreen)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertFalse(settings.notificationSoundEnabled)
        XCTAssertEqual(settings.edgeDwellDuration, 0.2)
        XCTAssertEqual(settings.panelDismissDelay, 0.3)
        XCTAssertEqual(settings.panelWidth, 400)
    }

    func testPersistsChanges() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)
        settings.edgeTriggerEnabled = false
        settings.notificationSoundEnabled = true

        let reloaded = PulseSettings(defaults: defaults)
        XCTAssertFalse(reloaded.edgeTriggerEnabled)
        XCTAssertTrue(reloaded.notificationSoundEnabled)
    }
}
