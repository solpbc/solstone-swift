// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchAwareBacklog: Equatable, Sendable {
    case known(Int)
    case partiallyUnknown(known: Int, asOf: Date?)

    nonisolated var knownCount: Int {
        switch self {
        case .known(let count), .partiallyUnknown(let count, _):
            count
        }
    }
}

nonisolated func watchAwareBacklog(
    phoneLocalCount: Int,
    session: WatchSessionReadiness,
    waiting: WatchSideWaiting
) -> WatchAwareBacklog {
    let phoneLocalCount = max(0, phoneLocalCount)
    guard case .activated(.installedActive) = session else {
        return .known(phoneLocalCount)
    }

    switch waiting {
    case .reported(let count, .fresh):
        return .known(phoneLocalCount + max(0, count))
    case .reported(_, .stale(let asOf, _)):
        return .partiallyUnknown(known: phoneLocalCount, asOf: asOf)
    case .unknown:
        return .partiallyUnknown(known: phoneLocalCount, asOf: nil)
    }
}
