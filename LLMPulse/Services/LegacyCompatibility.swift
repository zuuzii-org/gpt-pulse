import Darwin
import Foundation

/// One-release compatibility surface for the previous product identity.
///
/// Keep every old identifier here so normal product code cannot accidentally
/// continue writing new state under the legacy bundle or directory name. This
/// compatibility layer is intentionally copy/move-only: it never deletes a
/// legacy preference domain and never overwrites a destination directory.
enum LegacyCompatibility {
    enum V1 {
        static let displayName = "GPT Pulse"
        static let applicationBundleFilename = "GPT Pulse.app"
        static let bundleIdentifier = "com.zuuzii.GPTPulse"
        static let applicationSupportDirectoryName = "GPT Pulse"
    }

    static let preferencesMigrationMarker =
        "legacyCompatibility.v1.preferencesMigrated"

    static func legacyPreferenceDomain(
        defaults: UserDefaults = .standard
    ) -> [String: Any] {
        defaults.persistentDomain(forName: V1.bundleIdentifier) ?? [:]
    }

    /// Merges the previous persistent domain into the new one exactly once.
    /// Existing new-identity values always win. The marker is written last, so
    /// interruption is safe: a retry fills only keys that are still absent.
    static func migratePreferencesIfNeeded(
        to defaults: UserDefaults,
        legacyDomain: [String: Any]
    ) {
        guard !defaults.bool(forKey: preferencesMigrationMarker) else { return }

        for key in legacyDomain.keys.sorted() {
            guard key != preferencesMigrationMarker,
                  defaults.object(forKey: key) == nil,
                  let value = legacyDomain[key],
                  PropertyListSerialization.propertyList(
                      value,
                      isValidFor: .binary
                  )
            else {
                continue
            }
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: preferencesMigrationMarker)
    }

    static func currentApplicationSupportURL(
        homeDirectory: URL
    ) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/\(PulseBrand.applicationSupportDirectoryName)",
            isDirectory: true
        )
    }

    static func legacyApplicationSupportURL(
        homeDirectory: URL
    ) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/\(V1.applicationSupportDirectoryName)",
            isDirectory: true
        )
    }

    /// Resolves the writable support directory and atomically moves the entire
    /// legacy tree when it is the sole copy. Moving the root keeps receipts,
    /// SQLite WAL/SHM files, plugin events, and migration journals together.
    static func resolveApplicationSupportDirectory(
        homeDirectory: URL,
        currentUserID: uid_t = geteuid()
    ) -> LegacyApplicationSupportResolution {
        let currentURL = currentApplicationSupportURL(homeDirectory: homeDirectory)
            .standardizedFileURL
        let legacyURL = legacyApplicationSupportURL(homeDirectory: homeDirectory)
            .standardizedFileURL
        let currentEntry = fileEntry(at: currentURL)
        let legacyEntry = fileEntry(at: legacyURL)

        switch currentEntry {
        case .missing:
            break
        case let .directory(currentOwner, currentPermissions):
            guard currentOwner == currentUserID,
                  currentPermissions & mode_t(S_IWGRP | S_IWOTH) == 0
            else {
                return LegacyApplicationSupportResolution(
                    directoryURL: currentURL,
                    state: .unsafeCurrentDestination
                )
            }
        case .regularFile, .present, .unsafe:
            return LegacyApplicationSupportResolution(
                directoryURL: currentURL,
                state: .unsafeCurrentDestination
            )
        }

        guard case let .directory(legacyOwner, legacyPermissions) = legacyEntry else {
            if case .missing = legacyEntry {
                return LegacyApplicationSupportResolution(
                    directoryURL: currentURL,
                    state: .current
                )
            }
            return LegacyApplicationSupportResolution(
                directoryURL: currentURL,
                state: .unsafeLegacySource
            )
        }
        guard legacyOwner == currentUserID,
              legacyPermissions & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            return LegacyApplicationSupportResolution(
                directoryURL: currentURL,
                state: .unsafeLegacySource
            )
        }

        switch currentEntry {
        case .missing:
            break
        case .directory:
            // `rmdir` succeeds only while the directory is still empty. If a
            // beta build or another process writes into it concurrently, the
            // operation fails and both trees remain untouched.
            let removalResult: Int32 = currentURL.withUnsafeFileSystemRepresentation { path in
                guard let path else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return rmdir(path)
            }
            guard removalResult == 0 else {
                let preferredURL = preferredConflictDirectory(
                    currentURL: currentURL,
                    legacyURL: legacyURL,
                    currentUserID: currentUserID
                )
                return LegacyApplicationSupportResolution(
                    directoryURL: preferredURL,
                    state: .conflict
                )
            }
        case .regularFile, .present, .unsafe:
            return LegacyApplicationSupportResolution(
                directoryURL: currentURL,
                state: .conflict
            )
        }

        let moveResult: Int32 = legacyURL.withUnsafeFileSystemRepresentation { legacyPath in
            currentURL.withUnsafeFileSystemRepresentation { currentPath in
                guard let legacyPath, let currentPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return renamex_np(
                    legacyPath,
                    currentPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if moveResult == 0 {
            return LegacyApplicationSupportResolution(
                directoryURL: currentURL,
                state: .migrated
            )
        }

        let moveError = errno
        if moveError == EEXIST || moveError == ENOTEMPTY {
            guard isSafeDirectory(at: currentURL, currentUserID: currentUserID) else {
                return LegacyApplicationSupportResolution(
                    directoryURL: currentURL,
                    state: .unsafeCurrentDestination
                )
            }
            return LegacyApplicationSupportResolution(
                directoryURL: preferredConflictDirectory(
                    currentURL: currentURL,
                    legacyURL: legacyURL,
                    currentUserID: currentUserID
                ),
                state: .conflict
            )
        }

        // A safe legacy tree remains usable as a one-release fallback when an
        // atomic rename is unavailable (for example, a transient permission or
        // cross-volume failure). No data is copied partially or deleted.
        return LegacyApplicationSupportResolution(
            directoryURL: legacyURL,
            state: .legacyFallback(errorCode: moveError)
        )
    }

    private enum FileEntry {
        case missing
        case directory(owner: uid_t, permissions: mode_t)
        case regularFile(owner: uid_t, permissions: mode_t, linkCount: nlink_t)
        case present
        case unsafe
    }

    private static func fileEntry(at url: URL) -> FileEntry {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return lstat(path, &status)
        }
        guard result == 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }

        let type = status.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { return .unsafe }
        if type == mode_t(S_IFDIR) {
            return .directory(
                owner: status.st_uid,
                permissions: status.st_mode
            )
        }
        if type == mode_t(S_IFREG) {
            return .regularFile(
                owner: status.st_uid,
                permissions: status.st_mode,
                linkCount: status.st_nlink
            )
        }
        return .present
    }

    private static func preferredConflictDirectory(
        currentURL: URL,
        legacyURL: URL,
        currentUserID: uid_t
    ) -> URL {
        let legacyHasReceipts = hasSafeReceiptState(
            at: legacyURL,
            currentUserID: currentUserID
        )
        let currentHasReceipts = hasSafeReceiptState(
            at: currentURL,
            currentUserID: currentUserID
        )
        return legacyHasReceipts && !currentHasReceipts ? legacyURL : currentURL
    }

    private static func isSafeDirectory(
        at url: URL,
        currentUserID: uid_t
    ) -> Bool {
        guard case let .directory(owner, permissions) = fileEntry(at: url) else {
            return false
        }
        return owner == currentUserID
            && permissions & mode_t(S_IWGRP | S_IWOTH) == 0
    }

    private static func hasSafeReceiptState(
        at directoryURL: URL,
        currentUserID: uid_t
    ) -> Bool {
        guard isSafeDirectory(at: directoryURL, currentUserID: currentUserID) else {
            return false
        }
        return ["receipts.sqlite", "receipts.sqlite-wal", "receipts.sqlite-shm"].contains {
            filename in
            guard case let .regularFile(owner, permissions, linkCount) = fileEntry(
                at: directoryURL.appendingPathComponent(filename)
            ) else {
                return false
            }
            return owner == currentUserID
                && linkCount == 1
                && permissions & mode_t(S_IWGRP | S_IWOTH) == 0
        }
    }
}

struct LegacyApplicationSupportResolution: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case current
        case migrated
        case conflict
        case unsafeCurrentDestination
        case unsafeLegacySource
        case legacyFallback(errorCode: Int32)
    }

    let directoryURL: URL
    let state: State
}
