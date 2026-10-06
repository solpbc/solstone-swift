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
    let segment: String?
    let stream: String?

    enum CodingKeys: String, CodingKey {
        case key
        case files
        case originalKey = "original_key"
        case segment
        case stream
    }

    init(key: String, files: [LinkedDeviceIngestFile], originalKey: String?, segment: String? = nil, stream: String? = nil) {
        self.key = key
        self.files = files
        self.originalKey = originalKey
        self.segment = segment
        self.stream = stream
    }

    var displayKey: String {
        self.segment ?? self.key
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
    case duplicateListingKey
    case invalidPhysicalIdentity
    case invalidFileMetadata
}

nonisolated struct LinkedDeviceIngestDayManifest: Decodable, Equatable, Sendable {
    let version: Int
    let day: String
    let segments: [String: LinkedDeviceIngestDaySegment]
}

nonisolated struct LinkedDeviceIngestDaySegment: Decodable, Equatable, Sendable {
    let files: [LinkedDeviceIngestFile]

    nonisolated private struct AnyKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        guard container.allKeys.map(\.stringValue) == ["files"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "day manifest entries contain only files"))
        }
        guard let key = AnyKey(stringValue: "files") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing files"))
        }
        self.files = try container.decode([LinkedDeviceIngestFile].self, forKey: key)
    }
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
        if let error = Self.validationError(for: response) { return .failure(error) }
        guard !response.items.contains(where: { segment in
            segment.files.contains { $0.status == .missing }
        }) else {
            return .failure(.missingCustody)
        }
        return .success(response)
    }

    nonisolated static func validPhysicalIdentity(_ item: LinkedDeviceIngestSegment) -> Bool {
        switch (item.segment, item.stream) {
        case (nil, nil):
            // The listing key remains opaque. Legacy basename-only rows have no physical pair.
            return true
        case (.some(let segment), .some(let stream)):
            return Self.isSafePathComponent(segment) && Self.isSafePathComponent(stream)
        case (nil, .some), (.some, nil):
            return false
        }
    }

    nonisolated private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    nonisolated static func validationError(for response: LinkedDeviceIngestSegmentsResponse) -> LinkedDeviceIngestClientError? {
        guard response.protocolVersion == 3, response.total == response.items.count else { return .malformedResponse }
        guard Set(response.items.map(\.key)).count == response.items.count else { return .duplicateListingKey }
        guard response.items.allSatisfy(Self.validPhysicalIdentity) else { return .invalidPhysicalIdentity }
        let physicalIdentities = response.items.compactMap { item -> String? in
            guard let segment = item.segment, let stream = item.stream else { return nil }
            return "\(segment)\u{0}\(stream)"
        }
        guard Set(physicalIdentities).count == physicalIdentities.count else { return .invalidPhysicalIdentity }
        guard response.items.allSatisfy({ $0.files.allSatisfy { $0.size >= 0 } }) else { return .invalidFileMetadata }
        guard !response.items.contains(where: { $0.files.contains { $0.status == .missing } }) else { return .missingCustody }
        return nil
    }

    nonisolated static func decodeDayManifest(_ data: Data, expectedDay: String) -> Result<LinkedDeviceIngestDayManifest, LinkedDeviceIngestClientError> {
        guard let manifest = try? JSONDecoder().decode(LinkedDeviceIngestDayManifest.self, from: data),
              manifest.version == 1,
              manifest.day == expectedDay,
              manifest.segments.keys.allSatisfy({ !$0.isEmpty }) else {
            return .failure(.malformedResponse)
        }
        return .success(manifest)
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
        guard LinkedDeviceIngestClient.validationError(for: response) == nil else { return .failed }
        let items = response.items
            .filter { segment in
                segment.files.contains(where: { $0.name == fileName || $0.submittedName == fileName })
            }
            .sorted {
                if $0.displayKey == $1.displayKey { return $0.key > $1.key }
                return $0.displayKey > $1.displayKey
            }
            .map { segment in
                ObserverManifestItem(
                    id: segment.key,
                    title: self.timeLabel(forSegmentKey: segment.displayKey, day: day, locale: locale, timeZone: timeZone),
                    subtitle: self.durationLabel(forSegmentKey: segment.displayKey) ?? ""
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
        guard LinkedDeviceIngestClient.validationError(for: response) == nil else { return .failed }
        let items = response.items.compactMap { segment -> (String, LocationRecentItem)? in
            guard segment.files.contains(where: { $0.name == "location.jsonl" }) else { return nil }
            return (
                segment.displayKey,
                LocationRecentItem(
                    id: segment.key,
                    timeLabel: self.timeLabel(forSegmentKey: segment.displayKey, day: day, locale: locale, timeZone: timeZone)
                )
            )
        }
        let sorted = items.sorted { $0.0 > $1.0 }.map(\.1)
        return sorted.isEmpty ? .loadedEmpty : .loaded(sorted)
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        SegmentWireTimeFormatter.configure(formatter)
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
