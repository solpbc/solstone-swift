// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum TunnelError: Error, Sendable, Equatable {
    case revoked
    /// The journal kept refusing this device until the credential stopped. Presented as
    /// `revoked`, but the pairing is kept: only a new pairing ends the stop.
    case refusalsExhausted
    case tlsHandshakeFailed
    case muxTeardown
    case unreachable
    case unknown(String)

    var userMessage: String {
        switch self {
        case .revoked, .refusalsExhausted:
            return AppStrings.ios_app_repairline()
        case .tlsHandshakeFailed:
            return AppStrings.ios_tunnel_usermessage4()
        case .muxTeardown:
            return AppStrings.ios_tunnel_usermessage3()
        case .unreachable:
            return AppStrings.ios_tunnel_usermessage()
        case .unknown(let detail):
            if UserSettings.verboseErrors {
                return AppStrings.ios_tunnel_usermessage2("\(detail)")
            }
            return AppStrings.ios_tunnel_connectionfailed()
        }
    }

    var iconName: String {
        switch self {
        case .revoked, .refusalsExhausted:
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
        case .revoked, .refusalsExhausted:
            return false
        case .unreachable, .tlsHandshakeFailed, .muxTeardown, .unknown:
            return true
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .revoked:
            return AppStrings.ios_tunnel_diagnosticlabel()
        case .refusalsExhausted:
            return "refusalsExhausted"
        case .tlsHandshakeFailed:
            return "tlsHandshakeFailed"
        case .muxTeardown:
            return "muxTeardown"
        case .unreachable:
            return AppStrings.ios_integrationgate_unreachable()
        case .unknown:
            return AppStrings.ios_tunnel_diagnosticlabel2()
        }
    }
}
