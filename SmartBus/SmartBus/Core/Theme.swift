//
//  Theme.swift
//  SmartBus
//
//  Màu dùng chung, lấy từ bản thiết kế SafeBus.
//

import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Theme {
    static let primary = UIColor(hex: 0x1E4FD8)
    static let primarySoft = UIColor(hex: 0xE8EEFD)
    static let navy = UIColor(hex: 0x0B1B3F)
    static let schoolBus = UIColor(hex: 0xFFC21A)

    static let ink = UIColor(hex: 0x0F172A)
    static let muted = UIColor(hex: 0x64748B)
    static let slate = UIColor(hex: 0x475569)
    static let background = UIColor(hex: 0xF3F5F9)
    static let line = UIColor(hex: 0xE2E8F0)
    static let disabled = UIColor(hex: 0xE2E8F0)

    static let success = UIColor(hex: 0x16A34A)
    static let successSoft = UIColor(hex: 0xDCFCE7)
    static let successText = UIColor(hex: 0x166534)

    static let danger = UIColor(hex: 0xDC2626)
    static let dangerSoft = UIColor(hex: 0xFEE2E2)
    static let dangerText = UIColor(hex: 0x991B1B)

    static let warningSoft = UIColor(hex: 0xFEF3C7)
    static let warningText = UIColor(hex: 0x78350F)

    static let infoSoft = UIColor(hex: 0xE8EEFD)
    static let infoText = UIColor(hex: 0x1E3A8A)
}
