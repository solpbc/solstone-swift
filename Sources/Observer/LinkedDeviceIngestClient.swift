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
    let files: [LinkedDeviceIngestFile]
    let originalKey: String?

    enum CodingKeys: String, CodingKey {
        case key
        case files
        case originalKey = "original_key"
    }
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
    case missingCustody
}

nonisolated struct LinkedDeviceIngestClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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

    func deleteSource(
        localPort: Int,
        source: String
    ) async -> Result<DeleteSourceReceipt?, LinkedDeviceIngestClientError> {
        guard let url = ObserverServerURL.deleteSourceURL(localPort: localPort, source: source) else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        request.attachLoopbackCapability()

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failure(.malformedResponse)
            }
            guard 200..<300 ~= response.statusCode else {
                return .failure(.httpStatus(response.statusCode))
            }
            guard !data.isEmpty,
                  let receipt = try? JSONDecoder().decode(DeleteSourceReceipt.self, from: data)
            else {
                return .success(nil)
            }
            return .success(receipt)
        } catch {
            ingestReadLog.debug("ingest delete failed: \(String(describing: error), privacy: .public)")
            return .failure(.malformedResponse)
        }
    }

    private func fetch<Response: Decodable>(url: URL) async -> Result<Response, LinkedDeviceIngestClientError> {
        var request = URLRequest(url: url)
        request.setValue(
            ObserverServerURL.ingestProtocolVersion,
            forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName
        )
        request.timeoutInterval = 5
        request.attachLoopbackCapability()

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
}

nonisolated struct ObserverManifestItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
}

/// `unavailable` means no journal connection was up, so nothing was asked. It is not a failure:
/// an unpaired phone, or one whose journal is out of reach, has nothing to load.
nonisolated enum ObserverManifestResult: Equatable, Sendable {
    case loaded([ObserverManifestItem])
    case loadedEmpty
    case unavailable
    case failed
}

nonisolated struct LocationRecentItem: Identifiable, Equatable, Sendable {
    let id: String
    let timeLabel: String
}

nonisolated enum LocationRecentResult: Equatable, Sendable {
    case loaded([LocationRecentItem])
    case loadedEmpty
    case unavailable
    case failed
}

nonisolated enum LinkedDeviceIngestViewMapper {
    /// One source's segments from the shared `mobile-segment` stream, newest first. A segment
    /// belongs to the source whose file it carries, so audio never lists a location-only segment.
    static func observerManifestResult(
        _ result: Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError>,
        day: String,
        fileName: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> ObserverManifestResult {
        guard case .success(let response) = result else { return .failed }
        let items = response.items
            .filter { segment in
                segment.files.contains(where: { $0.name == fileName || $0.submittedName == fileName })
            }
            .sorted { $0.key > $1.key }
            .map { segment in
                ObserverManifestItem(
                    id: segment.key,
                    title: self.timeLabel(forSegmentKey: segment.key, day: day, locale: locale, timeZone: timeZone),
                    subtitle: self.durationLabel(forSegmentKey: segment.key) ?? ""
                )
            }
        return items.isEmpty ? .loadedEmpty : .loaded(items)
    }

    static func locationRecentResult(
        _ result: Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError>,
        day: String,
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
                    timeLabel: self.timeLabel(forSegmentKey: segment.key, day: day, locale: locale, timeZone: timeZone)
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

    /// A segment key is `HHmmss_<seconds>` within its `yyyyMMdd` day, for example `140535_3`.
    static func segmentStart(forSegmentKey segmentKey: String, day: String, timeZone: TimeZone = .current) -> Date? {
        guard let separator = segmentKey.firstIndex(of: "_") else { return nil }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyyMMddHHmmss"
        return parser.date(from: day + segmentKey[..<separator])
    }

    static func durationLabel(forSegmentKey segmentKey: String) -> String? {
        guard let separator = segmentKey.firstIndex(of: "_"),
              let seconds = Int(segmentKey[segmentKey.index(after: separator)...])
        else { return nil }
        return OnThisPhoneItem.formattedDuration(TimeInterval(seconds))
    }

    static func timeLabel(
        forSegmentKey segmentKey: String,
        day: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = self.segmentStart(forSegmentKey: segmentKey, day: day, timeZone: timeZone) else {
            return segmentKey
        }
        return OnThisPhoneItemDetailPresentation.shortTimeLabel(for: date, locale: locale, timeZone: timeZone)
    }
}
