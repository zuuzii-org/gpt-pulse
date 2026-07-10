import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case text(String)
    case double(Double)
    case integer(Int64)
    case null
}

final class SQLiteConnection {
    private var database: OpaquePointer?

    init(url: URL, flags: Int32) throws {
        var openedDatabase: OpaquePointer?
        let result = url.path.withCString { path in
            sqlite3_open_v2(path, &openedDatabase, flags, nil)
        }

        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open database"
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw DataAdapterError.sqlite(message)
        }

        database = openedDatabase
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw makeError()
            }
        }
    }

    func withStatement<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else {
            throw DataAdapterError.sqlite("Database is closed")
        }

        var statement: OpaquePointer?
        let prepareResult = sql.withCString { sql in
            sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw makeError()
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)
        return try body(statement)
    }

    func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    func int64(at index: Int32, in statement: OpaquePointer) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32, in statement: OpaquePointer) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32

            switch binding {
            case let .text(value):
                result = value.withCString { value in
                    sqlite3_bind_text(
                        statement,
                        index,
                        value,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case let .double(value):
                result = sqlite3_bind_double(statement, index, value)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }

            guard result == SQLITE_OK else {
                throw makeError()
            }
        }
    }

    private func makeError() -> DataAdapterError {
        guard let database else {
            return .sqlite("Database is closed")
        }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}
