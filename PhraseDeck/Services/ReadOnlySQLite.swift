import Foundation
import SQLite3

final class ReadOnlySQLite {
    private var db: OpaquePointer?

    init?(url: URL) {
        var db: OpaquePointer?
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        let uri = components?.string ?? "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 2_000)
        sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)
        self.db = db
    }

    deinit {
        sqlite3_close(db)
    }

    func string(sql: String, params: [String] = []) -> String? {
        column(sql: sql, params: params, index: 0)
    }

    func column(sql: String, params: [String], index: Int) -> String? {
        let row = rows(sql: sql, params: params).first
        guard let row, index < row.count else { return nil }
        return row[index]
    }

    func rows(sql: String, params: [String] = []) -> [[String]] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), param, -1, sqliteTransient)
        }
        var result: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [String] = []
            for i in 0..<count {
                row.append(Self.columnString(stmt, i) ?? "")
            }
            result.append(row)
        }
        return result
    }

    private static func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        let type = sqlite3_column_type(stmt, index)
        if type == SQLITE_NULL { return nil }
        if type == SQLITE_BLOB {
            let length = Int(sqlite3_column_bytes(stmt, index))
            guard length > 0, let bytes = sqlite3_column_blob(stmt, index) else { return "" }
            return String(data: Data(bytes: bytes, count: length), encoding: .utf8)
        }
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
