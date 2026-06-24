// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockWatchConnectivitySession: WatchConnectivitySession {
    var isSupported = true
    var isReachable = false
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?

    var activateCallCount = 0

    func activate() {
        self.activateCallCount += 1
        self.onActivationChanged?(true)
    }

    func emitReachability(_ isReachable: Bool) {
        self.isReachable = isReachable
        self.onReachabilityChanged?(isReachable)
    }
}
