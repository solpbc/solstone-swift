// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum VoiceState: Sendable, Equatable {
    case idle
    case connecting
    case listening
    case speaking
    case error(VoiceError)
}
