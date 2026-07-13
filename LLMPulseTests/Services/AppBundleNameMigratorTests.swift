import Darwin
import Foundation
import XCTest
@testable import LLMPulse

@MainActor
final class AppBundleNameMigratorTests: XCTestCase {
    func testLegacyBundleMovesAtomicallyThenRequestsRelaunch() async {
        let fixture = MigrationFixture(loginState: .enabled)

        let result = await fixture.migrator.run()

        XCTAssertEqual(result, .terminateAfterRelaunch)
        XCTAssertFalse(fixture.files.itemExists(at: fixture.legacyURL))
        XCTAssertTrue(fixture.files.itemExists(at: fixture.canonicalURL))
        XCTAssertEqual(fixture.files.moves, [
            .init(source: fixture.legacyURL.path, destination: fixture.canonicalURL.path),
        ])
        XCTAssertEqual(fixture.login.unregisterStates, [.enabled])
        XCTAssertTrue(fixture.login.restoreStates.isEmpty)
        XCTAssertEqual(fixture.relauncher.urls, [fixture.canonicalURL])
        XCTAssertEqual(fixture.journal.journal?.phase, .moved)
    }

    func testRelaunchFailureRollsBundleAndLoginItemBack() async {
        let fixture = MigrationFixture(loginState: .enabled)
        fixture.relauncher.error = TestMigrationError.relaunchFailed

        let result = await fixture.migrator.run()

        XCTAssertTrue(fixture.files.itemExists(at: fixture.legacyURL))
        XCTAssertFalse(fixture.files.itemExists(at: fixture.canonicalURL))
        XCTAssertEqual(fixture.files.moves.count, 2)
        XCTAssertEqual(fixture.login.unregisterStates, [.enabled])
        XCTAssertEqual(fixture.login.restoreStates, [.enabled])
        XCTAssertNil(fixture.journal.journal)
        assertSingleOperationFailure(result)
    }

    func testMoveFailureRestoresLoginItemAndClearsJournal() async {
        let fixture = MigrationFixture(loginState: .enabled)
        fixture.files.moveError = TestMigrationError.invalidMove

        let result = await fixture.migrator.run()

        XCTAssertTrue(fixture.files.itemExists(at: fixture.legacyURL))
        XCTAssertFalse(fixture.files.itemExists(at: fixture.canonicalURL))
        XCTAssertEqual(fixture.login.unregisterStates, [.enabled])
        XCTAssertEqual(fixture.login.restoreStates, [.enabled])
        XCTAssertNil(fixture.journal.journal)
        assertSingleOperationFailure(result)
    }

    func testPhaseSaveFailureAfterUnregisterRollsBackLoginItem() async {
        let fixture = MigrationFixture(loginState: .requiresApproval)
        fixture.journal.saveErrorOnCalls = [2]

        let result = await fixture.migrator.run()

        XCTAssertTrue(fixture.files.itemExists(at: fixture.legacyURL))
        XCTAssertFalse(fixture.files.itemExists(at: fixture.canonicalURL))
        XCTAssertEqual(fixture.login.unregisterStates, [.requiresApproval])
        XCTAssertEqual(fixture.login.restoreStates, [.requiresApproval])
        XCTAssertNil(fixture.journal.journal)
        assertSingleOperationFailure(result)
    }

    func testNotRegisteredLoginItemIsNeverChangedDuringMigration() async {
        let fixture = MigrationFixture(loginState: .notRegistered)

        let result = await fixture.migrator.run()

        XCTAssertEqual(result, .terminateAfterRelaunch)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
        XCTAssertTrue(fixture.login.restoreStates.isEmpty)
    }

    func testDestinationConflictNeverOverwritesOrUnregisters() async {
        let fixture = MigrationFixture(loginState: .enabled, canonicalExists: true)

        let result = await fixture.migrator.run()

        XCTAssertEqual(
            result,
            .continueLaunch(issues: [
                .destinationExists(path: fixture.canonicalURL.path),
            ])
        )
        XCTAssertEqual(fixture.journal.loadCallCount, 0)
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
        XCTAssertTrue(fixture.relauncher.urls.isEmpty)
    }

    func testSymbolicLinkAndUnwritableParentAreRejected() async {
        let symbolicFixture = MigrationFixture(loginState: .notRegistered)
        symbolicFixture.files.symbolicLinks.insert(symbolicFixture.legacyURL.path)

        let symbolicResult = await symbolicFixture.migrator.run()
        XCTAssertEqual(
            symbolicResult,
            .continueLaunch(issues: [
                .symbolicLink(path: symbolicFixture.legacyURL.path),
            ])
        )

        let permissionFixture = MigrationFixture(loginState: .enabled)
        permissionFixture.files.writableDirectories.remove(permissionFixture.root.path)

        let permissionResult = await permissionFixture.migrator.run()
        XCTAssertEqual(
            permissionResult,
            .continueLaunch(issues: [
                .permissionDenied(path: permissionFixture.canonicalURL.path),
            ])
        )
        XCTAssertTrue(permissionFixture.login.unregisterStates.isEmpty)
    }

    func testBundleOutsideApplicationDirectoriesIsNeverTouched() async {
        let root = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let legacyURL = root.appendingPathComponent(
            LegacyCompatibility.V1.applicationBundleFilename,
            isDirectory: true
        )
        let files = FakeMigrationFileManager(items: [legacyURL.path])
        let journal = FakeMigrationJournalStore()
        let login = FakeMigrationLoginItemManager(state: .enabled)
        let relauncher = FakeMigrationRelauncher()
        let migrator = AppBundleNameMigrator(
            currentBundleURL: legacyURL,
            allowedApplicationDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
            ],
            fileManager: files,
            journalStore: journal,
            loginItemManager: login,
            relauncher: relauncher
        )

        let result = await migrator.run()

        XCTAssertEqual(result, .continueLaunch(issues: []))
        XCTAssertTrue(files.moves.isEmpty)
        XCTAssertTrue(login.unregisterStates.isEmpty)
        XCTAssertNil(journal.journal)
    }

    func testCanonicalBundleCompletesCrashRecoveryAndRestoresLoginItem() async {
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .notRegistered,
            legacyExists: false,
            canonicalExists: true
        )
        fixture.journal.journal = AppBundleNameMigrationJournal(
            sourcePath: fixture.legacyURL.path,
            destinationPath: fixture.canonicalURL.path,
            previousLoginItemState: .requiresApproval,
            phase: .loginItemUnregistered
        )

        let result = await fixture.migrator.run()

        XCTAssertEqual(result, .continueLaunch(issues: []))
        XCTAssertEqual(fixture.login.restoreStates, [.requiresApproval])
        XCTAssertNil(fixture.journal.journal)
        XCTAssertTrue(fixture.relauncher.urls.isEmpty)
    }

    func testCanonicalBundleRetriesFailedLoginItemRestoreOnNextLaunch() async {
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .notRegistered,
            legacyExists: false,
            canonicalExists: true
        )
        fixture.journal.journal = AppBundleNameMigrationJournal(
            sourcePath: fixture.legacyURL.path,
            destinationPath: fixture.canonicalURL.path,
            previousLoginItemState: .enabled,
            phase: .moved
        )
        fixture.login.restoreError = TestMigrationError.restoreFailed

        let firstResult = await fixture.migrator.run()

        assertSingleOperationFailure(firstResult)
        XCTAssertNotNil(fixture.journal.journal)

        fixture.login.restoreError = nil
        let secondResult = await fixture.migrator.run()

        XCTAssertEqual(secondResult, .continueLaunch(issues: []))
        XCTAssertEqual(fixture.login.restoreStates, [.enabled, .enabled])
        XCTAssertNil(fixture.journal.journal)
    }

    func testCorruptJournalIsDiscardedAndRequestsLoginItemVerification() async {
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .notRegistered,
            legacyExists: false,
            canonicalExists: true
        )
        fixture.journal.loadError = AppBundleNameMigrationJournalError.corruptOrUnsupported

        let result = await fixture.migrator.run()

        guard case let .continueLaunch(issues) = result,
              issues.count == 1,
              case .loginItemVerificationRequired = issues[0] else {
            return XCTFail("Expected login-item verification warning")
        }
        XCTAssertEqual(fixture.journal.clearCallCount, 1)
        XCTAssertTrue(fixture.login.restoreStates.isEmpty)
    }

    func testUnexpectedJournalPathIsDiscardedWithoutTouchingEitherApp() async {
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: false,
            canonicalExists: true
        )
        fixture.journal.journal = AppBundleNameMigrationJournal(
            sourcePath: "/Applications/Other.app",
            destinationPath: "/Applications/Unexpected.app",
            previousLoginItemState: .enabled,
            phase: .moved
        )

        let result = await fixture.migrator.run()

        guard case let .continueLaunch(issues) = result,
              issues.count == 1,
              case .loginItemVerificationRequired = issues[0] else {
            return XCTFail("Expected login-item verification warning")
        }
        XCTAssertNil(fixture.journal.journal)
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.restoreStates.isEmpty)
    }

    func testCanonicalBundleReportsLegacyCopyWithoutDeletingEitherApp() async {
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: true,
            canonicalExists: true
        )

        let result = await fixture.migrator.run()

        XCTAssertEqual(
            result,
            .continueLaunch(issues: [
                .legacyCopyConflict(
                    legacyPath: fixture.legacyURL.path,
                    currentPath: fixture.canonicalURL.path
                ),
            ])
        )
        XCTAssertTrue(fixture.files.itemExists(at: fixture.legacyURL))
        XCTAssertTrue(fixture.files.itemExists(at: fixture.canonicalURL))
        XCTAssertTrue(fixture.files.moves.isEmpty)
    }

    func testApplicationSupportConflictIsSurfacedWithoutTouchingEitherTree() async {
        let supportParent = URL(
            fileURLWithPath: "/Users/test/Library/Application Support",
            isDirectory: true
        )
        let currentSupportURL = supportParent.appendingPathComponent(
            PulseBrand.applicationSupportDirectoryName,
            isDirectory: true
        )
        let legacySupportURL = supportParent.appendingPathComponent(
            LegacyCompatibility.V1.applicationSupportDirectoryName,
            isDirectory: true
        )
        let resolution = LegacyApplicationSupportResolution(
            directoryURL: currentSupportURL,
            state: .conflict
        )
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: false,
            canonicalExists: true,
            applicationSupportResolution: resolution
        )

        let result = await fixture.migrator.run()

        XCTAssertEqual(
            result,
            .continueLaunch(issues: [
                .applicationSupportConflict(
                    legacyPath: legacySupportURL.path,
                    currentPath: currentSupportURL.path
                ),
            ])
        )
        XCTAssertEqual(fixture.journal.loadCallCount, 0)
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
    }

    func testUnsafeLegacySupportDirectoryIsSurfacedWithoutMutation() async {
        let supportParent = URL(
            fileURLWithPath: "/Users/test/Library/Application Support",
            isDirectory: true
        )
        let currentSupportURL = supportParent.appendingPathComponent(
            PulseBrand.applicationSupportDirectoryName,
            isDirectory: true
        )
        let legacySupportURL = supportParent.appendingPathComponent(
            LegacyCompatibility.V1.applicationSupportDirectoryName,
            isDirectory: true
        )
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: false,
            canonicalExists: true,
            applicationSupportResolution: LegacyApplicationSupportResolution(
                directoryURL: currentSupportURL,
                state: .unsafeLegacySource
            )
        )

        let result = await fixture.migrator.run()

        XCTAssertEqual(
            result,
            .continueLaunch(issues: [
                .applicationSupportMigrationBlocked(
                    legacyPath: legacySupportURL.path,
                    currentPath: currentSupportURL.path,
                    detail: "Legacy directory type, owner, or permissions are unsafe"
                ),
            ])
        )
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
    }

    func testUnsafeCurrentSupportDirectoryBlocksLaunchBeforeJournalAccess() async {
        let supportParent = URL(
            fileURLWithPath: "/Users/test/Library/Application Support",
            isDirectory: true
        )
        let currentSupportURL = supportParent.appendingPathComponent(
            PulseBrand.applicationSupportDirectoryName,
            isDirectory: true
        )
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: false,
            canonicalExists: true,
            applicationSupportResolution: LegacyApplicationSupportResolution(
                directoryURL: currentSupportURL,
                state: .unsafeCurrentDestination
            )
        )

        let result = await fixture.migrator.run()

        let expectedIssue = AppBundleNameMigrationIssue
            .applicationSupportDestinationUnsafe(
                path: currentSupportURL.path,
                detail: "Current directory type, owner, or permissions are unsafe"
            )
        XCTAssertEqual(result, .continueLaunch(issues: [expectedIssue]))
        XCTAssertTrue(expectedIssue.blocksLaunch)
        XCTAssertEqual(fixture.journal.loadCallCount, 0)
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
    }

    func testUnsafeDestinationsAndDuplicateAppsBlockLaunch() {
        let blocking = AppBundleNameMigrationIssue.applicationSupportDestinationUnsafe(
            path: "/unsafe",
            detail: "unsafe"
        )
        let warning = AppBundleNameMigrationIssue.applicationSupportMigrationBlocked(
            legacyPath: "/legacy",
            currentPath: "/current",
            detail: "unsafe"
        )

        XCTAssertTrue(blocking.blocksLaunch)
        XCTAssertFalse(warning.blocksLaunch)
        XCTAssertTrue(
            AppBundleNameMigrationIssue.applicationSupportConflict(
                legacyPath: "/legacy",
                currentPath: "/current"
            ).blocksLaunch
        )
        XCTAssertTrue(
            AppBundleNameMigrationIssue.legacyCopyConflict(
                legacyPath: "/legacy.app",
                currentPath: "/current.app"
            ).blocksLaunch
        )
        XCTAssertTrue(
            AppBundleNameMigrationIssue.destinationExists(
                path: "/current.app"
            ).blocksLaunch
        )
    }

    func testLegacyCopyPreflightBlocksBeforeDataOrLoginItemAccess() async {
        let issue = AppBundleNameMigrationIssue.legacyCopyConflict(
            legacyPath: "/Applications/legacy.app",
            currentPath: "/Applications/LLM Pulse.app"
        )
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: true,
            canonicalExists: true,
            preflightIssue: issue
        )

        let result = await fixture.migrator.run()

        XCTAssertEqual(result, .continueLaunch(issues: [issue]))
        XCTAssertEqual(fixture.journal.loadCallCount, 0)
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
    }

    func testPreflightFindsCanonicalNamedBridgeCopyOutsideCurrentPath() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let currentURL = URL(
            fileURLWithPath: "/Volumes/Installer/LLM Pulse.app",
            isDirectory: true
        )
        let installedBridgeURL = applications.appendingPathComponent(
            PulseBrand.applicationBundleFilename,
            isDirectory: true
        )
        let files = FakeMigrationFileManager(items: [installedBridgeURL.path])

        let conflict = AppBundleNameMigrator.conflictingInstalledBundleURL(
            currentBundleURL: currentURL,
            allowedApplicationDirectories: [applications],
            fileManager: files
        )

        XCTAssertEqual(conflict, installedBridgeURL.standardizedFileURL)
    }

    func testAtomicSupportMoveFailureSurfacesLegacyFallback() async {
        let supportParent = URL(
            fileURLWithPath: "/Users/test/Library/Application Support",
            isDirectory: true
        )
        let currentSupportURL = supportParent.appendingPathComponent(
            PulseBrand.applicationSupportDirectoryName,
            isDirectory: true
        )
        let legacySupportURL = supportParent.appendingPathComponent(
            LegacyCompatibility.V1.applicationSupportDirectoryName,
            isDirectory: true
        )
        let fixture = MigrationFixture(
            currentName: PulseBrand.applicationBundleFilename,
            loginState: .enabled,
            legacyExists: false,
            canonicalExists: true,
            applicationSupportResolution: LegacyApplicationSupportResolution(
                directoryURL: legacySupportURL,
                state: .legacyFallback(errorCode: 18)
            )
        )

        let result = await fixture.migrator.run()

        XCTAssertEqual(
            result,
            .continueLaunch(issues: [
                .applicationSupportMigrationDeferred(
                    legacyPath: legacySupportURL.path,
                    currentPath: currentSupportURL.path,
                    detail: "Atomic move failed with POSIX error 18"
                ),
            ])
        )
        XCTAssertTrue(fixture.files.moves.isEmpty)
        XCTAssertTrue(fixture.login.unregisterStates.isEmpty)
    }

    func testJournalStoreUsesOwnerOnlyPermissionsAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("migration.json")
        let store = JSONAppBundleNameMigrationJournalStore(journalURL: journalURL)
        let value = AppBundleNameMigrationJournal(
            sourcePath: "/Applications/\(LegacyCompatibility.V1.applicationBundleFilename)",
            destinationPath: "/Applications/LLM Pulse.app",
            previousLoginItemState: .enabled,
            phase: .moved
        )

        try store.save(value)

        XCTAssertEqual(try store.load(), value)
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let directoryPermissions = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testJournalStoreRejectsUnsupportedSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONAppBundleNameMigrationJournalStore(
            journalURL: root.appendingPathComponent("migration.json")
        )
        try store.save(AppBundleNameMigrationJournal(
            sourcePath: "/Applications/\(LegacyCompatibility.V1.applicationBundleFilename)",
            destinationPath: "/Applications/LLM Pulse.app",
            previousLoginItemState: .enabled,
            phase: .moved,
            schemaVersion: 99
        ))

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error is AppBundleNameMigrationJournalError)
        }
    }

    func testJournalStoreRejectsOversizedFileBeforeDecoding() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("migration.json")
        let store = JSONAppBundleNameMigrationJournalStore(journalURL: journalURL)
        let value = AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        )
        try store.save(value)
        var oversizedData = try Data(contentsOf: journalURL)
        oversizedData.append(Data(
            repeating: 0x20,
            count: JSONAppBundleNameMigrationJournalStore.maximumFileSizeBytes
                - oversizedData.count
                + 1
        ))
        try oversizedData.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case let .exceedsMaximumSize(maximumBytes) = journalError else {
                return XCTFail("Expected oversized journal error")
            }
            XCTAssertEqual(
                maximumBytes,
                JSONAppBundleNameMigrationJournalStore.maximumFileSizeBytes
            )
        }
    }

    func testJournalStoreRejectsHardLinkedLeafWithoutChangingEitherLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("target.json")
        let journalURL = root.appendingPathComponent("migration.json")
        let value = AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        )
        try JSONAppBundleNameMigrationJournalStore(journalURL: targetURL).save(value)
        let originalData = try Data(contentsOf: targetURL)
        try FileManager.default.linkItem(at: targetURL, to: journalURL)
        let store = JSONAppBundleNameMigrationJournalStore(journalURL: journalURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case .unsafePath = journalError else {
                return XCTFail("Expected unsafe hard-linked journal path")
            }
        }
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
        XCTAssertEqual(try Data(contentsOf: journalURL), originalData)
    }

    func testJournalStoreRejectsMismatchedOwnerEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("migration.json")
        let value = AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        )
        try JSONAppBundleNameMigrationJournalStore(journalURL: journalURL).save(value)
        let store = JSONAppBundleNameMigrationJournalStore(
            journalURL: journalURL,
            currentUserID: geteuid() &+ 1
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case .unsafePath = journalError else {
                return XCTFail("Expected mismatched journal owner to fail closed")
            }
        }
    }

    func testJournalStoreRejectsGroupWritableLeaf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("migration.json")
        let store = JSONAppBundleNameMigrationJournalStore(journalURL: journalURL)
        try store.save(AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o660],
            ofItemAtPath: journalURL.path
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case .unsafePath = journalError else {
                return XCTFail("Expected group-writable journal to fail closed")
            }
        }
    }

    func testJournalStoreRejectsGroupWritableParentBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o770]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770],
            ofItemAtPath: root.path
        )
        let journalURL = root.appendingPathComponent("migration.json")
        let store = JSONAppBundleNameMigrationJournalStore(journalURL: journalURL)

        XCTAssertThrowsError(try store.save(AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        ))) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case .unsafePath = journalError else {
                return XCTFail("Expected group-writable journal directory to fail closed")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testJournalStoreRejectsLeafSymlinkWithoutTouchingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("target.json")
        let journalURL = root.appendingPathComponent("migration.json")
        let originalData = Data("sentinel".utf8)
        try originalData.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: journalURL,
            withDestinationURL: target
        )
        let store = JSONAppBundleNameMigrationJournalStore(journalURL: journalURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case .unsafePath = journalError else {
                return XCTFail("Expected unsafe journal path")
            }
        }
        XCTAssertThrowsError(try store.save(AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        )))
        XCTAssertEqual(try Data(contentsOf: target), originalData)
        XCTAssertNotNil(
            try FileManager.default.destinationOfSymbolicLink(atPath: journalURL.path)
        )
    }

    func testJournalStoreRejectsSymlinkedParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: targetDirectory
        )
        let store = JSONAppBundleNameMigrationJournalStore(
            journalURL: linkedDirectory.appendingPathComponent("migration.json")
        )

        XCTAssertThrowsError(try store.save(AppBundleNameMigrationJournal(
            sourcePath: "/source",
            destinationPath: "/destination",
            previousLoginItemState: .enabled,
            phase: .prepared
        ))) { error in
            guard let journalError = error as? AppBundleNameMigrationJournalError,
                  case .unsafePath = journalError else {
                return XCTFail("Expected unsafe journal directory")
            }
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path).isEmpty
        )
    }

    private func assertSingleOperationFailure(
        _ result: AppBundleNameMigrationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .continueLaunch(issues) = result,
              issues.count == 1,
              case .operationFailed = issues[0] else {
            return XCTFail("Expected one migration operation failure", file: file, line: line)
        }
    }
}

@MainActor
private final class MigrationFixture {
    let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let legacyURL: URL
    let canonicalURL: URL
    let files: FakeMigrationFileManager
    let journal = FakeMigrationJournalStore()
    let login: FakeMigrationLoginItemManager
    let relauncher = FakeMigrationRelauncher()
    let migrator: AppBundleNameMigrator

    init(
        currentName: String = LegacyCompatibility.V1.applicationBundleFilename,
        loginState: LaunchAtLoginRegistrationState,
        legacyExists: Bool = true,
        canonicalExists: Bool = false,
        applicationSupportResolution: LegacyApplicationSupportResolution? = nil,
        preflightIssue: AppBundleNameMigrationIssue? = nil
    ) {
        legacyURL = root.appendingPathComponent(
            LegacyCompatibility.V1.applicationBundleFilename,
            isDirectory: true
        )
        canonicalURL = root.appendingPathComponent(
            PulseBrand.applicationBundleFilename,
            isDirectory: true
        )
        var items: Set<String> = []
        if legacyExists { items.insert(legacyURL.path) }
        if canonicalExists { items.insert(canonicalURL.path) }
        files = FakeMigrationFileManager(
            items: items,
            writableDirectories: [root.path]
        )
        login = FakeMigrationLoginItemManager(state: loginState)
        migrator = AppBundleNameMigrator(
            currentBundleURL: root.appendingPathComponent(currentName, isDirectory: true),
            allowedApplicationDirectories: [root],
            fileManager: files,
            journalStore: journal,
            loginItemManager: login,
            relauncher: relauncher,
            applicationSupportResolution: applicationSupportResolution,
            preflightIssue: preflightIssue
        )
    }
}

private final class FakeMigrationFileManager: AppBundleNameMigrationFileManaging {
    struct Move: Equatable {
        let source: String
        let destination: String
    }

    var items: Set<String>
    var symbolicLinks: Set<String> = []
    var writableDirectories: Set<String>
    var moves: [Move] = []
    var moveError: Error?

    init(items: Set<String>, writableDirectories: Set<String> = []) {
        self.items = items
        self.writableDirectories = writableDirectories
    }

    func itemExists(at url: URL) -> Bool {
        items.contains(url.path) || symbolicLinks.contains(url.path)
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        symbolicLinks.contains(url.path)
    }

    func isWritableDirectory(at url: URL) -> Bool {
        writableDirectories.contains(url.path)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if let moveError { throw moveError }
        guard items.contains(sourceURL.path), !itemExists(at: destinationURL) else {
            throw TestMigrationError.invalidMove
        }
        items.remove(sourceURL.path)
        items.insert(destinationURL.path)
        moves.append(.init(source: sourceURL.path, destination: destinationURL.path))
    }
}

private final class FakeMigrationJournalStore: AppBundleNameMigrationJournalStoring {
    var journal: AppBundleNameMigrationJournal?
    var loadError: Error?
    var saveError: Error?
    var clearError: Error?
    var saveErrorOnCalls: Set<Int> = []
    var loadCallCount = 0
    var saveCallCount = 0
    var clearCallCount = 0

    func load() throws -> AppBundleNameMigrationJournal? {
        loadCallCount += 1
        if let loadError { throw loadError }
        return journal
    }

    func save(_ journal: AppBundleNameMigrationJournal) throws {
        saveCallCount += 1
        if saveErrorOnCalls.contains(saveCallCount) {
            throw TestMigrationError.journalSaveFailed
        }
        if let saveError { throw saveError }
        self.journal = journal
    }

    func clear() throws {
        clearCallCount += 1
        if let clearError { throw clearError }
        journal = nil
    }
}

@MainActor
private final class FakeMigrationLoginItemManager: LaunchAtLoginMigrationManaging {
    var migrationRegistrationState: LaunchAtLoginRegistrationState
    var unregisterStates: [LaunchAtLoginRegistrationState] = []
    var restoreStates: [LaunchAtLoginRegistrationState] = []
    var unregisterError: Error?
    var restoreError: Error?

    init(state: LaunchAtLoginRegistrationState) {
        migrationRegistrationState = state
    }

    func unregisterForBundleNameMigration(
        preserving previousState: LaunchAtLoginRegistrationState
    ) async throws {
        guard previousState.shouldRemainRegistered,
              migrationRegistrationState.shouldRemainRegistered else {
            return
        }
        unregisterStates.append(previousState)
        if let unregisterError { throw unregisterError }
        migrationRegistrationState = .notRegistered
    }

    func restoreAfterBundleNameMigration(
        from previousState: LaunchAtLoginRegistrationState
    ) async throws {
        restoreStates.append(previousState)
        if let restoreError { throw restoreError }
        migrationRegistrationState = previousState
    }
}

@MainActor
private final class FakeMigrationRelauncher: AppBundleNameMigrationRelaunching {
    var urls: [URL] = []
    var error: Error?

    func relaunchApplication(at url: URL) async throws {
        urls.append(url)
        if let error { throw error }
    }
}

private enum TestMigrationError: LocalizedError {
    case invalidMove
    case relaunchFailed
    case restoreFailed
    case journalSaveFailed

    var errorDescription: String? {
        switch self {
        case .invalidMove:
            return "Invalid move"
        case .relaunchFailed:
            return "Relaunch failed"
        case .restoreFailed:
            return "Restore failed"
        case .journalSaveFailed:
            return "Journal save failed"
        }
    }
}
