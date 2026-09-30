// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class PairFlowPresence {
    var count: Int = 0

    var isPresent: Bool {
        count > 0
    }

    func increment() {
        count += 1
    }

    func decrement() {
        count = max(0, count - 1)
    }
}
