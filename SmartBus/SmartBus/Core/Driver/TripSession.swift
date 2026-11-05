//
//  TripSession.swift
//  SmartBus
//
//  Một chuyến đang mở trên máy phụ xe:
//  - đối chiếu QR với manifest trên máy, kể cả khi mất mạng (US05, US06)
//  - ghi outbox trước, cập nhật giao diện sau, gọi mạng cuối cùng (05 §9.1)
//  - đồng bộ tuần tự, tối đa 100 sự kiện/lô, backoff 2→60 giây (US11)
//  - gộp manifest server với thao tác còn trong outbox (05 §6.4)
//

import Foundation
import CoreLocation

extension Notification.Name {
    /// `object` là `TripSession` vừa thay đổi (manifest, trạng thái đồng bộ…).
    static let tripSessionDidChange = Notification.Name("SmartBus.tripSessionDidChange")
    static let tripWasReassigned = Notification.Name("SmartBus.tripWasReassigned")
}

enum ScanMode {
    case board, alight

    var title: String { self == .board ? "Đón" : "Trả" }
    var hint: String { self == .board ? "Đón: ghi lên xe" : "Trả: ghi xuống xe" }
}

/// Kết quả xử lý một lần quét QR học sinh (phía app, trước khi gửi server).
enum ScanOutcome {
    case accepted(ManifestItem, AttendanceEventType)
    case duplicate(ManifestItem)
    case needsAbsentConfirmation(ManifestItem, payload: String)
    case needsUnexpectedConfirmation(studentCode: String, payload: String)
    case wrongState(ManifestItem, title: String, message: String)
    case notInManifest(studentCode: String)
    case invalidFormat
    case outdatedCard(ManifestItem)
    case invalidSignature(ManifestItem)
    case tripNotActive
}

enum SyncState: Equatable {
    case idle
    case syncing
    case offline
    case retrying(seconds: Int)
    /// Server từ chối, cần người xử lý (ví dụ bắt đầu chuyến bị từ chối khi offline).
    case blocked(String)
}

enum TripSessionError: LocalizedError {
    case tooEarly
    case nothingToRevoke
    case tripNotActive

    var errorDescription: String? {
        switch self {
        case .tooEarly: return "Chỉ được bắt đầu sớm tối đa 60 phút so với giờ dự kiến"
        case .nothingToRevoke: return "Học sinh chưa có lần ghi nhận nào để thu hồi"
        case .tripNotActive: return "Chuyến chưa bắt đầu"
        }
    }
}

/// QR thẻ học sinh: `SB_STU|<mã>|<version>|<chữ ký 64 hex>` (utils/qr.js).
struct StudentQR {
    let studentCode: String
    let version: Int
    let signature: String

    init?(payload: String) {
        let parts = payload.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "SB_STU" else { return nil }
        let code = parts[1]
        guard (1...30).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let version = Int(parts[2]), version >= 1,
              parts[3].count == 64, parts[3].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        studentCode = code
        self.version = version
        signature = parts[3]
    }
}

@MainActor
final class TripSession {
    let tripId: String
    private(set) var local: LocalManifest
    private(set) var syncState: SyncState = .idle

    private let store: DriverLocalStore
    private let service: DriverService
    private var isFlushing = false
    private var retryDelay: TimeInterval = 2
    private var retryTask: Task<Void, Never>?
    private var recentScans: [String: Date] = [:]
    private var networkObserver: NSObjectProtocol?

    init(local: LocalManifest, store: DriverLocalStore = .shared, service: DriverService = DriverService()) {
        self.tripId = local.manifest.trip.id
        self.local = local
        self.store = store
        self.service = service
        networkObserver = NotificationCenter.default.addObserver(forName: .networkStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NetworkMonitor.shared.isOnline { self.flush() } else if self.pendingCount > 0 { self.setSync(.offline) }
            }
        }
    }

    deinit {
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        retryTask?.cancel()
    }

    // MARK: - Trạng thái đọc

    var manifest: ManifestResponse { local.manifest }
    var trip: ManifestTrip { local.manifest.trip }
    var items: [ManifestItem] { local.manifest.manifestItems }
    var isActive: Bool { trip.status == .active }
    var pendingCount: Int { store.pendingCount(tripId: tripId) }
    var rejectedEvents: [RejectedEvent] { store.rejectedEvents(tripId: tripId) }

    /// Đếm theo trạng thái trên máy (đã gồm thao tác chưa đồng bộ).
    var counts: StudentCounts {
        var counts = StudentCounts(total: items.count, expected: 0, absent: 0, boarded: 0, alighted: 0)
        for item in items {
            switch item.status {
            case .expected: counts.expected += 1
            case .absent: counts.absent += 1
            case .boarded: counts.boarded += 1
            case .alighted: counts.alighted += 1
            }
        }
        return counts
    }

    var boardedItems: [ManifestItem] { items.filter { $0.status == .boarded } }

    /// Điểm tiếp theo theo tiến độ server trả về (`progress == "next"`).
    var nextStop: RouteStop? {
        manifest.route.stops.first { $0.progress == "next" }
    }

    func stopName(for item: ManifestItem) -> String? {
        guard let stopId = item.stopId else { return nil }
        return manifest.route.stops.first { $0.id == stopId }?.name
    }

    // MARK: - Tải manifest

    /// Tải manifest mới từ server và gộp với thao tác còn trong outbox.
    func refreshFromServer() async {
        guard let server = try? await service.manifest(tripId: tripId) else { return }
        apply(server: server)
    }

    func apply(server: ManifestResponse) {
        local = Self.merge(server: server, previous: local, pending: store.outbox(tripId: tripId))
        try? store.saveManifest(local)
        notify()
    }

    static func merge(server: ManifestResponse, previous: LocalManifest?, pending: [OutboxItem]) -> LocalManifest {
        var result = LocalManifest(manifest: server, localHistory: [:])
        guard let previous else { return result }

        // Lệnh bắt đầu chuyến còn trong outbox: giữ trạng thái "đang chạy" trên máy.
        if pending.contains(where: { $0.kind == .startTrip }), server.trip.status == .scheduled {
            result.manifest.trip.status = .active
            result.manifest.trip.actualStartTimeMs = previous.manifest.trip.actualStartTimeMs
        }
        // Server là chuẩn, trừ học sinh còn thao tác chưa gửi (05 §6.4).
        let pendingStudents = Set(pending.compactMap(\.studentId))
        for index in result.manifest.manifestItems.indices {
            let studentId = result.manifest.manifestItems[index].studentId
            guard pendingStudents.contains(studentId),
                  let old = previous.manifest.manifestItems.first(where: { $0.studentId == studentId }) else { continue }
            result.manifest.manifestItems[index].status = old.status
            result.manifest.manifestItems[index].lastEffectiveEventId = old.lastEffectiveEventId
            result.localHistory[studentId] = previous.localHistory[studentId]
        }
        return result
    }

    // MARK: - Bắt đầu chuyến (US04)

    /// Có mạng: gửi ngay để báo lỗi tức thì. Mất mạng: ghi outbox, cho điểm danh luôn.
    func startTrip() async throws {
        guard trip.status == .scheduled else { return }
        let now = Date()
        let earliest = Date(milliseconds: trip.scheduledStartTimeMs).addingTimeInterval(-60 * 60)
        guard now >= earliest else { throw TripSessionError.tooEarly }

        if NetworkMonitor.shared.isOnline {
            do {
                let response = try await service.startTrip(tripId: tripId, startedAtMs: now.milliseconds)
                local.manifest.trip.status = .active
                local.manifest.trip.actualStartTimeMs = response.actualStartTimeMs ?? now.milliseconds
                try? store.saveManifest(local)
                notify()
                await refreshFromServer()
                return
            } catch let error as APIError {
                guard case .network = error else { throw error }
                // Rớt mạng giữa chừng: chuyển sang ghi outbox.
            }
        }

        var next = local
        next.manifest.trip.status = .active
        next.manifest.trip.actualStartTimeMs = now.milliseconds
        let payload = try JSONEncoder().encode(StartTripRequest(startedAtMs: now.milliseconds))
        try store.enqueue(tripId: tripId, kind: .startTrip, eventId: UUID().uuidString.lowercased(),
                          studentId: nil, payload: payload, manifest: next)
        local = next
        notify()
        flush()
    }

    // MARK: - Quét QR (US05, US06, US08)

    func handleScan(payload: String, mode: ScanMode) -> ScanOutcome {
        guard isActive else { return .tripNotActive }
        guard let qr = StudentQR(payload: payload) else { return .invalidFormat }

        guard let item = items.first(where: { $0.studentCode == qr.studentCode }) else {
            return mode == .board
                ? .needsUnexpectedConfirmation(studentCode: qr.studentCode, payload: payload)
                : .notInManifest(studentCode: qr.studentCode)
        }
        if let last = recentScans[qr.studentCode], Date().timeIntervalSince(last) < 15 {
            return .duplicate(item)
        }
        // So với chữ ký và phiên bản thẻ đã tải về máy (05 §9.1, US06 AC3).
        guard qr.version == item.qrVersion else { return .outdatedCard(item) }
        guard qr.signature == item.qrHmacHash.lowercased() else { return .invalidSignature(item) }

        switch (mode, item.status) {
        case (.board, .expected):
            return recordScan(item: item, type: .boarded, payload: payload)
        case (.board, .absent):
            return .needsAbsentConfirmation(item, payload: payload)
        case (.board, .boarded):
            return .wrongState(item, title: "Em đang trên xe", message: "Đã ghi lên xe trước đó. Không ghi thêm.")
        case (.board, .alighted):
            return .wrongState(item, title: "Em đã xuống xe", message: "Không ghi lên xe lại trong cùng chuyến.")
        case (.alight, .boarded):
            return recordScan(item: item, type: .alighted, payload: payload)
        case (.alight, .expected), (.alight, .absent):
            return .wrongState(item, title: "Em chưa lên xe", message: "Đang ở chế độ Trả. Không ghi xuống xe.")
        case (.alight, .alighted):
            return .wrongState(item, title: "Em đã xuống xe", message: "Đã ghi xuống xe trước đó. Không ghi thêm.")
        }
    }

    /// Phụ xe xác nhận cho em đã báo nghỉ lên xe (US06 AC5).
    func confirmAbsentBoarding(item: ManifestItem, payload: String) -> ScanOutcome {
        recordScan(item: item, type: .boarded, payload: payload)
    }

    /// Phụ xe xác nhận "Vẫn cho lên xe" với em ngoài danh sách (US06 AC4).
    /// Server sẽ thêm em vào manifest và báo giám sát viên khi đồng bộ.
    func confirmUnexpectedBoarding(payload: String) throws {
        try record(type: .boarded, method: .qr, item: nil, qrPayload: payload, targetEventId: nil)
    }

    private func recordScan(item: ManifestItem, type: AttendanceEventType, payload: String) -> ScanOutcome {
        do {
            try record(type: type, method: .qr, item: item, qrPayload: payload, targetEventId: nil)
            recentScans[item.studentCode] = Date()
            let updated = items.first { $0.studentId == item.studentId } ?? item
            return .accepted(updated, type)
        } catch {
            return .wrongState(item, title: "Không lưu được", message: error.localizedDescription)
        }
    }

    // MARK: - Điểm danh tay & thu hồi (US08 AC5, US09)

    /// Hành động tay phù hợp với trạng thái hiện tại, `nil` nếu không còn gì để ghi.
    func manualAction(for item: ManifestItem) -> AttendanceEventType? {
        switch item.status {
        case .expected, .absent: return .boarded
        case .boarded: return .alighted
        case .alighted: return nil
        }
    }

    func recordManual(item: ManifestItem, type: AttendanceEventType) throws {
        guard isActive else { throw TripSessionError.tripNotActive }
        try record(type: type, method: .manual, item: item, qrPayload: nil, targetEventId: nil)
    }

    func canRevoke(_ item: ManifestItem) -> Bool {
        isActive && item.lastEffectiveEventId != nil
    }

    func revokeLatest(item: ManifestItem) throws {
        guard isActive else { throw TripSessionError.tripNotActive }
        guard let target = item.lastEffectiveEventId else { throw TripSessionError.nothingToRevoke }
        try record(type: .revoked, method: .manual, item: item, qrPayload: nil, targetEventId: target)
    }

    private func record(type: AttendanceEventType, method: ScanMethod, item: ManifestItem?, qrPayload: String?, targetEventId: String?) throws {
        let eventId = UUID().uuidString.lowercased()
        let location = LocationTracker.shared.recentLocation
        let event = AttendanceEventPayload(
            eventId: eventId,
            eventType: type,
            scanMethod: method,
            qrPayload: method == .qr ? qrPayload : nil,
            // QR: server xác định học sinh từ mã; tay/thu hồi: gửi student_id (04 §10.4).
            studentId: method == .manual ? item?.studentId : nil,
            targetEventId: targetEventId,
            recordedAtMs: Date().milliseconds,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            nearestStopId: LocationTracker.shared.nearestStopId(in: manifest.route.stops)
        )

        var next = local
        if let item, let index = next.manifest.manifestItems.firstIndex(where: { $0.studentId == item.studentId }) {
            var current = next.manifest.manifestItems[index]
            var history = next.localHistory[item.studentId] ?? []
            if type == .revoked {
                if let last = history.last, last.eventId == targetEventId {
                    history.removeLast()
                    current.status = last.previousStatus
                    current.lastEffectiveEventId = last.previousEffectiveEventId
                } else {
                    // Thu hồi sự kiện đã có trên server: tạm suy ra, tải lại manifest sẽ chỉnh đúng.
                    current.status = current.status == .alighted ? .boarded : .expected
                    current.lastEffectiveEventId = nil
                }
            } else {
                history.append(.init(eventId: eventId, previousStatus: current.status, previousEffectiveEventId: current.lastEffectiveEventId))
                current.status = type == .boarded ? .boarded : .alighted
                current.lastEffectiveEventId = eventId
            }
            next.manifest.manifestItems[index] = current
            next.localHistory[item.studentId] = history
        }

        try store.enqueue(tripId: tripId, kind: .attendance, eventId: eventId, studentId: item?.studentId,
                          payload: try JSONEncoder().encode(event), manifest: next)
        local = next
        notify()
        flush()
    }

    // MARK: - Đồng bộ (US11)

    func flush() {
        retryTask?.cancel()
        retryTask = nil
        guard !isFlushing else { return }
        Task { await runFlush() }
    }

    private func runFlush() async {
        isFlushing = true
        defer { isFlushing = false }

        while true {
            let pending = store.outbox(tripId: tripId)
            guard let first = pending.first else {
                retryDelay = 2
                setSync(.idle)
                await refreshFromServer()
                return
            }
            guard NetworkMonitor.shared.isOnline else {
                setSync(.offline)
                return
            }
            setSync(.syncing)

            do {
                if first.kind == .startTrip {
                    // Bắt đầu chuyến luôn gửi riêng, trước mọi sự kiện điểm danh (05 §7).
                    _ = try await service.startTrip(tripId: tripId, startedAtMs: first.startedAtMs ?? first.createdAtMs)
                    store.removeOutbox(eventIds: [first.eventId])
                } else {
                    let batch = Array(pending.prefix { $0.kind == .attendance }.prefix(100))
                    let response = try await service.syncAttendance(tripId: tripId, events: batch.compactMap(\.attendance))
                    handle(response: response, batch: batch)
                }
                retryDelay = 2
            } catch let error as APIError {
                if shouldRetry(error) {
                    scheduleRetry(after: retryAfter(error))
                } else if first.kind == .startTrip {
                    setSync(.blocked("\(error.localizedDescription). Liên hệ giám sát viên."))
                } else {
                    setSync(.blocked(error.localizedDescription))
                }
                return
            } catch {
                scheduleRetry(after: nil)
                return
            }
        }
    }

    private func handle(response: AttendanceSyncResponse, batch: [OutboxItem]) {
        var done: [String] = []
        for result in response.results {
            done.append(result.eventId)
            guard result.result == "rejected" else { continue }
            let source = batch.first { $0.eventId == result.eventId }
            store.addRejected(RejectedEvent(
                eventId: result.eventId,
                tripId: tripId,
                title: describe(source),
                message: result.message ?? result.reason ?? "Server từ chối thao tác",
                recordedAtMs: source?.attendance?.recordedAtMs ?? Date().milliseconds
            ))
        }
        store.removeOutbox(eventIds: done)
    }

    private func describe(_ item: OutboxItem?) -> String {
        guard let item, let event = item.attendance else { return "Thao tác điểm danh" }
        let name = item.studentId.flatMap { id in items.first { $0.studentId == id }?.fullName }
        let action: String
        switch event.eventType {
        case .boarded: action = "Lên xe"
        case .alighted: action = "Xuống xe"
        case .revoked: action = "Thu hồi"
        }
        let method = event.scanMethod == .qr ? "quét QR" : "tay"
        let who = name.map { " · \($0)" } ?? ""
        return "\(action) (\(method))\(who) lúc \(TimeFormat.time(ms: event.recordedAtMs))"
    }

    private func shouldRetry(_ error: APIError) -> Bool {
        switch error {
        case .network: return true
        case .server(let serverError): return serverError.status >= 500 || serverError.status == 429
        default: return false
        }
    }

    private func retryAfter(_ error: APIError) -> TimeInterval? {
        if case .server(let serverError) = error, let seconds = serverError.retryAfterSeconds {
            return TimeInterval(seconds)
        }
        return nil
    }

    private func scheduleRetry(after explicit: TimeInterval?) {
        let delay = explicit ?? retryDelay
        retryDelay = min(retryDelay * 2, 60)
        setSync(.retrying(seconds: Int(delay)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    // MARK: - Ghế cuối & hoàn tất (US14, US15)

    /// Điều kiện trước khi quét ghế cuối: có mạng, outbox trống, không còn em trên xe.
    enum SafetyPrecondition {
        case ready
        case needsSync(pending: Int)
        case offline
        case studentsOnBoard([ManifestItem])
    }

    var safetyPrecondition: SafetyPrecondition {
        if !NetworkMonitor.shared.isOnline { return .offline }
        let pending = pendingCount
        if pending > 0 { return .needsSync(pending: pending) }
        let onBoard = boardedItems
        if !onBoard.isEmpty { return .studentsOnBoard(onBoard) }
        return .ready
    }

    func safetyCheck(rearQrPayload: String) async throws -> SafetyCheckResponse {
        let location = LocationTracker.shared.recentLocation
        let response = try await service.safetyCheck(tripId: tripId, rearQrPayload: rearQrPayload,
                                                     latitude: location?.coordinate.latitude,
                                                     longitude: location?.coordinate.longitude)
        await refreshFromServer()
        return response
    }

    func complete() async throws -> CompleteTripResponse {
        let response = try await service.completeTrip(tripId: tripId)
        local.manifest.trip.status = .completed
        try? store.saveManifest(local)
        notify()
        return response
    }

    func sendSOS(category: SOSCategory, note: String?) async throws -> SOSResponse {
        let location = LocationTracker.shared.recentLocation
        return try await service.sos(tripId: tripId, category: category, note: note,
                                     latitude: location?.coordinate.latitude,
                                     longitude: location?.coordinate.longitude)
    }

    /// Chỉ đường tới điểm cần tới tiếp theo (hoặc `stopId`) từ vị trí hiện tại.
    func directions(from location: CLLocation, stopId: String? = nil) async throws -> DirectionsResponse {
        try await service.directions(tripId: tripId, latitude: location.coordinate.latitude,
                                     longitude: location.coordinate.longitude, stopId: stopId)
    }

    func dismissRejected(_ event: RejectedEvent) {
        store.dismissRejected(eventId: event.eventId)
        notify()
    }

    // MARK: - Private

    private func setSync(_ state: SyncState) {
        guard syncState != state else { return }
        syncState = state
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .tripSessionDidChange, object: self)
    }
}

// MARK: - Quản lý các chuyến đang mở

@MainActor
final class TripSessionManager {
    static let shared = TripSessionManager()

    private let store: DriverLocalStore
    private let service: DriverService
    private var sessions: [String: TripSession] = [:]

    init(store: DriverLocalStore = .shared, service: DriverService = DriverService()) {
        self.store = store
        self.service = service
    }

    /// Mở chuyến: tải manifest (US03). Mất mạng thì dùng bản đã lưu trên máy.
    func open(tripId: String) async throws -> TripSession {
        do {
            let server = try await service.manifest(tripId: tripId)
            if let session = sessions[tripId] {
                session.apply(server: server)
                session.flush()
                return session
            }
            let local = TripSession.merge(server: server, previous: store.loadManifest(tripId: tripId), pending: store.outbox(tripId: tripId))
            try store.saveManifest(local)
            let session = TripSession(local: local, store: store, service: service)
            sessions[tripId] = session
            session.flush()
            ImageLoader.shared.prefetch(paths: server.manifestItems.compactMap(\.photoUrl))
            return session
        } catch let error as APIError {
            guard case .network = error else { throw error }
            if let session = sessions[tripId] { return session }
            guard let cached = store.loadManifest(tripId: tripId) else { throw error }
            let session = TripSession(local: cached, store: store, service: service)
            sessions[tripId] = session
            return session
        }
    }

    /// Gửi tiếp outbox còn tồn của mọi chuyến (ví dụ sau khi mở lại app).
    func resumePendingSyncs() {
        for tripId in store.tripIdsWithPendingOutbox() {
            if sessions[tripId] == nil, let cached = store.loadManifest(tripId: tripId) {
                sessions[tripId] = TripSession(local: cached, store: store, service: service)
            }
            sessions[tripId]?.flush()
        }
    }

    var hasPendingOutbox: Bool { store.totalPendingCount() > 0 }

    /// Chuyến đang chạy trên máy (mỗi phụ xe chỉ có một).
    var activeSession: TripSession? { sessions.values.first { $0.isActive } }

    // MARK: - Sự kiện realtime

    /// `manifest:updated`: tải lại manifest (vẫn giữ thao tác chưa đồng bộ) rồi báo phụ xe nếu cần.
    func handleRemoteChange(_ change: ManifestRemoteChange) {
        guard let session = sessions[change.tripId] else { return }
        Task {
            await session.refreshFromServer()
            if let message = change.message {
                NotificationCenter.default.post(name: .manifestDidChangeRemotely, object: session, userInfo: ["message": message])
            }
        }
    }

    /// `trip:stop_arrived`: tiến độ điểm dừng thay đổi, tải lại để cập nhật "điểm tiếp theo".
    func handleStopArrived(tripId: String) {
        guard let session = sessions[tripId] else { return }
        Task { await session.refreshFromServer() }
    }

    /// `session:revoked { trip_reassigned }`: chuyến đã giao cho phụ xe khác.
    func handleTripReassigned() {
        NotificationCenter.default.post(name: .tripWasReassigned, object: nil)
    }

    /// Có chuyến đang chạy trên máy (chặn đăng xuất, US16 AC2).
    var hasActiveTrip: Bool { sessions.values.contains { $0.isActive } }

    func reset() {
        sessions.removeAll()
    }
}
