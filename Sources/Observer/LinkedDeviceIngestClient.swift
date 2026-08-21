// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let ingestReadLog = Logger(subsystem: "app.solstone.swift", category: "ingest-read")

nonisolated enum LinkedDeviceIngestCustody: String, Decodable, Equatable, Sendable {
    case missing
    case processed
    case present
}

nonisolated struct LinkedDeviceIngestFile: Decodable, Equatable, Sendable {
    let name: String
    let size: Int
    let sha256: String
    let status: LinkedDeviceIngestCustody
    let submittedName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case sha256
        case status
        case submittedName = "submitted_name"
    }
}

nonisolated struct LinkedDeviceIngestSegment: Decodable, Equatable, Sendable {
    let key: String
    let observed: Bool
    let files: [LinkedDeviceIngestFile]
    let originalKey: String?

    enum CodingKeys: String, CodingKey {
        case key
        case observed
        case files
        case originalKey = "original_key"
    }
}

nonisolated struct LinkedDeviceIngestDaysResponse: Decodable, Equatable, Sendable {
    let days: [String: LinkedDeviceIngestDaySummary]
}

nonisolated struct LinkedDeviceIngestDaySummary: Decodable, Equatable, Sendable {
    let segments: Int?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case segments
        case error
    }

    init(segments: Int?, error: String?) {
        self.segments = segments
        self.error = error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.segments = try container.decodeIfPresent(Int.self, forKey: .segments)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        guard (self.segments == nil) != (self.error == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .segments, in: container, debugDescription: "expected segments or error")
        }
    }
}

nonisolated struct LinkedDeviceIngestManifestDayResponse: Decodable, Equatable, Sendable {
    let version: Int
    let day: String
    let segments: [String: LinkedDeviceIngestManifestSegment]
}

nonisolated struct LinkedDeviceIngestManifestSegment: Decodable, Equatable, Sendable {
    let files: [LinkedDeviceIngestFile]
}

nonisolated struct LinkedDeviceIngestSegmentsResponse: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let total: Int
    let items: [LinkedDeviceIngestSegment]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case total
        case items
    }
}

nonisolated enum LinkedDeviceIngestClientError: Error, Equatable, Sendable {
    case invalidURL
    case httpStatus(Int)
    case malformedResponse
    case dayError(day: String, reason: String)
    case missingCustody
}

nonisolated struct LinkedDeviceIngestClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listDays(localPort: Int, source: String) async -> Result<LinkedDeviceIngestDaysResponse, LinkedDeviceIngestClientError> {
        guard let url = ObserverServerURL.manifestURL(localPort: localPort, source: source) else {
            return .failure(.invalidURL)
        }
        let result: Result<LinkedDeviceIngestDaysResponse, LinkedDeviceIngestClientError> = await self.fetch(url: url)
        guard case .success(let response) = result else { return result }
        if let failure = response.days.first(where: { $0.value.error != nil }) {
            return .failure(.dayError(day: failure.key, reason: failure.value.error!))
        }
        return .success(response)
    }

    func fetchManifestDay(
        localPort: Int,
        source: String,
        day: String
    ) async -> Result<LinkedDeviceIngestManifestDayResponse, LinkedDeviceIngestClientError> {
        guard let url = ObserverServerURL.manifestDayURL(localPort: localPort, source: source, day: day) else {
            return .failure(.invalidURL)
        }
        let result: Result<LinkedDeviceIngestManifestDayResponse, LinkedDeviceIngestClientError> = await self.fetch(url: url)
        guard case .success(let response) = result else { return result }
        guard response.version == 1, response.day == day else {
            return .failure(.malformedResponse)
        }
        return self.validatingCustody(response)
    }

    func fetchSegments(
        localPort: Int,
        source: String,
        day: String
    ) async -> Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError> {
        guard let url = ObserverServerURL.segmentsURL(localPort: localPort, source: source, day: day) else {
            return .failure(.invalidURL)
        }
        let result: Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError> = await self.fetch(url: url)
        guard case .success(let response) = result else { return result }
        guard response.protocolVersion == 3, response.total == response.items.count else {
            return .failure(.malformedResponse)
        }
        guard !response.items.contains(where: { segment in
            segment.files.contains { $0.status == .missing }
        }) else {
            return .failure(.missingCustody)
        }
        return .success(response)
    }

    private func fetch<Response: Decodable>(url: URL) async -> Result<Response, LinkedDeviceIngestClientError> {
        var request = URLRequest(url: url)
        request.setValue(
            ObserverServerURL.ingestProtocolVersion,
            forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName
        )
        request.timeoutInterval = 5

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failure(.malformedResponse)
            }
            guard 200..<300 ~= response.statusCode else {
                return .failure(.httpStatus(response.statusCode))
            }
            guard !data.isEmpty else {
                return .failure(.malformedResponse)
            }
            do {
                return .success(try JSONDecoder().decode(Response.self, from: data))
            } catch {
                ingestReadLog.debug("ingest read decode failed: \(String(describing: error), privacy: .public)")
                return .failure(.malformedResponse)
            }
        } catch {
            ingestReadLog.debug("ingest read failed: \(String(describing: error), privacy: .public)")
            return .failure(.malformedResponse)
        }
    }

    private func validatingCustody(
        _ response: LinkedDeviceIngestManifestDayResponse
    ) -> Result<LinkedDeviceIngestManifestDayResponse, LinkedDeviceIngestClientError> {
        guard !response.segments.values.contains(where: { segment in
            segment.files.contains { $0.status == .missing }
        }) else {
            return .failure(.missingCustody)
        }
        return .success(response)
    }
}

nonisolated struct ObserverManifestItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
}

nonisolated enum ObserverManifestResult: Equatable, Sendable {
    case loaded([ObserverManifestItem])
    case loadedEmpty
    case failed
}

nonisolated struct LocationRecentItem: Identifiable, Equatable, Sendable {
    let id: String
    let timeLabel: String
}

nonisolated enum LocationRecentResult: Equatable, Sendable {
    case loaded([LocationRecentItem])
    case loadedEmpty
    case failed
}

nonisolated enum LinkedDeviceIngestViewMapper {
    static func observerManifestResult(
        _ result: Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError>
    ) -> ObserverManifestResult {
        guard case .success(let response) = result else { return .failed }
        let items = response.items.map { segment in
            ObserverManifestItem(
                id: segment.key,
                title: segment.key,
                subtitle: "\(segment.files.count) file\(segment.files.count == 1 ? "" : "s")"
            )
        }
        return items.isEmpty ? .loadedEmpty : .loaded(items)
    }

    static func locationRecentResult(
        _ result: Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError>,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> LocationRecentResult {
        guard case .success(let response) = result else { return .failed }
        let items = response.items.compactMap { segment -> (String, LocationRecentItem)? in
            guard segment.files.contains(where: { $0.name == "location.jsonl" }) else { return nil }
            return (
                segment.key,
                LocationRecentItem(
                    id: segment.key,
                    timeLabel: self.timeLabel(forSegmentKey: segment.key, locale: locale, timeZone: timeZone)
                )
            )
        }
        let sorted = items.sorted { $0.0 > $1.0 }.map(\.1)
        return sorted.isEmpty ? .loadedEmpty : .loaded(sorted)
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func timeLabel(
        forSegmentKey segmentKey: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let separator = segmentKey.firstIndex(of: "_") else { return segmentKey }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyyMMdd-HHmmss"
        guard let date = parser.date(from: String(segmentKey[..<separator])) else { return segmentKey }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
