//
//  DriverLocalStore.swift
//  SmartBus
//
//  Lưu trên máy cho app phụ xe (US03, US10):
//  - local_trips: manifest đã tải (JSON) để làm việc khi mất mạng
//  - outbox: thao tác chờ gửi (bắt đầu chuyến, điểm danh), giữ nguyên sau khi tắt app
//  - rejected_events: thao tác server từ chối, để phụ xe xem lại
//  - cached_trip_lists: danh sách chuyến tải gần nhất (US02 AC4)
//

import Foundation

enum OutboxKind: String {
    case startTrip = "start_trip"
    case attendance = "attendance"
}

struct OutboxItem {
    let seq: Int64
    let tripId: String
    let kind: OutboxKind
    let eventId: String
    /// Học sinh liên quan (kể cả sự kiện QR), dùng khi gộp manifest tải lại.
    let studentId: String?
    let payload: Data
    let createdAtMs: Int64

    var attendance: AttendanceEventPayload? {
        guard kind == .attendance else { return nil }
        return try? JSONDecoder().decode(AttendanceEventPayload.self, from: payload)
    }

    var startedAtMs: Int64? {
        guard kind == .startTrip else { return nil }
        return (try? JSONDecoder().decode(StartTripRequest.self, from: payload))?.startedAtMs
    }
}

struct RejectedEvent {
    let eventId: String
    let tripId: String
    let title: String
    let message: String
    let recordedAtMs: Int64
}

/// Manifest lưu trên máy, kèm lịch sử thao tác cục bộ để thu hồi khi chưa có mạng.
struct LocalManifest: Codable {
    var manifest: ManifestResponse
    /// studentId → các sự kiện hiệu lực tạo trên máy (cũ → mới), kèm trạng thái trước đó.
    var localHistory: [String: [LocalEffectiveEvent]]

    struct LocalEffectiveEvent: Codable {
        let eventId: String
        let previousStatus: ManifestStatus
        let previousEffectiveEventId: String?
    }
}

final class DriverLocalStore {
    static let shared: DriverLocalStore = {
        do {
            return try DriverLocalStore()
        } catch {
            fatalError("Không mở được cơ sở dữ liệu trên máy: \(error)")
        }
    }()

    private let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileName: String = "smartbus-driver.sqlite") throws {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        db = try SQLiteDatabase(url: folder.appendingPathComponent(fileName))
        try db.execute("""
        CREATE TABLE IF NOT EXISTS local_trips (
            trip_id TEXT PRIMARY KEY,
            manifest_json BLOB NOT NULL,
            saved_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS outbox (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            event_id TEXT NOT NULL UNIQUE,
            student_id TEXT,
            payload_json BLOB NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_outbox_trip ON outbox (trip_id, seq);
        CREATE TABLE IF NOT EXISTS rejected_events (
            event_id TEXT PRIMARY KEY,
            trip_id TEXT NOT NULL,
            title TEXT NOT NULL,
            message TEXT NOT NULL,
            recorded_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cached_trip_lists (
            date_key TEXT PRIMARY KEY,
            trips_json BLOB NOT NULL,
            saved_at_ms INTEGER NOT NULL
        );
        """)
    }

    // MARK: - Manifest

    func saveManifest(_ local: LocalManifest) throws {
        let data = try encoder.encode(local)
        try db.run(
            "INSERT OR REPLACE INTO local_trips (trip_id, manifest_json, saved_at_ms) VALUES (?, ?, ?)",
            [.text(local.manifest.trip.id), .blob(data), .int(Date().milliseconds)]
        )
    }

    func loadManifest(tripId: String) -> LocalManifest? {
        guard let row = try? db.query("SELECT manifest_json FROM local_trips WHERE trip_id = ?", [.text(tripId)]).first,
              let data = row["manifest_json"]?.data else { return nil }
        return try? decoder.decode(LocalManifest.self, from: data)
    }

    func deleteManifest(tripId: String) {
        try? db.run("DELETE FROM local_trips WHERE trip_id = ?", [.text(tripId)])
    }

    // MARK: - Outbox

    /// Ghi thao tác vào outbox cùng lúc với manifest mới (một transaction, US10 AC1).
    func enqueue(tripId: String, kind: OutboxKind, eventId: String, studentId: String?, payload: Data, manifest: LocalManifest) throws {
        let manifestData = try encoder.encode(manifest)
        try db.transaction {
            try db.run(
                "INSERT INTO outbox (trip_id, kind, event_id, student_id, payload_json, created_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(tripId), .text(kind.rawValue), .text(eventId), studentId.map { .text($0) } ?? .null, .blob(payload), .int(Date().milliseconds)]
            )
            try db.run(
                "INSERT OR REPLACE INTO local_trips (trip_id, manifest_json, saved_at_ms) VALUES (?, ?, ?)",
                [.text(tripId), .blob(manifestData), .int(Date().milliseconds)]
            )
        }
    }

    func outbox(tripId: String) -> [OutboxItem] {
        let rows = (try? db.query(
            "SELECT seq, trip_id, kind, event_id, student_id, payload_json, created_at_ms FROM outbox WHERE trip_id = ? ORDER BY seq",
            [.text(tripId)]
        )) ?? []
        return rows.compactMap(makeOutboxItem)
    }

    func pendingCount(tripId: String) -> Int {
        let row = try? db.query("SELECT COUNT(*) AS total FROM outbox WHERE trip_id = ?", [.text(tripId)]).first
        return Int(row?["total"]?.int64 ?? 0)
    }

    func totalPendingCount() -> Int {
        let row = try? db.query("SELECT COUNT(*) AS total FROM outbox").first
        return Int(row?["total"]?.int64 ?? 0)
    }

    func tripIdsWithPendingOutbox() -> [String] {
        let rows = (try? db.query("SELECT DISTINCT trip_id FROM outbox")) ?? []
        return rows.compactMap { $0["trip_id"]?.string }
    }

    func removeOutbox(eventIds: [String]) {
        for eventId in eventIds {
            try? db.run("DELETE FROM outbox WHERE event_id = ?", [.text(eventId)])
        }
    }

    // MARK: - Rejected

    func addRejected(_ event: RejectedEvent) {
        try? db.run(
            "INSERT OR REPLACE INTO rejected_events (event_id, trip_id, title, message, recorded_at_ms) VALUES (?, ?, ?, ?, ?)",
            [.text(event.eventId), .text(event.tripId), .text(event.title), .text(event.message), .int(event.recordedAtMs)]
        )
    }

    func rejectedEvents(tripId: String) -> [RejectedEvent] {
        let rows = (try? db.query(
            "SELECT event_id, trip_id, title, message, recorded_at_ms FROM rejected_events WHERE trip_id = ? ORDER BY recorded_at_ms DESC",
            [.text(tripId)]
        )) ?? []
        return rows.compactMap { row in
            guard let eventId = row["event_id"]?.string, let tripId = row["trip_id"]?.string,
                  let title = row["title"]?.string, let message = row["message"]?.string,
                  let recorded = row["recorded_at_ms"]?.int64 else { return nil }
            return RejectedEvent(eventId: eventId, tripId: tripId, title: title, message: message, recordedAtMs: recorded)
        }
    }

    func dismissRejected(eventId: String) {
        try? db.run("DELETE FROM rejected_events WHERE event_id = ?", [.text(eventId)])
    }

    // MARK: - Trip list cache

    func saveTripList(_ trips: [DriverTrip], dateKey: String) {
        guard let data = try? encoder.encode(trips) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO cached_trip_lists (date_key, trips_json, saved_at_ms) VALUES (?, ?, ?)",
            [.text(dateKey), .blob(data), .int(Date().milliseconds)]
        )
    }

    func cachedTripList(dateKey: String) -> (trips: [DriverTrip], savedAtMs: Int64)? {
        guard let row = try? db.query("SELECT trips_json, saved_at_ms FROM cached_trip_lists WHERE date_key = ?", [.text(dateKey)]).first,
              let data = row["trips_json"]?.data,
              let trips = try? decoder.decode([DriverTrip].self, from: data),
              let saved = row["saved_at_ms"]?.int64 else { return nil }
        return (trips, saved)
    }

    /// Xóa dữ liệu chuyến khi đăng xuất hợp lệ (US16 AC3). Không gọi khi còn outbox.
    func clearAllTripData() {
        try? db.execute("DELETE FROM local_trips; DELETE FROM rejected_events; DELETE FROM cached_trip_lists;")
    }

    // MARK: - Private

    private func makeOutboxItem(_ row: SQLiteRow) -> OutboxItem? {
        guard let seq = row["seq"]?.int64, let tripId = row["trip_id"]?.string,
              let kindRaw = row["kind"]?.string, let kind = OutboxKind(rawValue: kindRaw),
              let eventId = row["event_id"]?.string, let payload = row["payload_json"]?.data,
              let created = row["created_at_ms"]?.int64 else { return nil }
        return OutboxItem(seq: seq, tripId: tripId, kind: kind, eventId: eventId,
                          studentId: row["student_id"]?.string, payload: payload, createdAtMs: created)
    }
}

/// Khóa ngày theo giờ Việt Nam ("YYYY-MM-DD"), trùng cách server tính "hôm nay".
enum OperatingDate {
    static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
