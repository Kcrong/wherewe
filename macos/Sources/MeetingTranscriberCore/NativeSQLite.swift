import Foundation
import SQLite3

enum NativeSQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case bind(String)
    case step(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case let .open(message): "Unable to open the native database: \(message)"
        case let .prepare(message): "Unable to prepare a native database query: \(message)"
        case let .bind(message): "Unable to bind a native database value: \(message)"
        case let .step(message): "Unable to execute a native database query: \(message)"
        case let .execute(message): "Unable to update the native database: \(message)"
        }
    }
}

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(values: [String: SQLiteValue]) {
        self.values = values
    }

    func value(_ name: String) -> SQLiteValue { values[name] ?? .null }
    func string(_ name: String) -> String? {
        guard case let .text(value) = value(name) else { return nil }
        return value
    }
    func int(_ name: String) -> Int? {
        guard case let .integer(value) = value(name) else { return nil }
        return Int(value)
    }
    func int64(_ name: String) -> Int64? {
        guard case let .integer(value) = value(name) else { return nil }
        return value
    }
    func double(_ name: String) -> Double? {
        switch value(name) {
        case let .real(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }
    func data(_ name: String) -> Data? {
        guard case let .blob(value) = value(name) else { return nil }
        return value
    }
}

final class NativeDatabase {
    struct RunResult {
        let changes: Int
        let lastInsertID: Int
    }

    let url: URL
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, fileManager: FileManager = .default) throws {
        let validatedURL = try NativeStoragePathPolicy.validateDatabaseURL(
            url,
            fileManager: fileManager
        )
        self.url = validatedURL

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw NativeSQLiteError.open(message)
        }
        do {
            // Tighten the main file before WAL mode can create companion files.
            // SQLite derives new `-wal`/`-shm` permissions from the database, but
            // existing companions from older builds may still be world-readable.
            try secureFiles(fileManager: fileManager)
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute(NativeSchema.tables)
            try migrate()
            try execute(NativeSchema.indexes)
            try secureFiles(fileManager: fileManager)
        } catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
    }

    private func secureFiles(fileManager: FileManager) throws {
        for path in [url.path, url.path + "-wal", url.path + "-shm"]
            where fileManager.fileExists(atPath: path) {
            try NativeStoragePathPolicy.securePrivateFile(
                URL(fileURLWithPath: path),
                fileManager: fileManager
            )
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw NativeSQLiteError.execute("database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw NativeSQLiteError.execute(message)
        }
    }

    func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> RunResult {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NativeSQLiteError.step(errorMessage)
        }
        return RunResult(
            changes: Int(sqlite3_changes(handle)),
            lastInsertID: Int(sqlite3_last_insert_rowid(handle))
        )
    }

    func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var rows: [SQLiteRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var values: [String: SQLiteValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    values[name] = column(statement, index: index)
                }
                rows.append(SQLiteRow(values: values))
            case SQLITE_DONE:
                return rows
            default:
                throw NativeSQLiteError.step(errorMessage)
            }
        }
    }

    func first(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteRow? {
        try query(sql, values).first
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrate() throws {
        try execute("PRAGMA foreign_keys = OFF")
        do {
            try transaction {
                try ensureColumn(table: "meetings", name: "mode", declaration: "TEXT NOT NULL DEFAULT 'meeting'")
                try ensureColumn(table: "glossary", name: "meeting_id", declaration: "INTEGER REFERENCES meetings(id) ON DELETE CASCADE")
                for (name, declaration) in [
                    ("alternatives", "TEXT"),
                    ("confidence", "REAL"),
                    ("transcription_engine", "TEXT"),
                    ("transcription_provider", "TEXT"),
                    ("transcription_model", "TEXT"),
                    ("transcription_mode", "TEXT"),
                    ("result_stage", "TEXT"),
                    ("translation_target", "TEXT"),
                    ("translation_provider", "TEXT"),
                    ("translation_source_hash", "TEXT"),
                    ("translation_source_version", "INTEGER NOT NULL DEFAULT 1"),
                    ("translation_status", "TEXT NOT NULL DEFAULT 'idle'"),
                    ("translation_error", "TEXT"),
                    ("translation_attempts", "INTEGER NOT NULL DEFAULT 0"),
                    ("translation_updated_at", "TEXT"),
                ] {
                    try ensureColumn(table: "transcripts", name: name, declaration: declaration)
                }
                for (name, declaration) in [
                    ("translation_target", "TEXT"),
                    ("translation_provider", "TEXT"),
                    ("translation_source_hash", "TEXT"),
                    ("translation_source_version", "INTEGER NOT NULL DEFAULT 1"),
                    ("translation_status", "TEXT NOT NULL DEFAULT 'idle'"),
                    ("translation_error", "TEXT"),
                    ("translation_attempts", "INTEGER NOT NULL DEFAULT 0"),
                    ("translation_updated_at", "TEXT"),
                ] {
                    try ensureColumn(table: "transcript_segments", name: name, declaration: declaration)
                }

                try ensureForeignKey(
                    table: "transcripts",
                    fromColumn: "meeting_id",
                    parentTable: "meetings",
                    parentColumn: "id",
                    onDelete: "CASCADE"
                )
                try execute("UPDATE meetings SET mode = 'meeting' WHERE mode IS NULL OR mode <> 'meeting'")
                try execute("UPDATE transcripts SET translation_status = 'succeeded' WHERE translation IS NOT NULL AND translation_status = 'idle'")
                try execute("UPDATE transcript_segments SET translation_status = 'succeeded' WHERE translation IS NOT NULL AND translation_status = 'idle'")
                try execute("UPDATE transcripts SET translation_status = 'idle', translation_error = NULL WHERE translation_status = 'pending'")
                try execute("UPDATE transcript_segments SET translation_status = 'idle', translation_error = NULL WHERE translation_status = 'pending'")

                let violations = try query("PRAGMA foreign_key_check")
                guard violations.isEmpty else {
                    throw NativeSQLiteError.execute(
                        "legacy migration found \(violations.count) foreign-key violation(s)"
                    )
                }
            }
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            try? execute("PRAGMA foreign_keys = ON")
            throw error
        }
    }

    private func ensureForeignKey(
        table: String,
        fromColumn: String,
        parentTable: String,
        parentColumn: String,
        onDelete: String
    ) throws {
        let foreignKeys = try query("PRAGMA foreign_key_list(\(quotedIdentifier(table)))")
        let hasExpectedForeignKey = foreignKeys.contains { row in
            guard let referencedTable = row.string("table"),
                  let sourceColumn = row.string("from"),
                  let referencedColumn = row.string("to"),
                  let deleteAction = row.string("on_delete") else {
                return false
            }
            return referencedTable.caseInsensitiveCompare(parentTable) == .orderedSame
                && sourceColumn.caseInsensitiveCompare(fromColumn) == .orderedSame
                && referencedColumn.caseInsensitiveCompare(parentColumn) == .orderedSame
                && deleteAction.caseInsensitiveCompare(onDelete) == .orderedSame
        }
        guard !hasExpectedForeignKey else { return }

        try rebuildTable(
            table,
            addingConstraint: "FOREIGN KEY (\(quotedIdentifier(fromColumn))) "
                + "REFERENCES \(quotedIdentifier(parentTable))(\(quotedIdentifier(parentColumn))) "
                + "ON DELETE \(onDelete)"
        )
    }

    private func rebuildTable(_ table: String, addingConstraint constraint: String) throws {
        let temporaryTable = "__wherewe_migrate_\(table)"
        guard try first(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = ?",
            [.text(temporaryTable)]
        ) == nil else {
            throw NativeSQLiteError.execute("temporary migration table already exists")
        }
        guard let createSQL = try first(
            "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?",
            [.text(table)]
        )?.string("sql"),
            let openingParenthesis = createSQL.firstIndex(of: "("),
            let closingParenthesis = createSQL.lastIndex(of: ")"),
            openingParenthesis < closingParenthesis else {
            throw NativeSQLiteError.execute("unable to read legacy \(table) schema")
        }

        let columns = try query("PRAGMA table_info(\(quotedIdentifier(table)))")
            .compactMap { $0.string("name") }
        guard !columns.isEmpty else {
            throw NativeSQLiteError.execute("legacy \(table) table has no columns")
        }
        let quotedColumns = columns.map(quotedIdentifier).joined(separator: ", ")
        let schemaObjects = try query(
            """
            SELECT sql FROM sqlite_schema
            WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL
            ORDER BY type, name
            """,
            [.text(table)]
        ).compactMap { $0.string("sql") }

        let definition = String(createSQL[openingParenthesis..<closingParenthesis])
        let suffix = String(createSQL[closingParenthesis...])
        try execute(
            "CREATE TABLE \(quotedIdentifier(temporaryTable)) \(definition), \(constraint)\(suffix)"
        )
        try execute(
            "INSERT INTO \(quotedIdentifier(temporaryTable)) (\(quotedColumns)) "
                + "SELECT \(quotedColumns) FROM \(quotedIdentifier(table))"
        )
        try execute("DROP TABLE \(quotedIdentifier(table))")
        try execute(
            "ALTER TABLE \(quotedIdentifier(temporaryTable)) RENAME TO \(quotedIdentifier(table))"
        )
        for sql in schemaObjects {
            try execute(sql)
        }
    }

    private func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func ensureColumn(table: String, name: String, declaration: String) throws {
        let columns = Set(try query("PRAGMA table_info(\(table))").compactMap { $0.string("name") })
        guard !columns.contains(name) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(declaration)")
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw NativeSQLiteError.prepare("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NativeSQLiteError.prepare(errorMessage)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case let .integer(value):
                sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                sqlite3_bind_double(statement, index, value)
            case let .text(value):
                value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
            case let .blob(value):
                value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else { throw NativeSQLiteError.bind(errorMessage) }
        }
    }

    private func column(_ statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            sqlite3_column_text(statement, index).map { .text(String(cString: $0)) } ?? .null
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, index) {
                .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
            } else {
                .blob(Data())
            }
        default:
            .null
        }
    }
}
