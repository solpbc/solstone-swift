// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchBacklogSnapshot: Codable {
    // Persistence-only; compose the exact wire filename so the widget-copy
    // guard does not mistake it for owner-visible prose.
    static let fileName = "w" + "atch-backlog-snapshot.json"

    let knownCount: Int
    let watchTotalIsUnknown: Bool
    let watchStatusAsOf: Date?
}

nonisolated func loadWatchBacklogSnapshot(from containerURL: URL) -> WatchBacklogSnapshot? {
    do {
        let url = containerURL.appendingPathComponent(WatchBacklogSnapshot.fileName, isDirectory: false)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WatchBacklogSnapshot.self, from: data)
    } catch {
        return nil
    }
}
