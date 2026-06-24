// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

@MainActor
protocol WatchConnectivitySession: AnyObject {
    var isSupported: Bool { get }
    var isReachable: Bool { get }
    var onActivationChanged: (@Sendable (Bool) -> Void)? { get set }
    var onReachabilityChanged: (@Sendable (Bool) -> Void)? { get set }

    func activate()
}

@MainActor
final class LiveWatchConnectivitySession: NSObject, WatchConnectivitySession, WCSessionDelegate {
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?

    private let session: WCSession?

    var isSupported: Bool {
        self.session != nil
    }

    var isReachable: Bool {
        self.session?.isReachable ?? false
    }

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        self.session?.delegate = self
    }

    func activate() {
        guard let session else {
            self.onActivationChanged?(false)
            return
        }
        session.delegate = self
        session.activate()
    }

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

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.onActivationChanged?(false)
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(isReachable)
        }
    }
}
