import Foundation
import XCTest
@testable import LLMPulse

final class CodexPathsTests: XCTestCase {
    func testDiscoversStateDatabasesByNumericSuffix() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent("custom-codex", isDirectory: true)
        let sqliteDirectory = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: sqliteDirectory.appendingPathComponent("state_4.sqlite"))
        try Data().write(to: sqliteDirectory.appendingPathComponent("state_12.sqlite"))
        try Data().write(to: sqliteDirectory.appendingPathComponent("state_invalid.sqlite"))

        let paths = CodexPaths.live(
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: home
        )

        XCTAssertEqual(
            paths.stateDatabaseCandidates.map(\.lastPathComponent),
            ["state_12.sqlite", "state_4.sqlite"]
        )
        XCTAssertFalse(paths.receiptsDatabaseURL.path.hasPrefix(codexHome.path))
        XCTAssertTrue(
            paths.receiptsDatabaseURL.path.contains(
                "/Application Support/\(PulseBrand.applicationSupportDirectoryName)/"
            )
        )
        XCTAssertEqual(
            paths.pluginJournalURL.lastPathComponent,
            "events.jsonl"
        )
        XCTAssertEqual(paths.compatibilityPluginJournalURLs.count, 1)
        XCTAssertEqual(
            paths.compatibilityPluginJournalURLs[0].deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent,
            LegacyCompatibility.V1.applicationSupportDirectoryName
        )
    }

    func testLiveAtomicallyMigratesLegacyApplicationSupportTree() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let legacyEvents = legacyRoot
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let legacyReceipts = legacyRoot.appendingPathComponent("receipts.sqlite")
        try FileManager.default.createDirectory(
            at: legacyEvents.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy-events".utf8).write(to: legacyEvents)
        try Data("legacy-receipts".utf8).write(to: legacyReceipts)

        let paths = CodexPaths.live(homeDirectory: home)

        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        XCTAssertEqual(paths.receiptsDatabaseURL, currentRoot.appendingPathComponent("receipts.sqlite"))
        XCTAssertEqual(try Data(contentsOf: paths.receiptsDatabaseURL), Data("legacy-receipts".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.pluginJournalURL), Data("legacy-events".utf8))
        XCTAssertEqual(paths.compatibilityPluginJournalURLs.count, 1)
        XCTAssertEqual(
            paths.compatibilityPluginJournalURLs[0].deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent,
            LegacyCompatibility.V1.applicationSupportDirectoryName
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testUnsafeLegacySupportPathIsNotAddedAsJournalCandidate() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("unsafe-target", isDirectory: true)
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: legacyRoot,
            withDestinationURL: target
        )

        let paths = CodexPaths.live(homeDirectory: home)

        XCTAssertTrue(paths.compatibilityPluginJournalURLs.isEmpty)
        XCTAssertEqual(
            paths.pluginJournalURL.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent,
            PulseBrand.applicationSupportDirectoryName
        )
    }

    func testUnsafeCurrentSupportPathDoesNotExposeLegacyJournalCandidate() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("unsafe-current-target", isDirectory: true)
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: currentRoot,
            withDestinationURL: target
        )

        let paths = CodexPaths.live(homeDirectory: home)

        XCTAssertTrue(paths.compatibilityPluginJournalURLs.isEmpty)
        XCTAssertEqual(
            paths.pluginJournalURL.deletingLastPathComponent()
                .deletingLastPathComponent().standardizedFileURL,
            currentRoot.standardizedFileURL
        )
    }

    func testPrefersMostRecentlyActiveDatabaseAtSameVersion() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let sqliteDirectory = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteDirectory,
            withIntermediateDirectories: true
        )

        let stale = sqliteDirectory.appendingPathComponent("state_5.sqlite")
        let active = codexHome.appendingPathComponent("state_5.sqlite")
        try Data().write(to: stale)
        try Data().write(to: active)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate.addingTimeInterval(60)],
            ofItemAtPath: active.path
        )

        let candidates = CodexPaths.discoverStateDatabases(in: codexHome)
        XCTAssertEqual(
            candidates.first?.resolvingSymlinksInPath(),
            active.resolvingSymlinksInPath()
        )
    }
}
