import Foundation
import CSQLite

/// Only this actor owns the SQLite connection. Every final result is committed before the UI reports it saved.
public actor MeetingRepository {
    private var database: OpaquePointer?
    public let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("meetings.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw StorageError.operation("无法打开本地数据库")
        }
        sqlite3_busy_timeout(database, 5_000)
        for sql in [
            "PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL",
            "CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, saved REAL NOT NULL, payload BLOB NOT NULL)",
            "CREATE TABLE IF NOT EXISTS originals (meeting_id TEXT NOT NULL, segment_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(meeting_id, segment_id))",
            "PRAGMA user_version=1"
        ] {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(database); database = nil
                throw StorageError.operation("无法初始化本地数据库")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit { if let database { sqlite3_close(database) } }

    public func save(_ meeting: Meeting) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            // Separate immutable ledger enforces original text protection even if caller data is malformed.
            for segment in meeting.allTranscriptSegments {
                let bytes = try encoder.encode(segment)
                if let stored = try original(meetingID: meeting.id.uuidString, segmentID: segment.id) {
                    guard stored == bytes else { throw MeetingError.conflictingResult }
                } else {
                    let statement = try prepare("INSERT INTO originals VALUES (?, ?, ?)")
                    defer { sqlite3_finalize(statement) }
                    bind(meeting.id.uuidString, to: statement, at: 1); bind(segment.id, to: statement, at: 2)
                    bind(bytes, to: statement, at: 3)
                    try done(statement)
                }
            }
            let statement = try prepare("INSERT INTO meetings VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET saved=excluded.saved, payload=excluded.payload")
            defer { sqlite3_finalize(statement) }
            bind(meeting.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, meeting.lastSavedAt.timeIntervalSince1970)
            bind(try encoder.encode(meeting), to: statement, at: 3)
            try done(statement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func loadAll(recover: Bool = false) throws -> [Meeting] {
        let statement = try prepare("SELECT payload FROM meetings ORDER BY saved DESC")
        defer { sqlite3_finalize(statement) }
        var meetings: [Meeting] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            var meeting = try decoder.decode(Meeting.self, from: data(statement, column: 0))
            if recover { meeting.recoverInterrupted() }
            meetings.append(meeting)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure() }
        if recover { for meeting in meetings { try save(meeting) } }
        return meetings
    }

    public func delete(_ id: UUID) throws {
        // Audio deletion first: a failure keeps the visible meeting available for retry.
        let audio = directory.appendingPathComponent("Audio/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["originals", "meetings"] {
                let statement = try prepare("DELETE FROM \(table) WHERE \(table == "meetings" ? "id" : "meeting_id") = ?")
                defer { sqlite3_finalize(statement) }
                bind(id.uuidString, to: statement, at: 1); try done(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func original(meetingID: String, segmentID: String) throws -> Data? {
        let statement = try prepare("SELECT payload FROM originals WHERE meeting_id=? AND segment_id=?")
        defer { sqlite3_finalize(statement) }
        bind(meetingID, to: statement, at: 1); bind(segmentID, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return data(statement, column: 0) }
        guard result == SQLITE_DONE else { throw failure() }
        return nil
    }
    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind(_ bytes: Data, to statement: OpaquePointer, at index: Int32) {
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> StorageError {
        // Avoid storing full SQL, transcripts, paths or credentials in diagnostics.
        .operation("本地存储操作失败（SQLite \(sqlite3_errcode(database))）；请检查磁盘空间与权限")
    }
}

public enum StorageError: LocalizedError {
    case operation(String)
    public var errorDescription: String? { if case let .operation(message) = self { return message }; return nil }
}
