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
        XCTAssertEqual(settings.notificationAttentionLevel, .attentionOnly)
        XCTAssertTrue(settings.mutedProjectExpirations.isEmpty)
        XCTAssertEqual(settings.edgeDwellDuration, 0.2)
        XCTAssertEqual(settings.panelDismissDelay, 0.3)
        XCTAssertEqual(settings.statusItemPanelDisplayDuration, 5)
        XCTAssertEqual(settings.panelWidth, 400)
    }

    func testPersistsChanges() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)
        settings.edgeTriggerEnabled = false
        settings.notificationSoundEnabled = true
        settings.notificationAttentionLevel = .important
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        settings.muteProject("/tmp/project", until: expiration)
        let persistedMuteKeys = defaults.dictionary(
            forKey: PulsePreferenceKey.mutedProjectExpirations
        ).map { Array($0.keys) } ?? []
        XCTAssertFalse(persistedMuteKeys.contains("/tmp/project"))
        XCTAssertEqual(persistedMuteKeys.first?.count, 64)

        let reloaded = PulseSettings(defaults: defaults)
        XCTAssertFalse(reloaded.edgeTriggerEnabled)
        XCTAssertTrue(reloaded.notificationSoundEnabled)
        XCTAssertEqual(reloaded.notificationAttentionLevel, .important)
        XCTAssertEqual(reloaded.mutedProjectExpirations.count, 1)
        XCTAssertTrue(
            reloaded.isProjectMuted(
                "/tmp/project",
                asOf: expiration.addingTimeInterval(-1)
            )
        )

        reloaded.unmuteProject("/tmp/project")
        XCTAssertFalse(reloaded.isProjectMuted("/tmp/project", asOf: expiration.addingTimeInterval(-1)))
    }

    func testExpiredProjectMutesAreIgnoredAndCleanedUp() {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PulseSettings(defaults: defaults)
        let now = Date.now
        settings.muteProject("/tmp/expired", until: now.addingTimeInterval(60))
        settings.muteProject("/tmp/current", until: now.addingTimeInterval(3_600))

        XCTAssertFalse(
            settings.isProjectMuted(
                "/tmp/expired",
                asOf: now.addingTimeInterval(120)
            )
        )
        settings.cleanupExpiredProjectMutes(asOf: now.addingTimeInterval(120))

        XCTAssertFalse(
            settings.isProjectMuted(
                "/tmp/expired",
                asOf: now.addingTimeInterval(120)
            )
        )
        XCTAssertTrue(
            settings.isProjectMuted(
                "/tmp/current",
                asOf: now.addingTimeInterval(120)
            )
        )
        XCTAssertEqual(settings.mutedProjectExpirations.count, 1)

        settings.clearProjectMutes()
        XCTAssertTrue(settings.mutedProjectExpirations.isEmpty)
    }

    func testMigratesLegacyPlaintextSubdirectoryMuteKeyToGitRoot() throws {
        let suiteName = "PulseSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let repository = temporaryRoot.appendingPathComponent("legacy-project", isDirectory: true)
        let subdirectory = repository.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let expiration = Date.now.addingTimeInterval(3_600)
        defaults.set(
            [subdirectory.path: expiration.timeIntervalSince1970],
            forKey: PulsePreferenceKey.mutedProjectExpirations
        )

        let settings = PulseSettings(defaults: defaults)

        XCTAssertTrue(
            settings.isProjectMuted(
                repository.path,
                asOf: expiration.addingTimeInterval(-1)
            )
        )
        let persistedKeys = defaults.dictionary(
            forKey: PulsePreferenceKey.mutedProjectExpirations
        ).map { Array($0.keys) } ?? []
        XCTAssertEqual(persistedKeys.count, 1)
        XCTAssertEqual(persistedKeys.first?.count, 64)
        XCTAssertFalse(persistedKeys.contains(subdirectory.path))
    }
}
