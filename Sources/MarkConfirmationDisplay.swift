// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum MarkConfirmationDisplay {
    static func showsAwaitingWords(
        awaitingMarkConfirmation: Bool,
        status: ConnectionSyncStatus,
        isStalled: Bool
    ) -> Bool {
        guard awaitingMarkConfirmation, !isStalled else { return false }
        switch status {
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            return true
        case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
            return false
        }
    }
}
