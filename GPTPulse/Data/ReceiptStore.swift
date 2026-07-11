import Foundation
import SQLite3

actor ReceiptStore {
    private let databaseURL: URL
    private var cachedSnapshot: ReceiptSnapshot?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
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
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parentDirectory.path
        )
        let connection = try SQLiteConnection(
            url: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
        return connection
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
