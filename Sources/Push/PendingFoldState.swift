// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation

@MainActor
@Observable
final class PendingFoldState {
    var useID: String?

    func markPending(_ useID: String) {
        self.useID = useID
    }

    func markShown(_ useID: String) {
        if self.useID == useID {
            self.useID = nil
        }
    }
}
