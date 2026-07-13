import Darwin
import Foundation
import XCTest
@testable import LLMPulse

final class LegacyCompatibilityTests: XCTestCase {
    func testCurrentAndLegacyIdentifiersAreSeparated() {
        XCTAssertEqual(PulseBrand.bundleIdentifier, "com.zuuzii.LLMPulse")
        XCTAssertEqual(PulseBrand.applicationSupportDirectoryName, PulseBrand.displayName)
        XCTAssertNotEqual(
            LegacyCompatibility.V1.bundleIdentifier,
            PulseBrand.bundleIdentifier
        )
        XCTAssertNotEqual(
            LegacyCompatibility.V1.applicationSupportDirectoryName,
            PulseBrand.applicationSupportDirectoryName
        )
        XCTAssertEqual(
            LegacyCompatibility.legacyApplicationSupportURL(
                homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
            ).lastPathComponent,
            LegacyCompatibility.V1.applicationSupportDirectoryName
        )
    }

    func testApplicationSupportMigrationMovesWholeTreeAndIsIdempotent() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let receipts = legacyRoot.appendingPathComponent("receipts.sqlite")
        let receiptsWAL = legacyRoot.appendingPathComponent("receipts.sqlite-wal")
        let journal = legacyRoot
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("receipts".utf8).write(to: receipts)
        try Data("wal".utf8).write(to: receiptsWAL)
        try Data("events".utf8).write(to: journal)

        let first = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(first.state, .migrated)
        XCTAssertEqual(
            first.directoryURL,
            LegacyCompatibility.currentApplicationSupportURL(homeDirectory: home)
                .standardizedFileURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertEqual(
            try Data(contentsOf: first.directoryURL.appendingPathComponent("receipts.sqlite")),
            Data("receipts".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: first.directoryURL.appendingPathComponent("receipts.sqlite-wal")),
            Data("wal".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: first.directoryURL
                    .appendingPathComponent("events", isDirectory: true)
                    .appendingPathComponent("events.jsonl")
            ),
            Data("events".utf8)
        )

        let second = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )
        XCTAssertEqual(second.state, .current)
        XCTAssertEqual(second.directoryURL, first.directoryURL)
    }

    func testMigratedLegacyReceiptSymlinkRemainsUnreadableAndUntouched() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let target = home.appendingPathComponent("receipt-target.sqlite")
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: legacyRoot.appendingPathComponent("receipts.sqlite"),
            withDestinationURL: target
        )

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .migrated)
        do {
            _ = try await ReceiptStore(
                databaseURL: resolution.directoryURL.appendingPathComponent("receipts.sqlite")
            ).snapshot()
            XCTFail("Expected migrated receipt symlink to fail closed")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
    }

    func testApplicationSupportConflictNeverOverwritesEitherTree() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentRoot,
            withIntermediateDirectories: true
        )
        let legacyReceipts = legacyRoot.appendingPathComponent("receipts.sqlite")
        let currentReceipts = currentRoot.appendingPathComponent("receipts.sqlite")
        try Data("legacy".utf8).write(to: legacyReceipts)
        try Data("current".utf8).write(to: currentReceipts)

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .conflict)
        XCTAssertEqual(resolution.directoryURL, currentRoot.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: legacyReceipts), Data("legacy".utf8))
        XCTAssertEqual(try Data(contentsOf: currentReceipts), Data("current".utf8))
    }

    func testConflictPrefersLegacyTreeWhenOnlyItContainsReceiptState() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        let currentEvents = currentRoot
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(
            at: currentEvents.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        let legacyReceipts = legacyRoot.appendingPathComponent("receipts.sqlite")
        try Data("events".utf8).write(to: currentEvents)
        try Data("legacy-receipts".utf8).write(to: legacyReceipts)

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .conflict)
        XCTAssertEqual(resolution.directoryURL, legacyRoot.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: currentEvents), Data("events".utf8))
        XCTAssertEqual(
            try Data(contentsOf: legacyReceipts),
            Data("legacy-receipts".utf8)
        )
    }

    func testConflictNeverPrefersLegacyReceiptSymlink() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        let currentEvents = currentRoot
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let receiptTarget = home.appendingPathComponent("receipt-target.sqlite")
        try FileManager.default.createDirectory(
            at: currentEvents.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        try Data("events".utf8).write(to: currentEvents)
        try Data("do-not-follow".utf8).write(to: receiptTarget)
        try FileManager.default.createSymbolicLink(
            at: legacyRoot.appendingPathComponent("receipts.sqlite"),
            withDestinationURL: receiptTarget
        )

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .conflict)
        XCTAssertEqual(resolution.directoryURL, currentRoot.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: receiptTarget), Data("do-not-follow".utf8))
    }

    func testEmptyCurrentDirectoryIsRemovedBeforeAtomicLegacyMigration() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: legacyRoot.appendingPathComponent("receipts.sqlite")
        )
        try FileManager.default.createDirectory(
            at: currentRoot,
            withIntermediateDirectories: true
        )

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .migrated)
        XCTAssertEqual(resolution.directoryURL, currentRoot.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertEqual(
            try Data(
                contentsOf: currentRoot.appendingPathComponent("receipts.sqlite")
            ),
            Data("legacy".utf8)
        )
    }

    func testLegacyApplicationSupportSymlinkIsNeverFollowed() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("symlink-target", isDirectory: true)
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

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .unsafeLegacySource)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: LegacyCompatibility.currentApplicationSupportURL(
                    homeDirectory: home
                ).path
            )
        )
        XCTAssertNotNil(
            try FileManager.default.destinationOfSymbolicLink(atPath: legacyRoot.path)
        )
    }

    func testCurrentApplicationSupportSymlinkIsNeverFollowed() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("current-target", isDirectory: true)
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

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .unsafeCurrentDestination)
        XCTAssertEqual(resolution.directoryURL, currentRoot.standardizedFileURL)
        XCTAssertNotNil(
            try FileManager.default.destinationOfSymbolicLink(atPath: currentRoot.path)
        )
    }

    func testCurrentApplicationSupportWrongOwnerEvidenceFailsClosed() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: currentRoot,
            withIntermediateDirectories: true
        )

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home,
            currentUserID: geteuid() &+ 1
        )

        XCTAssertEqual(resolution.state, .unsafeCurrentDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentRoot.path))
    }

    func testGroupWritableCurrentApplicationSupportFailsClosed() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let currentRoot = LegacyCompatibility.currentApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: currentRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770],
            ofItemAtPath: currentRoot.path
        )

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home
        )

        XCTAssertEqual(resolution.state, .unsafeCurrentDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentRoot.path))
    }

    func testWrongOwnerEvidenceFailsClosedWithoutMovingLegacyTree() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyRoot = LegacyCompatibility.legacyApplicationSupportURL(
            homeDirectory: home
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )

        let resolution = LegacyCompatibility.resolveApplicationSupportDirectory(
            homeDirectory: home,
            currentUserID: geteuid() &+ 1
        )

        XCTAssertEqual(resolution.state, .unsafeLegacySource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    private func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false
        )
        return home
    }
}
