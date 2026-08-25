// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if os(iOS)
import Foundation
import Observation
import os

private let watchBacklogSnapshotLog = Logger(
    subsystem: "app.solstone.swift",
    category: "watch-backlog-snapshot"
)

nonisolated struct WatchBacklogSnapshotPayload: Codable, Equatable, Sendable {
    static let fileName = "watch-backlog-snapshot.json"

    let knownCount: Int
    let watchTotalIsUnknown: Bool
    let watchStatusAsOf: Date?

    init(backlog: WatchAwareBacklog, watchStatusAsOf: Date?) {
        switch backlog {
        case .known(let count):
            self.knownCount = count
            self.watchTotalIsUnknown = false
            self.watchStatusAsOf = watchStatusAsOf
        case .partiallyUnknown(let known, let asOf):
            self.knownCount = known
            self.watchTotalIsUnknown = true
            self.watchStatusAsOf = asOf ?? watchStatusAsOf
        }
    }
}

@MainActor
@Observable
final class WatchBacklogSnapshotWriter {
    @ObservationIgnored private let rootURLProvider: @Sendable () throws -> URL

    init(rootURLProvider: @escaping @Sendable () throws -> URL = { try AppGroupContainer.rootURL() }) {
        self.rootURLProvider = rootURLProvider
    }

    @discardableResult
    func write(backlog: WatchAwareBacklog, watchStatusAsOf: Date?) -> Bool {
        do {
            let payload = WatchBacklogSnapshotPayload(
                backlog: backlog,
                watchStatusAsOf: watchStatusAsOf
            )
            let data = try Self.makeEncoder().encode(payload)
            let url = try self.rootURLProvider()
                .appendingPathComponent(WatchBacklogSnapshotPayload.fileName, isDirectory: false)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            watchBacklogSnapshotLog.error(
                "watch backlog snapshot write failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }
}
#endif
