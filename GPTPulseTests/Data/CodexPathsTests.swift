import Foundation
import XCTest
@testable import GPTPulse

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
        XCTAssertEqual(
            paths.pluginJournalURL.lastPathComponent,
            "events.jsonl"
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
