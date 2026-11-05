//
//  QRScannerView.swift
//  SmartBus
//
//  Camera quét QR liên tục bằng AVFoundation, không cần bấm chụp (US05 AC1).
//  Dùng chung cho thẻ học sinh và mã ghế cuối.
//

import UIKit
import AVFoundation

final class QRScannerView: UIView {
    /// Gọi trên main thread mỗi khi đọc được một mã (cùng mã trong 2 giây chỉ báo một lần).
    var onCode: ((String) -> Void)?
    /// Tạm ngừng báo mã (ví dụ đang chờ phụ xe xác nhận).
    var isPaused = false

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "SmartBus.QRScanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var device: AVCaptureDevice?
    private var lastCode: String?
    private var lastCodeAt = Date.distantPast
    private let messageLabel = UILabel()
    private var isConfigured = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: 0x0B1220)
        messageLabel.textColor = UIColor(hex: 0xCBD5E1)
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    var hasTorch: Bool { device?.hasTorch ?? false }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureAndRun() : self?.showMessage("SafeBus cần quyền Camera để quét QR. Mở Cài đặt → SafeBus → Camera.")
                }
            }
        default:
            showMessage("SafeBus cần quyền Camera để quét QR. Mở Cài đặt → SafeBus → Camera.")
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    private func configureAndRun() {
        guard !isConfigured else {
            sessionQueue.async { [session] in if !session.isRunning { session.startRunning() } }
            return
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            showMessage("Không mở được camera trên thiết bị này.")
            return
        }
        device = camera
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        isConfigured = true

        sessionQueue.async { [session] in session.startRunning() }
    }

    private func showMessage(_ text: String) {
        messageLabel.text = text
        messageLabel.isHidden = false
    }
}

extension QRScannerView: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !isPaused,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        let now = Date()
        if value == lastCode, now.timeIntervalSince(lastCodeAt) < 2 { return }
        lastCode = value
        lastCodeAt = now
        onCode?(value)
    }
}
