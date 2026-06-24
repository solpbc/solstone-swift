// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

@MainActor
final class WatchSessionDelegate: NSObject, WCSessionDelegate {
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let didActivate = activationState == .activated && error == nil
        Task { @MainActor [weak self] in
            self?.onActivationChanged?(didActivate)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(isReachable)
        }
    }
}
