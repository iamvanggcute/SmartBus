//
//  SQLiteDatabase.swift
//  SmartBus
//
//  Lớp bọc mỏng quanh SQLite3 (có sẵn trong iOS, không cần thư viện ngoài).
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    var int64: Int64? { if case .int(let value) = self { return value }; return nil }
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var data: Data? {
        switch self {
        case .blob(let value): return value
        case .text(let value): return Data(value.utf8)
        default: return nil
        }
    }
}

typealias SQLiteRow = [String: SQLiteValue]

final class SQLiteDatabase {
    enum DatabaseError: LocalizedError {
        case open(String), prepare(String), step(String)

        var errorDescription: String? {
            switch self {
            case .open(let message), .prepare(let message), .step(let message):
                return "Lỗi bộ nhớ máy: \(message)"
            }
        }
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "SmartBus.SQLiteDatabase")

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "không mở được"
            throw DatabaseError.open(message)
        }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = FULL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Chạy nhiều câu lệnh không tham số (tạo bảng…).
    func execute(_ sql: String) throws {
        try queue.sync {
            var errorPointer: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
                let message = errorPointer.map { String(cString: $0) } ?? "exec"
                sqlite3_free(errorPointer)
                throw DatabaseError.step(message)
            }
        }
    }

    /// INSERT / UPDATE / DELETE có tham số `?`.
    func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        try queue.sync {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.step(lastError)
            }
        }
    }

    func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try queue.sync {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            var rows: [SQLiteRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw DatabaseError.step(lastError) }
                var row: SQLiteRow = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    row[name] = columnValue(statement, index)
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// Chạy nhiều lệnh trong một transaction (ghi manifest, outbox…).
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Private

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(lastError)
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func columnValue(_ statement: OpaquePointer?, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_blob(statement, index), count > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }
}
