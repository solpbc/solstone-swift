// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

// Decision: the complication loader turns every failure into nil. A corrupt
// snapshot and a genuine first-run absence both render the question mark forever
// with no signal anywhere. That is very likely right for a watch face, and this change
// preserves that behavior.
nonisolated func loadWatchComplicationSnapshot(from containerURL: URL) -> WatchComplicationSnapshot? {
    do {
        let url = containerURL.appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
    } catch {
        return nil
    }
}
