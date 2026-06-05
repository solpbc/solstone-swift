// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum SolstoneDeepLink: Equatable {
    case observerStop
    case locationPause

    nonisolated static func parse(_ url: URL) -> SolstoneDeepLink? {
        guard url.scheme == "solstone" else { return nil }

        switch (url.host, url.path) {
        case ("observer", "/stop"):
            return .observerStop
        case ("location", "/pause"):
            return .locationPause
        default:
            return nil
        }
    }
}
