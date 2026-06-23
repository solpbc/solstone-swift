// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private nonisolated let locationRecentLog = Logger(subsystem: "app.solstone.swift", category: "location-recent")

nonisolated struct LocationRecentItem: Identifiable, Equatable, Sendable {
    let id: String
    let timeLabel: String
}

nonisolated enum LocationRecentResult: Equatable, Sendable {
    case loaded([LocationRecentItem])
    case loadedEmpty
    case failed
}

nonisolated protocol LocationRecentProviding: Sendable {
    func fetchToday(localPort: Int, handle: String) async -> LocationRecentResult
}

nonisolated struct LocationRecentSource: LocationRecentProviding {
    private let session: URLSession
    private let locale: Locale
    private let timeZone: TimeZone

    init(session: URLSession = .shared, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.session = session
        self.locale = locale
        self.timeZone = timeZone
    }

    func fetchToday(localPort: Int, handle: String) async -> LocationRecentResult {
        let day = Self.dayString(for: Date())
        guard let url = ObserverServerURL.segmentsURL(localPort: localPort, day: day) else {
            locationRecentLog.debug("location recent unavailable: invalid url")
            return .failed
        }

        var request = ObserverAuthorizedRequest.make(url: url, handle: handle)
        request.setValue(
            ObserverServerURL.segmentsProtocolVersion,
            forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName
        )
        request.timeoutInterval = 5

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                locationRecentLog.debug("location recent unavailable: non-success response")
                return .failed
            }

            let payload = try JSONDecoder().decode(ManifestResponse.self, from: data)
            var locationItems: [(sortKey: String, item: LocationRecentItem)] = []
            for segment in payload.items {
                if let item = self.locationItem(from: segment) {
                    locationItems.append(item)
                }
            }
            let items = locationItems
                .sorted { $0.sortKey > $1.sortKey }
                .map(\.item)
            return items.isEmpty ? .loadedEmpty : .loaded(items)
        } catch {
            locationRecentLog.debug("location recent unavailable: \(String(describing: error), privacy: .public)")
            return .failed
        }
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
        guard let date = Self.date(forSegmentKey: segmentKey, timeZone: timeZone) else {
            return segmentKey
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func date(forSegmentKey segmentKey: String, timeZone: TimeZone = .current) -> Date? {
        guard let separator = segmentKey.firstIndex(of: "_") else {
            return nil
        }

        let stem = String(segmentKey[..<separator])
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyyMMdd-HHmmss"
        return parser.date(from: stem)
    }
}

private extension LocationRecentSource {
    nonisolated struct ManifestResponse: Decodable {
        let items: [SegmentItem]

        init(from decoder: any Decoder) throws {
            if let singleValue = try? decoder.singleValueContainer(),
               let items = try? singleValue.decode([SegmentItem].self)
            {
                self.items = items
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.items = try container.decode([SegmentItem].self, forKey: .items)
        }

        private enum CodingKeys: String, CodingKey {
            case items
        }
    }

    nonisolated struct SegmentItem: Decodable {
        let key: String
        let observed: Bool?
        let files: [SegmentFile]
        let originalKey: String?

        enum CodingKeys: String, CodingKey {
            case key
            case observed
            case files
            case originalKey = "original_key"
        }
    }

    nonisolated struct SegmentFile: Decodable {
        let name: String?
    }

    func locationItem(from segment: SegmentItem) -> (sortKey: String, item: LocationRecentItem)? {
        guard segment.files.contains(where: { $0.name == "location.jsonl" }) else {
            return nil
        }

        return (
            sortKey: segment.key,
            item: LocationRecentItem(
                id: segment.key,
                timeLabel: Self.timeLabel(
                    forSegmentKey: segment.key,
                    locale: self.locale,
                    timeZone: self.timeZone
                )
            )
        )
    }
}
