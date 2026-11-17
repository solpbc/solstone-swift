// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ObserverError: Error, Equatable, Sendable {
    case permissionDenied
    case audioSessionConflict
    case diskFull
    case uploadFailed(chunkID: String)
    case unavailable(reason: String)

    var message: String {
        switch self {
        case .permissionDenied:
            AppStrings.ios_observer_message2()
        case .audioSessionConflict:
            AppStrings.ios_observer_message()
        case .diskFull:
            AppStrings.ios_observer_message3()
        case .uploadFailed:
            AppStrings.ios_observer_message5()
        case .unavailable(let reason):
            reason
        }
    }
}
