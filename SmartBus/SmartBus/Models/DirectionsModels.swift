//
//  DirectionsModels.swift
//  SmartBus
//
//  GET /driver/trips/:id/directions (04 §10.8, 05 §8.6).
//  Server hỏi Goong (dự phòng OSRM) bằng key của server; polyline mã hóa precision 5.
//

import Foundation
import CoreLocation

struct DirectionsStop: Decodable {
    let id: String
    let name: String
    let stopOrder: Int
    let latitude: Double
    let longitude: Double
    let isSchool: Bool
}

struct LatLng: Decodable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// depart, straight, turn-left, turn-right, slight-left, slight-right, sharp-left, sharp-right, uturn, roundabout, arrive
struct DirectionsStep: Decodable {
    let instruction: String
    let maneuver: String
    let distanceMeters: Int
    let durationSeconds: Int
    let startLocation: LatLng?
    let endLocation: LatLng?
    let polyline: String?

    var symbol: String {
        switch maneuver {
        case "depart": return "location.north.fill"
        case "turn-left", "sharp-left": return "arrow.turn.up.left"
        case "turn-right", "sharp-right": return "arrow.turn.up.right"
        case "slight-left": return "arrow.up.left"
        case "slight-right": return "arrow.up.right"
        case "uturn": return "arrow.uturn.down"
        case "roundabout": return "arrow.triangle.turn.up.right.circle"
        case "arrive": return "mappin.circle.fill"
        default: return "arrow.up"
        }
    }
}

struct DirectionsResponse: Decodable {
    let targetStop: DirectionsStop
    let distanceMeters: Int
    let durationSeconds: Int
    let polyline: String?
    let steps: [DirectionsStep]
    /// "goong" hoặc "osrm"
    let source: String?
    let calculatedAtMs: Int64
}

enum DistanceFormat {
    static func meters(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1f km", Double(value) / 1000) : "\(value) m"
    }

    static func duration(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) giờ \(minutes % 60) phút" : "\(minutes) phút"
    }
}

/// Giải mã Encoded Polyline (Google, precision 5) — dùng cho polyline tuyến và chỉ đường.
enum Polyline {
    static func decode(_ encoded: String, precision: Double = 1e5) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0

        func nextValue() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLng = nextValue() else { break }
            latitude += dLat
            longitude += dLng
            coordinates.append(CLLocationCoordinate2D(latitude: Double(latitude) / precision, longitude: Double(longitude) / precision))
        }
        return coordinates
    }
}
