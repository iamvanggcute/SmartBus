//
//  APIConfig.swift
//  SmartBus
//
//  Địa chỉ backend SafeBus. Đổi `baseURL` theo môi trường đang chạy.
//

import Foundation

enum APIConfig {
    /// REST gốc của backend, luôn kết thúc bằng `/api/v1`.
    /// - Simulator chạy cùng máy với backend: `http://localhost:3000/api/v1`
    /// - iPhone thật trong cùng Wi-Fi: `http://<IP-máy-chạy-backend>:3000/api/v1`
    /// - Qua tunnel: `https://<...>.trycloudflare.com/api/v1`
    static let baseURL = URL(string: "http://localhost:3000/api/v1")!

    /// Thời gian chờ mỗi request (giây).
    static let timeout: TimeInterval = 20

    /// Giá trị `client` gửi khi đăng nhập (04 §2.1): app iOS luôn là "ios".
    static let clientType = "ios"
}
