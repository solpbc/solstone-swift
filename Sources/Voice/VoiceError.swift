// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum VoiceError: Error, Sendable, Equatable {
    case microphoneDenied
    case ephemeralKeyFailed(String)
    case connectionFailed(String)
    case sessionEnded

    var userMessage: String {
        switch self {
        case .microphoneDenied:
            return "microphone access is required for voice conversations — enable it in Settings"
        case .ephemeralKeyFailed(let detail):
            if UserSettings.verboseErrors {
                return "unable to start voice session — \(detail)"
            }
            return "unable to start voice session"
        case .connectionFailed(let detail):
            if UserSettings.verboseErrors {
                return "voice connection failed — \(detail)"
            }
            return "voice connection failed"
        case .sessionEnded:
            return "voice session ended unexpectedly"
        }
    }
}
