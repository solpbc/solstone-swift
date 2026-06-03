// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation

enum LocationCommand: Equatable, Sendable {
    case pauseRequested
}

@Observable
final class PendingLocationCommandState {
    var command: LocationCommand?
}
