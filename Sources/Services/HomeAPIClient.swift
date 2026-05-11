// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let homeAPILog = Logger(subsystem: "app.solstone.swift", category: "home-api")

enum HomeAPIError: Error, Equatable {
    case network
    case server(status: Int, body: String)
    case decoding
}

struct ProgressSnapshot: Decodable, Equatable, Sendable {
    let segmentsObserved: Int
    let meetingsDetected: Int
    let entitiesIdentified: Int
    let percent: Int
    let briefingReady: Bool?

    private enum CodingKeys: String, CodingKey {
        case segmentsObserved = "segments_observed"
        case meetingsDetected = "meetings_detected"
        case entitiesIdentified = "entities_identified"
        case percent
        case briefingReady = "briefing_ready"
        case hasBriefing = "has_briefing"
    }

    init(
        segmentsObserved: Int,
        meetingsDetected: Int,
        entitiesIdentified: Int,
        percent: Int,
        briefingReady: Bool? = nil
    ) {
        self.segmentsObserved = segmentsObserved
        self.meetingsDetected = meetingsDetected
        self.entitiesIdentified = entitiesIdentified
        self.percent = percent
        self.briefingReady = briefingReady
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.segmentsObserved = try container.decode(Int.self, forKey: .segmentsObserved)
        self.meetingsDetected = try container.decode(Int.self, forKey: .meetingsDetected)
        self.entitiesIdentified = try container.decode(Int.self, forKey: .entitiesIdentified)
        self.percent = try container.decode(Int.self, forKey: .percent)
        self.briefingReady = try container.decodeIfPresent(Bool.self, forKey: .briefingReady)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasBriefing)
    }
}

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
            throw HomeAPIError.decoding
        }
    }

    private func perform(path: String, method: String, body: Data?) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = loopbackPort
        components.path = path
        guard let url = components.url else {
            throw HomeAPIError.network
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HomeAPIError.network
        }
        guard 200..<300 ~= http.statusCode else {
            throw HomeAPIError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}
