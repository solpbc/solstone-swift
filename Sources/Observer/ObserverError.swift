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
            "microphone access is required to listen"
        case .audioSessionConflict:
            "audio session changed while listening"
        case .diskFull:
            "storage is full"
        case .uploadFailed:
            "upload failed"
        case .unavailable(let reason):
            reason
        }
    }
}
