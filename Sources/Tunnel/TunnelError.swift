// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum TunnelError: Error, Sendable, Equatable {
    case revoked
    case tlsHandshakeFailed
    case muxTeardown
    case unreachable
    case unknown(String)

    var userMessage: String {
        switch self {
        case .revoked:
            return "your journal asked this phone to reconnect."
        case .tlsHandshakeFailed:
            return "couldn't verify this solstone."
        case .muxTeardown:
            return "connection lost."
        case .unreachable:
            return "can't reach this solstone right now."
        case .unknown(let detail):
            if UserSettings.verboseErrors {
                return "connection failed — \(detail)"
            }
            return "connection failed"
        }
    }

    var iconName: String {
        switch self {
        case .revoked:
            return "person.crop.circle.badge.xmark"
        case .tlsHandshakeFailed:
            return "exclamationmark.shield"
        case .muxTeardown:
            return "bolt.horizontal.circle"
        case .unreachable:
            return "wifi.slash"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .revoked:
            return false
        case .unreachable, .tlsHandshakeFailed, .muxTeardown, .unknown:
            return true
        }
    }
}
