// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum TunnelError: Error, Sendable, Equatable {
    case networkUnreachable
    case connectionRefused
    case connectionTimeout
    case authenticationFailed
    case hostKeyMismatch
    case tunnelClosed
    case hubPhoneStartFailed(String)
    case unknown(String)

    var userMessage: String {
        switch self {
        case .networkUnreachable:
            return "unable to reach the server"
        case .connectionRefused:
            return "server refused the connection"
        case .connectionTimeout:
            return "connection timed out"
        case .authenticationFailed:
            return "authentication failed — check your SSH key"
        case .hostKeyMismatch:
            return "server identity has changed since last connection"
        case .tunnelClosed:
            return "connection lost"
        case .hubPhoneStartFailed:
            return "hub-phone failed to start"
        case .unknown(let detail):
            if UserSettings.verboseErrors {
                return "connection failed — \(detail)"
            }
            return "connection failed"
        }
    }

    var iconName: String {
        switch self {
        case .networkUnreachable:
            return "wifi.slash"
        case .connectionRefused:
            return "server.rack"
        case .connectionTimeout:
            return "clock.badge.xmark"
        case .authenticationFailed:
            return "key.slash"
        case .hostKeyMismatch:
            return "exclamationmark.shield"
        case .tunnelClosed:
            return "bolt.horizontal.circle"
        case .hubPhoneStartFailed:
            return "server.rack"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .hostKeyMismatch, .authenticationFailed:
            return false
        case .networkUnreachable, .connectionRefused, .connectionTimeout, .tunnelClosed, .hubPhoneStartFailed, .unknown:
            return true
        }
    }
}
