//
//  APIEnvelope.swift
//  SmartBus
//
//  Envelope chuẩn của backend (04 §1.2):
//  thành công `{ success: true, data, meta }`, lỗi `{ success: false, error, meta }`.
//

import Foundation

struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T
    let meta: APIMeta?
}

struct APIMeta: Decodable {
    let timestampMs: Int64?
    let pagination: Pagination?
}

struct Pagination: Decodable {
    let page: Int
    let limit: Int
    let total: Int
}

struct APIErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
        let details: [ErrorDetail]?
    }

    let success: Bool
    let error: Body
}
