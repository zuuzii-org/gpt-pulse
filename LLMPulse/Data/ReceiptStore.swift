import Darwin
import Foundation
import SQLite3

actor ReceiptStore {
    private let databaseURL: URL
    private let currentUserID: uid_t
    private var cachedSnapshot: ReceiptSnapshot?

    init(databaseURL: URL, currentUserID: uid_t = geteuid()) {
        self.databaseURL = databaseURL
        self.currentUserID = currentUserID
    }

    func snapshot(now: Date = .now) throws -> ReceiptSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        let connection = try openConnection()
        try ensureSchema(in: connection)
        let baselineAt = try readOrCreateBaseline(now: now, connection: connection)

        var viewedTaskIDs: Set<String> = []
        try connection.withStatement("SELECT task_id FROM receipts") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let taskId = connection.string(at: 0, in: statement) {
                    viewedTaskIDs.insert(taskId)
                }
            }
        }

        let snapshot = ReceiptSnapshot(
            baselineAt: baselineAt,
            viewedTaskIDs: viewedTaskIDs
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    func markViewed(_ task: PulseTask, at date: Date = .now) throws {
        try markViewed([task], at: date)
    }

    func markViewed(_ tasks: [PulseTask], at date: Date = .now) throws {
        let tasks = uniqueTasks(tasks)
        guard !tasks.isEmpty else { return }
        let currentSnapshot = try snapshot(now: date)
        do {
            let connection = try openConnection()
            try ensureSchema(in: connection)
            try transaction(in: connection) {
                for task in tasks {
                    try connection.execute(
                        """
                        INSERT INTO receipts(task_id, thread_id, turn_id, viewed_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(task_id) DO UPDATE SET
                            thread_id = excluded.thread_id,
                            turn_id = excluded.turn_id,
                            viewed_at = excluded.viewed_at
                        """,
                        bindings: [
                            .text(task.id),
                            .text(task.threadId),
                            task.turnId.map(SQLiteValue.text) ?? .null,
                            .double(date.timeIntervalSince1970),
                        ]
                    )
                }
            }
            var viewedTaskIDs = currentSnapshot.viewedTaskIDs
            viewedTaskIDs.formUnion(tasks.map(\.id))
            cachedSnapshot = ReceiptSnapshot(
                baselineAt: currentSnapshot.baselineAt,
                viewedTaskIDs: viewedTaskIDs
            )
        } catch {
            cachedSnapshot = nil
            throw error
        }
    }

    func unmarkViewed(_ task: PulseTask) throws {
        try unmarkViewed([task])
    }

    func unmarkViewed(_ tasks: [PulseTask]) throws {
        let tasks = uniqueTasks(tasks)
        guard !tasks.isEmpty else { return }
        let currentSnapshot = try snapshot()
        do {
            let connection = try openConnection()
            try ensureSchema(in: connection)
            try transaction(in: connection) {
                for task in tasks {
                    try connection.execute(
                        """
                        DELETE FROM receipts
                        WHERE task_id = ?
                        """,
                        bindings: [
                            .text(task.id),
                        ]
                    )
                }
            }
            var viewedTaskIDs = currentSnapshot.viewedTaskIDs
            viewedTaskIDs.subtract(tasks.map(\.id))
            cachedSnapshot = ReceiptSnapshot(
                baselineAt: currentSnapshot.baselineAt,
                viewedTaskIDs: viewedTaskIDs
            )
        } catch {
            cachedSnapshot = nil
            throw error
        }
    }

    private func openConnection() throws -> SQLiteConnection {
        let parentDirectory = databaseURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
        }
        try validateOwnerOnlyDirectory(parentDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parentDirectory.path
        )
        try validateOwnerOnlyDirectory(parentDirectory)
        // `SQLITE_OPEN_NOFOLLOW` also rejects a system ancestor symlink such
        // as /var -> /private/var. Validate the final parent itself first,
        // then canonicalize only that parent; never resolve the database leaf.
        let canonicalDatabaseURL = try canonicalDirectoryURL(parentDirectory)
            .appendingPathComponent(databaseURL.lastPathComponent)
        try receiptSidecarURLs(for: canonicalDatabaseURL)
            .forEach(validateSafeFileIfPresent)
        let connection = try SQLiteConnection(
            url: canonicalDatabaseURL,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_CREATE
                | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_NOFOLLOW
        )
        try validateSafeFileIfPresent(canonicalDatabaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: canonicalDatabaseURL.path
        )
        return connection
    }

    private func receiptSidecarURLs(for databaseURL: URL) -> [URL] {
        ["", "-wal", "-shm", "-journal"].map {
            URL(fileURLWithPath: databaseURL.path + $0)
        }
    }

    private func canonicalDirectoryURL(_ url: URL) throws -> URL {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let canonicalPath: String? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            return resolvedPath.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress,
                      realpath(path, baseAddress) != nil else {
                    return nil
                }
                return String(cString: baseAddress)
            }
        }
        guard let canonicalPath else {
            throw DataAdapterError.sqlite("Receipt directory canonicalization failed")
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private func validateOwnerOnlyDirectory(_ url: URL) throws {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        guard result == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == currentUserID,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw DataAdapterError.sqlite("Receipt directory failed safety validation")
        }
    }

    private func validateSafeFileIfPresent(_ url: URL) throws {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else {
                throw DataAdapterError.sqlite("Receipt file safety validation failed")
            }
            return
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == currentUserID,
              status.st_nlink == 1,
              status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw DataAdapterError.sqlite("Receipt file failed safety validation")
        }
    }

    private func ensureSchema(in connection: SQLiteConnection) throws {
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS receipts (
                task_id TEXT PRIMARY KEY NOT NULL,
                thread_id TEXT NOT NULL,
                turn_id TEXT,
                viewed_at REAL NOT NULL
            )
            """
        )
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS receipts_thread_id ON receipts(thread_id)"
        )
    }

    private func transaction(
        in connection: SQLiteConnection,
        _ body: () throws -> Void
    ) throws {
        try connection.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func uniqueTasks(_ tasks: [PulseTask]) -> [PulseTask] {
        var taskIDs: Set<String> = []
        return tasks.filter { taskIDs.insert($0.id).inserted }
    }

    private func readOrCreateBaseline(
        now: Date,
        connection: SQLiteConnection
    ) throws -> Date {
        try connection.execute(
            "INSERT OR IGNORE INTO metadata(key, value) VALUES ('baseline_at', ?)",
            bindings: [.text(String(now.timeIntervalSince1970))]
        )

        var value: String?
        try connection.withStatement(
            "SELECT value FROM metadata WHERE key = 'baseline_at' LIMIT 1"
        ) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                value = connection.string(at: 0, in: statement)
            }
        }

        guard let value, let timestamp = Double(value) else {
            throw DataAdapterError.sqlite("Receipt baseline is invalid")
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}
