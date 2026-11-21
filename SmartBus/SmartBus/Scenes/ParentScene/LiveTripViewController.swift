//
//  LiveTripViewController.swift
//  SmartBus
//
//  Theo dõi xe trực tiếp (US19, US20, thiết kế P-Live / P-NoTrip):
//  - GET /trips/:id/live?student_id= mỗi 30 giây (ETA, đoạn đường còn lại, tiến độ điểm dừng).
//  - Socket.IO: trip:subscribe; trip:location_updated di chuyển xe ngay;
//    trip:stop_arrived / trip:status_changed thì tải lại.
//  - Vị trí cũ hơn 30 giây → "Mất tín hiệu"; chuyến không chạy → thẻ "Không có xe đang chạy".
//

import UIKit
import MapKit

final class LiveTripViewController: UIViewController {
    private let tripId: String?
    private let studentId: String
    private let childName: String
    private let service = ParentService()

    private var live: LiveTripResponse?
    private var lastRecordedMs: Int64?
    private var isLoading = false
    private var hasFitted = false
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var subscribedTripId: String?

    /// Gọi lại /live mỗi 30 giây (04 §9.7); vị trí cũ hơn 30 giây là mất tín hiệu (05 §8.1).
    private let refreshInterval: TimeInterval = 30
    private let staleAfterMs: Int64 = 30_000

    private let mapView = MKMapView()
    private let chip = UIStackView()
    private let chipDot = UIView()
    private let chipLabel = makeLabel(size: 13, weight: .semibold)
    private let panel = UIView()
    private let etaLabel = makeLabel(size: 14, color: Theme.muted)
    private let etaValue = makeLabel(size: 28, weight: .heavy)
    private let etaSub = makeLabel(size: 14, color: Theme.slate)
    private let studentPill = PillLabel()
    private let stopsStack = UIStackView()
    private let vehicleTitle = makeLabel(size: 15, weight: .bold)
    private let vehicleSub = makeLabel(size: 13, color: Theme.muted)
    private let liveContent = UIStackView()
    private let noTripContent = UIStackView()

    private let busAnnotation = BusAnnotation()
    private var routeOverlay: MKPolyline?
    private var etaOverlay: MKPolyline?

    init(child: ParentChild) {
        tripId = child.currentTrip?.tripId
        studentId = child.id
        childName = child.fullName
        super.init(nibName: nil, bundle: nil)
    }

    /// Mở từ thông báo (có trip_id và student_id).
    init(tripId: String, studentId: String, childName: String) {
        self.tripId = tripId
        self.studentId = studentId
        self.childName = childName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Theo dõi xe"
        view.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain,
                                                            target: self, action: #selector(refreshTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Tải lại"
        setupMap()
        setupChip()
        setupPanel()
        observeRealtime()
        renderLoading()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let tripId {
            RealtimeClient.shared.connect()
            RealtimeClient.shared.subscribe(tripId: tripId)
            subscribedTripId = tripId
        }
        startTimers()
        Task { await load() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
        if let subscribedTripId { RealtimeClient.shared.unsubscribe(tripId: subscribedTripId) }
        subscribedTripId = nil
    }

    // MARK: - Layout

    private func setupMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupChip() {
        chipDot.layer.cornerRadius = 5
        chipDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        chipDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        chip.addArrangedSubview(chipDot)
        chip.addArrangedSubview(chipLabel)
        chip.spacing = 8
        chip.alignment = .center
        chip.isLayoutMarginsRelativeArrangement = true
        chip.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14)
        chip.backgroundColor = .white
        chip.layer.cornerRadius = 18
        chip.layer.shadowColor = UIColor.black.cgColor
        chip.layer.shadowOpacity = 0.12
        chip.layer.shadowRadius = 8
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.isAccessibilityElement = true
        view.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            chip.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func setupPanel() {
        panel.backgroundColor = .white
        panel.layer.cornerRadius = 24
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.12
        panel.layer.shadowRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        // Nội dung khi chuyến đang chạy.
        stopsStack.axis = .vertical
        stopsStack.spacing = 8
        let vehicleIcon = UIImageView(image: UIImage(systemName: "bus.fill"))
        vehicleIcon.tintColor = Theme.navy
        vehicleIcon.setContentHuggingPriority(.required, for: .horizontal)
        let vehicleTexts = UIStackView(arrangedSubviews: [vehicleTitle, vehicleSub])
        vehicleTexts.axis = .vertical
        vehicleTexts.spacing = 2
        let vehicleRow = UIStackView(arrangedSubviews: [vehicleIcon, vehicleTexts])
        vehicleRow.spacing = 10
        vehicleRow.alignment = .center
        let separator = UIView()
        separator.backgroundColor = Theme.line
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        for view in [etaLabel, etaValue, etaSub, UIStackView(arrangedSubviews: [studentPill, UIView()]), separator, stopsStack, vehicleRow] {
            liveContent.addArrangedSubview(view)
        }
        liveContent.axis = .vertical
        liveContent.spacing = 6
        liveContent.setCustomSpacing(2, after: etaLabel)
        liveContent.setCustomSpacing(10, after: etaSub)
        liveContent.setCustomSpacing(12, after: liveContent.arrangedSubviews[3])
        liveContent.setCustomSpacing(12, after: separator)
        liveContent.setCustomSpacing(14, after: stopsStack)

        noTripContent.axis = .vertical
        noTripContent.spacing = 12
        noTripContent.isHidden = true

        let container = UIStackView(arrangedSubviews: [liveContent, noTripContent])
        container.axis = .vertical
        container.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(container)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            container.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Data

    private func startTimers() {
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.load() }
            }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderChip() }
        }
    }

    @objc private func refreshTapped() {
        Task { await load() }
    }

    private func load() async {
        guard let tripId else {
            renderNoTrip(title: "Hôm nay không có chuyến", detail: "\(childName) không có chuyến xe nào hôm nay.", pill: nil)
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await service.live(tripId: tripId, studentId: studentId)
            live = response
            lastRecordedMs = response.currentLocation?.recordedAtMs
            render()
        } catch let error as APIError {
            if case .server(let serverError) = error, serverError.status == 401 { return }
            if live == nil {
                renderNoTrip(title: "Không tải được chuyến", detail: error.localizedDescription, pill: nil)
            } else {
                renderChip() // Giữ dữ liệu cũ; chip sẽ báo mất tín hiệu nếu quá 30 giây.
            }
        } catch {
            if live == nil { renderNoTrip(title: "Không tải được chuyến", detail: error.localizedDescription, pill: nil) }
        }
    }

    private func observeRealtime() {
        observers.append(NotificationCenter.default.addObserver(forName: .tripLocationDidUpdate, object: nil, queue: .main) { [weak self] note in
            guard let update = note.object as? TripLocationUpdate else { return }
            MainActor.assumeIsolated { self?.apply(update) }
        })
        for name in [Notification.Name.tripStopDidArrive, .tripStatusDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let tripId = note.userInfo?["trip_id"] as? String
                MainActor.assumeIsolated {
                    guard let self, tripId == self.tripId else { return }
                    Task { await self.load() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .realtimeStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, RealtimeClient.shared.isConnected else { return }
                Task { await self.load() }
            }
        })
    }

    private func apply(_ update: TripLocationUpdate) {
        guard update.tripId == tripId, var current = live, current.trip.status == .active else { return }
        let location = LiveLocation(latitude: update.latitude, longitude: update.longitude, speedKmh: update.speedKmh,
                                    heading: update.heading, recordedAtMs: update.recordedAtMs, isStale: false)
        current.currentLocation = location
        live = current
        lastRecordedMs = update.recordedAtMs
        moveBus(to: location, animated: true)
        renderChip()
        renderVehicle(current)
    }

    // MARK: - Render

    private func renderLoading() {
        liveContent.isHidden = false
        noTripContent.isHidden = true
        etaLabel.text = "Đang tải chuyến của \(childName)…"
        etaValue.text = " "
        etaSub.text = nil
        studentPill.isHidden = true
        chipLabel.text = "Đang kết nối…"
        chipDot.backgroundColor = Theme.slate
    }

    private func render() {
        guard let live else { return }
        drawRouteAndStops(live)

        guard live.trip.status == .active else {
            renderNoTripState(live)
            return
        }
        liveContent.isHidden = false
        noTripContent.isHidden = true
        if let location = live.currentLocation {
            moveBus(to: location, animated: hasFitted)
        } else {
            mapView.removeAnnotation(busAnnotation)
        }
        drawETA(live)
        renderETA(live)
        renderStops(live)
        renderVehicle(live)
        renderChip()
        if !hasFitted { fit(live); hasFitted = true }
    }

    private var isStale: Bool {
        guard let lastRecordedMs else { return false }
        return Date().milliseconds - lastRecordedMs > staleAfterMs
    }

    private func renderChip() {
        guard let live, live.trip.status == .active else {
            chip.isHidden = live != nil
            return
        }
        chip.isHidden = false
        if let lastRecordedMs {
            if isStale {
                chipLabel.text = "Mất tín hiệu – cập nhật lúc \(TimeFormat.time(ms: lastRecordedMs))"
                chipLabel.textColor = Theme.warningText
                chip.backgroundColor = Theme.warningSoft
                chipDot.backgroundColor = UIColor(hex: 0xD97706)
                busAnnotation.isStale = true
            } else {
                chipLabel.text = "Trực tiếp · \(ParentFormat.ago(ms: lastRecordedMs))"
                chipLabel.textColor = Theme.ink
                chip.backgroundColor = .white
                chipDot.backgroundColor = Theme.success
                busAnnotation.isStale = false
            }
        } else {
            chipLabel.text = "Chưa có vị trí xe"
            chipLabel.textColor = Theme.slate
            chip.backgroundColor = .white
            chipDot.backgroundColor = Theme.slate
        }
        (mapView.view(for: busAnnotation) as? BusAnnotationView)?.update(stale: busAnnotation.isStale)
        chip.accessibilityLabel = chipLabel.text
    }

    private func renderETA(_ live: LiveTripResponse) {
        let name = live.student?.fullName ?? childName
        let status = live.student?.status ?? .expected
        let studentStop = live.stops.first(where: \.isStudentStop)?.name
        studentPill.isHidden = false

        switch status {
        case .expected:
            studentPill.configure("\(name) · chưa lên xe", background: Theme.warningSoft, foreground: Theme.warningText)
        case .boarded:
            studentPill.configure("Trên xe", background: Theme.successSoft, foreground: Theme.successText)
        case .alighted:
            studentPill.configure("Đã xuống xe", background: Theme.infoSoft, foreground: Theme.infoText)
        case .absent:
            studentPill.configure("Vắng", background: ManifestStatus.absent.colors.background, foreground: ManifestStatus.absent.colors.foreground)
        }

        if let eta = live.eta {
            etaLabel.text = "Xe đến \(eta.targetStopName) sau khoảng"
            etaValue.text = eta.etaMinutes <= 0 ? "Sắp đến" : "\(eta.etaMinutes) phút"
            if eta.isEstimate {
                etaSub.text = "Ước tính theo khoảng cách" + (eta.distanceMeters.map { " · cách \(DistanceFormat.meters($0))" } ?? "")
            } else {
                etaSub.text = eta.distanceMeters.map { "Cách \(DistanceFormat.meters($0)) theo đường đi" }
            }
        } else if live.currentLocation == nil, status == .expected {
            etaLabel.text = "Chuyến đã bắt đầu"
            etaValue.text = "Đang chờ vị trí"
            etaSub.text = "Thời gian đến sẽ hiện khi xe gửi vị trí"
        } else {
            switch status {
            case .boarded:
                etaLabel.text = "\(name) đang trên xe"
                etaValue.text = "Đã lên xe"
                etaSub.text = live.trip.direction == .toSchool ? "Xe đang tới trường" : "Xe đang đưa em về \(studentStop ?? "điểm trả")"
            case .alighted:
                etaLabel.text = "\(name) đã xuống xe"
                etaValue.text = "Đã xuống xe"
                etaSub.text = studentStop.map { "Tại \($0)" }
            case .absent:
                etaLabel.text = "\(name) nghỉ chuyến này"
                etaValue.text = "Vắng"
                etaSub.text = "Xe không đón em ở chuyến này"
            case .expected:
                etaLabel.text = "Xe đang chạy"
                etaValue.text = "Đang tính…"
                etaSub.text = nil
            }
        }
        if isStale, live.currentLocation != nil {
            etaSub.text = [etaSub.text, "Hiển thị vị trí cuối cùng"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Điểm đã qua gần nhất, điểm của con và vài điểm quanh đó (như thiết kế P-Live).
    private func renderStops(_ live: LiveTripResponse) {
        stopsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let stops = live.orderedStops
        guard !stops.isEmpty else { return }
        let focus = stops.firstIndex { $0.progress == "next" } ?? stops.firstIndex(where: \.isStudentStop) ?? 0
        let lower = max(0, focus - 1)
        let upper = min(stops.count, max(focus + 2, (stops.firstIndex(where: \.isStudentStop) ?? 0) + 1))
        for index in lower..<upper {
            stopsStack.addArrangedSubview(stopRow(stops[index], number: index + 1))
        }
        if let school = stops.last(where: \.isSchool), live.trip.direction == .toSchool, upper < stops.count {
            stopsStack.addArrangedSubview(stopRow(school, number: stops.count))
        }
    }

    private func stopRow(_ stop: LiveStop, number: Int) -> UIView {
        let isDone = stop.progress == "done"
        let isNext = stop.progress == "next"
        let badge = UILabel()
        badge.text = isDone ? "✓" : (stop.isSchool ? "🏫" : "\(number)")
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textAlignment = .center
        badge.textColor = isDone ? Theme.successText : (isNext ? .white : Theme.slate)
        badge.backgroundColor = isDone ? Theme.successSoft : (isNext ? Theme.primary : Theme.background)
        badge.layer.cornerRadius = 11
        badge.layer.masksToBounds = true
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

        var text = stop.name
        if isDone, let arrived = stop.arrivedAtMs { text += " · \(TimeFormat.time(ms: arrived))" }
        if stop.isStudentStop { text += isNext ? " · điểm của con, tiếp theo" : " · điểm của con" }
        else if isNext { text += " · tiếp theo" }
        let label = makeLabel(text, size: 14, weight: stop.isStudentStop ? .bold : .regular,
                              color: isDone ? Theme.muted : Theme.ink, lines: 1)
        let row = UIStackView(arrangedSubviews: [badge, label])
        row.spacing = 10
        row.alignment = .center
        return row
    }

    private func renderVehicle(_ live: LiveTripResponse) {
        vehicleTitle.text = "\(live.vehicle.licensePlate) · \(live.route.name)"
        var parts: [String] = []
        if let model = live.vehicle.model { parts.append(model) }
        if let speed = live.currentLocation?.speedKmh, !isStale { parts.append("\(Int(speed.rounded())) km/h") }
        vehicleSub.text = parts.isEmpty ? live.trip.direction.title : parts.joined(separator: " · ")
    }

    // MARK: - Không có chuyến đang chạy (P-NoTrip)

    private func renderNoTripState(_ live: LiveTripResponse) {
        mapView.removeAnnotation(busAnnotation)
        if let etaOverlay { mapView.removeOverlay(etaOverlay) }
        etaOverlay = nil
        if !hasFitted { fit(live); hasFitted = true }

        let direction = live.trip.direction.title
        switch live.trip.status {
        case .scheduled:
            renderNoTrip(title: "Chuyến tiếp theo của \(childName) chưa bắt đầu.",
                         card: ("CHUYẾN TIẾP THEO", "\(direction) · \(live.vehicle.licensePlate)", live.route.name),
                         pill: ("Chưa bắt đầu", Theme.infoSoft, Theme.infoText))
        case .completed:
            renderNoTrip(title: "Chuyến \(direction.lowercased()) của \(childName) đã kết thúc.",
                         card: ("CHUYẾN GẦN NHẤT", "\(direction) · đã hoàn tất", "Xe \(live.vehicle.licensePlate) · \(live.route.name)"),
                         pill: ("Hoàn tất", Theme.successSoft, Theme.successText))
        case .cancelled:
            renderNoTrip(title: "Chuyến \(direction.lowercased()) của \(childName) đã bị hủy.",
                         card: ("CHUYẾN HÔM NAY", "\(direction) · đã hủy", "Vui lòng liên hệ nhà trường nếu cần."),
                         pill: ("Đã hủy", Theme.dangerSoft, Theme.dangerText))
        case .active:
            break
        }
    }

    private func renderNoTrip(title: String, detail: String, pill: (String, UIColor, UIColor)?) {
        renderNoTrip(title: title, card: nil, pill: pill, extra: detail)
    }

    private func renderNoTrip(title: String, card: (label: String, title: String, detail: String)?,
                              pill: (String, UIColor, UIColor)?, extra: String? = nil) {
        chip.isHidden = true
        liveContent.isHidden = true
        noTripContent.isHidden = false
        noTripContent.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let icon = UIImageView(image: UIImage(systemName: "bus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)))
        icon.tintColor = Theme.slate
        icon.contentMode = .left
        noTripContent.addArrangedSubview(icon)
        noTripContent.addArrangedSubview(makeLabel("Hiện không có chuyến xe nào đang chạy", size: 18, weight: .bold))
        noTripContent.addArrangedSubview(makeLabel(title, size: 14, color: Theme.muted))
        if let extra { noTripContent.addArrangedSubview(makeLabel(extra, size: 14, color: Theme.slate)) }

        if let card {
            let labels = UIStackView(arrangedSubviews: [
                makeLabel(card.label, size: 11, weight: .bold, color: Theme.slate),
                makeLabel(card.title, size: 16, weight: .bold),
                makeLabel(card.detail, size: 13, color: Theme.muted)
            ])
            labels.axis = .vertical
            labels.spacing = 3
            let row = UIStackView(arrangedSubviews: [labels])
            row.alignment = .center
            row.spacing = 8
            if let pill {
                let pillLabel = PillLabel()
                pillLabel.configure(pill.0, background: .white, foreground: pill.2)
                row.addArrangedSubview(pillLabel)
            }
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            row.backgroundColor = pill?.1 ?? Theme.background
            row.layer.cornerRadius = 14
            noTripContent.addArrangedSubview(row)
        }

        let hint = makeLabel("Bản đồ tự hiện xe khi chuyến bắt đầu", size: 13, color: Theme.muted)
        noTripContent.addArrangedSubview(hint)
        let back = AppButton.make("Về danh sách các con", style: .secondary)
        back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        noTripContent.addArrangedSubview(back)
    }

    // MARK: - Map

    private func drawRouteAndStops(_ live: LiveTripResponse) {
        if let routeOverlay { mapView.removeOverlay(routeOverlay) }
        routeOverlay = nil
        let stops = live.orderedStops
        var coordinates = live.route.polyline.map { Polyline.decode($0) } ?? []
        if coordinates.count < 2 {
            coordinates = stops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        if coordinates.count > 1 {
            let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
            overlay.title = "route"
            mapView.addOverlay(overlay, level: .aboveRoads)
            routeOverlay = overlay
        }
        mapView.removeAnnotations(mapView.annotations.filter { $0 is LiveStopAnnotation })
        for (index, stop) in stops.enumerated() {
            mapView.addAnnotation(LiveStopAnnotation(stop: stop, number: index + 1))
        }
    }

    private func drawETA(_ live: LiveTripResponse) {
        if let etaOverlay { mapView.removeOverlay(etaOverlay) }
        etaOverlay = nil
        guard let encoded = live.eta?.polyline else { return }
        let coordinates = Polyline.decode(encoded)
        guard coordinates.count > 1 else { return }
        let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        overlay.title = "eta"
        mapView.addOverlay(overlay, level: .aboveLabels)
        etaOverlay = overlay
    }

    private func moveBus(to location: LiveLocation, animated: Bool) {
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        if mapView.annotations.contains(where: { $0 === busAnnotation }) {
            if animated {
                UIView.animate(withDuration: 0.8) { self.busAnnotation.coordinate = coordinate }
            } else {
                busAnnotation.coordinate = coordinate
            }
        } else {
            busAnnotation.coordinate = coordinate
            mapView.addAnnotation(busAnnotation)
        }
    }

    private func fit(_ live: LiveTripResponse) {
        var points = live.stops.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        if let location = live.currentLocation {
            points.append(MKMapPoint(CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)))
        }
        guard let first = points.first else { return }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 90, left: 40, bottom: 380, right: 40), animated: false)
    }
}

// MARK: - MKMapViewDelegate

extension LiveTripViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        if line.title == "eta" {
            renderer.strokeColor = Theme.primary
            renderer.lineWidth = 6
        } else {
            renderer.strokeColor = Theme.slate.withAlphaComponent(0.45)
            renderer.lineWidth = 5
            renderer.lineDashPattern = [2, 8]
        }
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let bus = annotation as? BusAnnotation {
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: BusAnnotationView.reuseId) as? BusAnnotationView)
                ?? BusAnnotationView(annotation: bus, reuseIdentifier: BusAnnotationView.reuseId)
            view.annotation = bus
            view.update(stale: bus.isStale)
            return view
        }
        guard let stop = annotation as? LiveStopAnnotation else { return nil }
        let id = "liveStop"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation
        view.canShowCallout = true
        view.displayPriority = stop.stop.isStudentStop ? .required : .defaultHigh
        if stop.stop.isSchool {
            view.markerTintColor = Theme.navy
            view.glyphImage = UIImage(systemName: "building.columns.fill")
            view.glyphText = nil
        } else if stop.stop.isStudentStop {
            view.markerTintColor = Theme.primary
            view.glyphImage = UIImage(systemName: "house.fill")
            view.glyphText = nil
        } else if stop.stop.progress == "done" {
            view.markerTintColor = Theme.success
            view.glyphImage = UIImage(systemName: "checkmark")
            view.glyphText = nil
        } else {
            view.markerTintColor = Theme.slate
            view.glyphImage = nil
            view.glyphText = "\(stop.number)"
        }
        return view
    }
}

final class LiveStopAnnotation: NSObject, MKAnnotation {
    let stop: LiveStop
    let number: Int
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(stop: LiveStop, number: Int) {
        self.stop = stop
        self.number = number
        coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        title = stop.name
        if stop.progress == "done" {
            subtitle = stop.arrivedAtMs.map { "Đã qua · \(TimeFormat.time(ms: $0))" } ?? "Đã qua"
        } else if stop.isStudentStop {
            subtitle = "Điểm của con"
        } else {
            subtitle = stop.isSchool ? "Trường" : nil
        }
    }
}

final class BusAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var isStale = false
    let title: String? = "Xe đưa đón"
}

/// Xe màu vàng; mất tín hiệu thì xám và mờ (như thiết kế P-Live).
final class BusAnnotationView: MKAnnotationView {
    static let reuseId = "bus"
    private let icon = UIImageView(image: UIImage(systemName: "bus.fill"))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        layer.cornerRadius = 20
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 3
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        icon.tintColor = Theme.navy
        icon.contentMode = .scaleAspectFit
        icon.frame = bounds.insetBy(dx: 9, dy: 9)
        addSubview(icon)
        displayPriority = .required
        canShowCallout = false
        update(stale: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(stale: Bool) {
        backgroundColor = stale ? UIColor(hex: 0xCBD5E1) : Theme.schoolBus
        alpha = stale ? 0.75 : 1
    }
}
