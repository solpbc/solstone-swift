// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

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

private nonisolated struct ObserverManifestResponse: Decodable {
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

private struct Segment: Decodable {
    let key: String?
    let observed: String?
    let files: [SegmentFile]
    let originalKey: String?

    enum CodingKeys: String, CodingKey {
        case key
        case observed
        case files
        case originalKey = "original_key"
    }
}

private struct SegmentFile: Decodable {
    let name: String?
}

nonisolated struct ObserverManifestClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchToday(localPort: Int, handle: String) async -> ObserverManifestResult {
        let day = Self.dayString(for: Date())
        guard let url = ObserverServerURL.manifestURL(localPort: localPort, day: day) else {
            let log = Logger(subsystem: "app.solstone.swift", category: "observer")
            log.debug("observer manifest unavailable: invalid url")
            return .failed
        }

        var request = ObserverAuthorizedRequest.make(url: url, handle: handle)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let log = Logger(subsystem: "app.solstone.swift", category: "observer")
                log.debug("observer manifest unavailable: non-success response")
                return .failed
            }

            let payload = try JSONDecoder().decode(ObserverManifestResponse.self, from: data)
            let items = payload.segments.map { segment in
                let title = segment.key ?? segment.originalKey ?? "observation"
                let fileCount = segment.files.count
                let subtitle = segment.observed ?? "\(fileCount) file\(fileCount == 1 ? "" : "s")"
                return ObserverManifestItem(id: title, title: title, subtitle: subtitle)
            }
            return items.isEmpty ? .loadedEmpty : .loaded(items)
        } catch {
            let log = Logger(subsystem: "app.solstone.swift", category: "observer")
            log.debug("observer manifest unavailable: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
