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
    func fetchToday(localPort: Int, key: String) async -> LocationRecentResult
}

nonisolated struct LocationRecentSource: LocationRecentProviding {
    private static let locationPrefix = "location/"

    private let session: URLSession
    private let locale: Locale
    private let timeZone: TimeZone

    init(session: URLSession = .shared, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.session = session
        self.locale = locale
        self.timeZone = timeZone
    }

    func fetchToday(localPort: Int, key: String) async -> LocationRecentResult {
        let day = Self.dayString(for: Date())
        guard let url = ObserverServerURL.manifestURL(localPort: localPort, key: key, day: day) else {
            locationRecentLog.debug("location recent unavailable: invalid url")
            return .failed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                locationRecentLog.debug("location recent unavailable: non-success response")
                return .failed
            }

            let payload = try JSONDecoder().decode(ManifestResponse.self, from: data)
            var locationItems: [(sortKey: String, item: LocationRecentItem)] = []
            for segment in payload.segments {
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
        let segments: [Segment]

        init(from decoder: any Decoder) throws {
            if let singleValue = try? decoder.singleValueContainer(),
               let segments = try? singleValue.decode([Segment].self)
            {
                self.segments = segments
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case segments
        }
    }

    nonisolated struct Segment: Decodable {
        let key: String?
        let observed: String?
        let files: [SegmentFile]?
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

    func locationItem(from segment: Segment) -> (sortKey: String, item: LocationRecentItem)? {
        guard let fullKey = segment.key ?? segment.originalKey,
              fullKey.hasPrefix(Self.locationPrefix)
        else {
            return nil
        }

        let strippedKey = String(fullKey.dropFirst(Self.locationPrefix.count))
        return (
            sortKey: strippedKey,
            item: LocationRecentItem(
                id: fullKey,
                timeLabel: Self.timeLabel(
                    forSegmentKey: strippedKey,
                    locale: self.locale,
                    timeZone: self.timeZone
                )
            )
        )
    }
}
