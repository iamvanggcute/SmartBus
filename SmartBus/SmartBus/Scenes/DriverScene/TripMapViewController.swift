//
//  TripMapViewController.swift
//  SmartBus
//
//  Bản đồ & chỉ đường cho phụ xe (màn A-Navigate, 05 §8.6):
//  - Tuyến (`route.polyline`) và các điểm dừng theo tiến độ done / next / upcoming.
//  - Chỉ đường từng bước từ GET /driver/trips/:id/directions (Goong, dự phòng OSRM).
//  - Dịch vụ bản đồ lỗi hoặc mất mạng: vẫn hiện điểm dừng, điểm danh bình thường.
//

import UIKit
import MapKit
import CoreLocation

final class TripMapViewController: UIViewController {
    private let session: TripSession
    private var directions: DirectionsResponse?
    private var directionsError: String?
    private var lastFetchLocation: CLLocation?
    private var lastFetchAt = Date.distantPast
    private var isFetching = false
    private var hasCenteredOnUser = false
    private var observers: [NSObjectProtocol] = []

    /// Tính lại đường khi đi xa > 150 m hoặc sau 90 giây (giới hạn server 120 lượt / giờ).
    private let refetchDistance: CLLocationDistance = 150
    private let refetchInterval: TimeInterval = 90

    private let mapView = MKMapView()
    private let stepBanner = UIView()
    private let stepIcon = UIImageView()
    private let stepDistanceLabel = makeLabel(size: 20, weight: .bold, color: .white)
    private let stepTextLabel = makeLabel(size: 15, weight: .medium, color: .white)
    private let sheet = UIView()
    private let progressLabel = makeLabel(size: 13, weight: .semibold, color: Theme.muted)
    private let targetLabel = makeLabel(size: 20, weight: .bold)
    private let summaryLabel = makeLabel(size: 15, weight: .semibold, color: Theme.primary)
    private let sourceLabel = makeLabel(size: 12, color: Theme.muted)
    private let stopsStack = UIStackView()
    private let scanButton = AppButton.make("Tới nơi · Quét QR", style: .dark, symbol: "qrcode.viewfinder")

    private var routeOverlay: MKPolyline?
    private var directionsOverlay: MKPolyline?

    init(session: TripSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chỉ đường"
        view.backgroundColor = Theme.background
        setupMap()
        setupBanner()
        setupSheet()
        setupNavigationItems()

        observers.append(NotificationCenter.default.addObserver(forName: .tripSessionDidChange, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .locationDidUpdate, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locationChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .locationAuthorizationDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .networkStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if NetworkMonitor.shared.isOnline { self?.fetchDirections(force: true) } else { self?.render() }
            }
        })

        if session.isActive { LocationTracker.shared.start() }
        drawRoute()
        drawStops()
        render()
        fitRoute()
        fetchDirections(force: true)
    }

    // MARK: - Layout

    private func setupMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.pointOfInterestFilter = .excludingAll
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let tracking = MKUserTrackingButton(mapView: mapView)
        tracking.backgroundColor = .white
        tracking.layer.cornerRadius = 10
        tracking.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tracking)
        NSLayoutConstraint.activate([
            tracking.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tracking.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 120),
            tracking.widthAnchor.constraint(equalToConstant: 44),
            tracking.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func setupBanner() {
        stepBanner.backgroundColor = Theme.primary
        stepBanner.layer.cornerRadius = 18
        stepBanner.translatesAutoresizingMaskIntoConstraints = false
        stepIcon.tintColor = .white
        stepIcon.contentMode = .scaleAspectFit
        stepIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        stepIcon.setContentHuggingPriority(.required, for: .horizontal)
        stepIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let texts = UIStackView(arrangedSubviews: [stepDistanceLabel, stepTextLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [stepIcon, texts])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        stepBanner.addSubview(row)
        view.addSubview(stepBanner)

        let tap = UITapGestureRecognizer(target: self, action: #selector(showSteps))
        stepBanner.addGestureRecognizer(tap)
        stepBanner.isAccessibilityElement = true
        stepBanner.accessibilityTraits = .button
        stepBanner.accessibilityHint = "Xem các bước chỉ đường"

        NSLayoutConstraint.activate([
            stepBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stepBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stepBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: stepBanner.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: stepBanner.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: stepBanner.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: stepBanner.trailingAnchor, constant: -16)
        ])
    }

    private func setupSheet() {
        sheet.backgroundColor = .white
        sheet.layer.cornerRadius = 24
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.layer.shadowColor = UIColor.black.cgColor
        sheet.layer.shadowOpacity = 0.12
        sheet.layer.shadowRadius = 16
        sheet.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheet)

        let grabber = UIView()
        grabber.backgroundColor = Theme.line
        grabber.layer.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.widthAnchor.constraint(equalToConstant: 36).isActive = true
        grabber.heightAnchor.constraint(equalToConstant: 5).isActive = true
        let grabberRow = UIStackView(arrangedSubviews: [grabber])
        grabberRow.alignment = .center
        grabberRow.axis = .vertical

        sourceLabel.textAlignment = .right
        let summaryRow = UIStackView(arrangedSubviews: [summaryLabel, sourceLabel])
        summaryRow.spacing = 8

        stopsStack.axis = .vertical
        stopsStack.spacing = 8

        let note = makeLabel("Điểm không còn em cần đón sẽ được bỏ qua.", size: 12, color: Theme.muted)
        scanButton.addTarget(self, action: #selector(openScanner), for: .touchUpInside)

        let content = UIStackView(arrangedSubviews: [grabberRow, progressLabel, targetLabel, summaryRow, stopsStack, note, scanButton])
        content.axis = .vertical
        content.spacing = 6
        content.setCustomSpacing(10, after: grabberRow)
        content.setCustomSpacing(14, after: summaryRow)
        content.setCustomSpacing(10, after: stopsStack)
        content.setCustomSpacing(14, after: note)
        content.translatesAutoresizingMaskIntoConstraints = false
        sheet.addSubview(content)

        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func setupNavigationItems() {
        var items: [UIBarButtonItem] = []
        if session.isActive {
            let sos = UIBarButtonItem(title: "SOS", style: .prominent, target: self, action: #selector(openSOS))
            sos.tintColor = Theme.danger
            items.append(sos)
        }
        let refresh = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(refreshTapped))
        refresh.accessibilityLabel = "Tính lại đường"
        items.append(refresh)
        navigationItem.rightBarButtonItems = items
    }

    // MARK: - Map content

    private var orderedStops: [RouteStop] {
        // Cùng thứ tự với server (orderStopsForDirection): đi học theo stop_order;
        // về nhà: điểm trường trước, các điểm nhà theo thứ tự ngược lại.
        let stops = session.manifest.route.stops.sorted { $0.stopOrder < $1.stopOrder }
        guard session.trip.direction == .fromSchool else { return stops }
        return stops.filter(\.isSchool) + stops.filter { !$0.isSchool }.reversed()
    }

    private func drawRoute() {
        if let routeOverlay { mapView.removeOverlay(routeOverlay) }
        let coordinates: [CLLocationCoordinate2D]
        if let encoded = session.manifest.route.polyline, !encoded.isEmpty {
            coordinates = Polyline.decode(encoded)
        } else {
            coordinates = orderedStops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        guard coordinates.count > 1 else { return }
        let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        overlay.title = "route"
        mapView.addOverlay(overlay, level: .aboveRoads)
        routeOverlay = overlay
    }

    private func drawDirections() {
        if let directionsOverlay { mapView.removeOverlay(directionsOverlay) }
        directionsOverlay = nil
        guard let encoded = directions?.polyline else { return }
        let coordinates = Polyline.decode(encoded)
        guard coordinates.count > 1 else { return }
        let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        overlay.title = "directions"
        mapView.addOverlay(overlay, level: .aboveLabels)
        directionsOverlay = overlay
    }

    private func drawStops() {
        mapView.removeAnnotations(mapView.annotations.filter { $0 is StopAnnotation })
        let stops = orderedStops
        let targetId = directions?.targetStop.id ?? session.nextStop?.id
        for (index, stop) in stops.enumerated() {
            mapView.addAnnotation(StopAnnotation(stop: stop, number: index + 1, isTarget: stop.id == targetId,
                                                 studentCount: studentCount(at: stop)))
        }
    }

    private func fitRoute() {
        let points = orderedStops.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        guard var rect = points.first.map({ MKMapRect(origin: $0, size: MKMapSize(width: 0, height: 0)) }) else { return }
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 360, right: 40), animated: false)
    }

    /// Số em cần đón (đi học: chưa lên) hoặc cần trả (về nhà: đang trên xe) ở điểm dừng.
    private func studentCount(at stop: RouteStop) -> Int {
        let needed: ManifestStatus = session.trip.direction == .toSchool ? .expected : .boarded
        return session.items.filter { $0.stopId == stop.id && $0.status == needed }.count
    }

    // MARK: - Render

    private func render() {
        renderBanner()
        renderSheet()
    }

    private func renderBanner() {
        if !session.isActive {
            setBanner(symbol: "info.circle", distance: "Chưa có chỉ đường", text: "Bắt đầu chuyến để xem đường tới điểm tiếp theo", color: Theme.slate)
        } else if LocationTracker.shared.isDenied {
            setBanner(symbol: "location.slash", distance: "Chưa có quyền vị trí",
                      text: "Mở Cài đặt → SafeBus → Vị trí → Khi dùng ứng dụng", color: Theme.slate)
        } else if !NetworkMonitor.shared.isOnline {
            setBanner(symbol: "wifi.slash", distance: "Mất kết nối mạng",
                      text: "Chỉ hiện các điểm dừng · vẫn quét QR và điểm danh bình thường", color: Theme.slate)
        } else if let directionsError {
            setBanner(symbol: "exclamationmark.triangle", distance: "Không có chỉ đường", text: directionsError, color: Theme.slate)
        } else if let step = currentStep {
            setBanner(symbol: step.symbol, distance: DistanceFormat.meters(step.distanceMeters), text: step.instruction, color: Theme.primary)
        } else {
            setBanner(symbol: "location.circle", distance: "Đang tìm vị trí…", text: "Giữ điện thoại ở nơi thoáng để bắt GPS", color: Theme.slate)
        }
    }

    private func setBanner(symbol: String, distance: String, text: String, color: UIColor) {
        stepIcon.image = UIImage(systemName: symbol)
        stepDistanceLabel.text = distance
        stepTextLabel.text = text
        stepBanner.backgroundColor = color
        stepBanner.accessibilityLabel = "\(distance). \(text)"
    }

    /// Bước đang đi: bỏ bước "depart" và bước có điểm cuối đã ở rất gần.
    private var currentStep: DirectionsStep? {
        guard let steps = directions?.steps, !steps.isEmpty else { return nil }
        let location = LocationTracker.shared.recentLocation
        let remaining = steps.drop { step in
            if step.maneuver == "depart" { return true }
            guard let location, let end = step.endLocation else { return false }
            return location.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) < 25 && step.maneuver != "arrive"
        }
        return remaining.first ?? steps.last
    }

    private func renderSheet() {
        let stops = orderedStops
        let target: (id: String, name: String)?
        if let directions {
            target = (directions.targetStop.id, directions.targetStop.name)
        } else if let next = session.nextStop {
            target = (next.id, next.name)
        } else {
            target = nil
        }
        if let target, let index = stops.firstIndex(where: { $0.id == target.id }) {
            progressLabel.text = "Điểm tiếp theo · \(index + 1)/\(stops.count)"
            targetLabel.text = target.name
        } else {
            progressLabel.text = "\(stops.count) điểm dừng"
            targetLabel.text = session.manifest.route.name
        }

        if let directions, directionsError == nil {
            summaryLabel.text = "\(DistanceFormat.meters(directions.distanceMeters)) · khoảng \(DistanceFormat.duration(directions.durationSeconds))"
            summaryLabel.textColor = Theme.primary
            sourceLabel.text = directions.source == "osrm" ? "Nguồn: OSRM (dự phòng)" : "Nguồn: Goong"
        } else {
            summaryLabel.text = session.isActive ? "Vẫn quét QR và điểm danh bình thường" : "\(session.trip.direction.title) · \(session.manifest.vehicle.licensePlate)"
            summaryLabel.textColor = Theme.muted
            sourceLabel.text = isFetching ? "Đang tính đường…" : nil
        }

        renderStopList(stops, targetId: target?.id)
        scanButton.isHidden = !session.isActive
    }

    /// Các điểm đã qua gần nhất, điểm tiếp theo và vài điểm sau đó (như thiết kế).
    private func renderStopList(_ stops: [RouteStop], targetId: String?) {
        stopsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let targetIndex = targetId.flatMap { id in stops.firstIndex { $0.id == id } } ?? stops.firstIndex { $0.progress != "done" } ?? 0
        let lower = max(0, targetIndex - 2)
        let upper = min(stops.count, targetIndex + 2)
        guard lower < upper else { return }
        for index in lower..<upper {
            let stop = stops[index]
            let isDone = stop.progress == "done"
            let isTarget = stop.id == targetId
            let count = studentCount(at: stop)

            let badge = UILabel()
            badge.text = isDone ? "✓" : "\(index + 1)"
            badge.font = .systemFont(ofSize: 12, weight: .bold)
            badge.textAlignment = .center
            badge.textColor = isDone ? Theme.successText : (isTarget ? .white : Theme.slate)
            badge.backgroundColor = isDone ? Theme.successSoft : (isTarget ? Theme.primary : Theme.background)
            badge.layer.cornerRadius = 11
            badge.layer.masksToBounds = true
            badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

            var detail = stop.name
            if isDone, let arrived = stop.arrivedAtMs {
                detail += " · \(TimeFormat.time(ms: arrived))"
            } else if stop.isSchool {
                detail += " · Trường"
            } else if count > 0 {
                detail += " · \(count) em"
            }
            let label = makeLabel(detail, size: 14, weight: isTarget ? .bold : .regular,
                                  color: isDone ? Theme.muted : Theme.ink, lines: 1)
            let row = UIStackView(arrangedSubviews: [badge, label])
            row.spacing = 10
            row.alignment = .center
            stopsStack.addArrangedSubview(row)
        }
    }

    // MARK: - Events

    private func sessionChanged() {
        setupNavigationItems()
        drawStops()
        render()
        if session.isActive { LocationTracker.shared.start() }
    }

    private func locationChanged() {
        if !hasCenteredOnUser, session.isActive, LocationTracker.shared.recentLocation != nil {
            hasCenteredOnUser = true
            mapView.setUserTrackingMode(.followWithHeading, animated: true)
        }
        fetchDirections(force: false)
        renderBanner()
    }

    @objc private func refreshTapped() {
        fetchDirections(force: true)
    }

    @objc private func showSteps() {
        guard let directions, !directions.steps.isEmpty else { return }
        navigationController?.pushViewController(DirectionsStepsViewController(directions: directions), animated: true)
    }

    @objc private func openScanner() {
        let scanner = StudentScanViewController(session: session)
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    @objc private func openSOS() {
        present(UINavigationController(rootViewController: SOSViewController(session: session)), animated: true)
    }

    // MARK: - Directions

    private func fetchDirections(force: Bool) {
        guard session.isActive, NetworkMonitor.shared.isOnline, !isFetching,
              let location = LocationTracker.shared.recentLocation else {
            render()
            return
        }
        if !force {
            let movedFar = lastFetchLocation.map { location.distance(from: $0) > refetchDistance } ?? true
            let stale = Date().timeIntervalSince(lastFetchAt) > refetchInterval
            guard movedFar || stale else { return }
        }
        isFetching = true
        lastFetchAt = Date()
        lastFetchLocation = location
        render()
        Task {
            do {
                directions = try await session.directions(from: location)
                directionsError = nil
            } catch {
                directionsError = Self.message(for: error)
                if let apiError = error as? APIError, case .server(let serverError) = apiError,
                   serverError.code == "NO_REMAINING_STOP" {
                    directions = nil
                }
            }
            isFetching = false
            drawDirections()
            drawStops()
            render()
        }
    }

    static func message(for error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        switch apiError {
        case .network:
            return "Chỉ hiện các điểm dừng · vẫn quét QR và điểm danh bình thường"
        case .server(let serverError):
            switch serverError.code {
            case "ROUTING_SERVICE_UNAVAILABLE": return "Dịch vụ bản đồ đang lỗi · chỉ hiện các điểm dừng"
            case "NO_REMAINING_STOP": return serverError.message
            case "TOO_MANY_REQUESTS":
                let wait = serverError.retryAfterSeconds.map { " (thử lại sau \(max(1, $0 / 60)) phút)" } ?? ""
                return serverError.message + wait
            default: return serverError.message
            }
        default:
            return apiError.localizedDescription
        }
    }
}

// MARK: - MKMapViewDelegate

extension TripMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        if line.title == "directions" {
            renderer.strokeColor = Theme.primary
            renderer.lineWidth = 7
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
        guard let stop = annotation as? StopAnnotation else { return nil }
        let id = "stop"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation
        view.canShowCallout = true
        view.displayPriority = stop.isTarget ? .required : .defaultHigh
        if stop.stop.isSchool {
            view.markerTintColor = Theme.navy
            view.glyphImage = UIImage(systemName: "building.columns.fill")
            view.glyphText = nil
        } else if stop.stop.progress == "done" {
            view.markerTintColor = Theme.success
            view.glyphImage = UIImage(systemName: "checkmark")
            view.glyphText = nil
        } else {
            view.markerTintColor = stop.isTarget ? Theme.primary : Theme.slate
            view.glyphImage = nil
            view.glyphText = "\(stop.number)"
        }
        return view
    }
}

final class StopAnnotation: NSObject, MKAnnotation {
    let stop: RouteStop
    let number: Int
    let isTarget: Bool
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(stop: RouteStop, number: Int, isTarget: Bool, studentCount: Int) {
        self.stop = stop
        self.number = number
        self.isTarget = isTarget
        coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        title = "\(number). \(stop.name)"
        if stop.progress == "done" {
            subtitle = "Đã qua · \(TimeFormat.time(ms: stop.arrivedAtMs))"
        } else {
            subtitle = stop.isSchool ? "Trường" : "\(studentCount) em"
        }
    }
}

// MARK: - Danh sách bước chỉ đường

final class DirectionsStepsViewController: UITableViewController {
    private let directions: DirectionsResponse

    init(directions: DirectionsResponse) {
        self.directions = directions
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tới \(directions.targetStop.name)"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { directions.steps.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "\(DistanceFormat.meters(directions.distanceMeters)) · khoảng \(DistanceFormat.duration(directions.durationSeconds))"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let step = directions.steps[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: step.symbol)
        content.imageProperties.tintColor = Theme.primary
        content.text = step.instruction
        content.secondaryText = step.distanceMeters > 0 ? DistanceFormat.meters(step.distanceMeters) : nil
        content.secondaryTextProperties.color = Theme.muted
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
