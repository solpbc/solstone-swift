// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let homeAPILog = Logger(subsystem: "app.solstone.swift", category: "home-api")

typealias ProgressTodaySnapshot = ProgressSnapshot

struct BriefingTime: Sendable, Equatable {
    let hour: Int
    let minute: Int
    let tzIdentifier: String

    init(hour: Int, minute: Int, tzIdentifier: String) {
        self.hour = hour
        self.minute = minute
        self.tzIdentifier = tzIdentifier
    }
}

@MainActor
struct HomeAPIClient: Sendable {
    private struct BriefingRequest: Encodable {
        let hour: Int
        let minute: Int
        let tzIdentifier: String

        enum CodingKeys: String, CodingKey {
            case hour
            case minute
            case tzIdentifier = "tz_identifier"
        }
    }

    private let loopbackPort: Int
    private let session: URLSession

    init(loopbackPort: Int, session: URLSession = .shared) {
        self.loopbackPort = loopbackPort
        self.session = session
    }

    func setBriefingTime(_ time: BriefingTime) async throws {
        let payload = BriefingRequest(
            hour: time.hour,
            minute: time.minute,
            tzIdentifier: time.tzIdentifier
        )
        _ = try await perform(
            path: "/api/settings/briefing-time",
            method: "PUT",
            body: try JSONEncoder().encode(payload)
        )
    }

    func progressToday() async throws -> ProgressTodaySnapshot {
        let data = try await perform(path: "/api/home/progress-today", method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(ProgressTodaySnapshot.self, from: data)
        } catch {
            homeAPILog.error("progress decode failed: \(String(describing: error), privacy: .public)")
            throw PairingClientError.decoding
        }
    }

    private func perform(path: String, method: String, body: Data?) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = loopbackPort
        components.path = path
        guard let url = components.url else {
            throw PairingClientError.network
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PairingClientError.network
        }
        guard 200..<300 ~= http.statusCode else {
            throw PairingClientError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}
