// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity

@MainActor
final class MockWatchConnectivitySession: WatchConnectivitySession {
    var isSupported = true
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var activationState: WCSessionActivationState = .notActivated
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onWatchStateChanged: (@Sendable () -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?

    var activateCallCount = 0
    var transferredFiles: [(URL, [String: Any])] = []
    var transferredUserInfos: [[String: Any]] = []
    var sentMessages: [[String: Any]] = []

    func activate() {
        self.activateCallCount += 1
        self.activationState = .activated
        self.onActivationChanged?(true)
    }

    func transferFile(_ url: URL, metadata: [String: Any]) {
        self.transferredFiles.append((url, metadata))
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        self.transferredUserInfos.append(userInfo)
    }

    func sendMessage(_ message: [String: Any]) {
        self.sentMessages.append(message)
    }

    func emitReachability(_ isReachable: Bool) {
        self.isReachable = isReachable
        self.onReachabilityChanged?(isReachable)
    }

    func emitWatchState(
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        activationState: WCSessionActivationState
    ) {
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
        self.activationState = activationState
        self.onWatchStateChanged?()
    }

    func deliverFile(_ url: URL, metadata: [String: Any]) {
        self.onReceiveFile?(url, metadata)
    }

    func deliverUserInfo(_ userInfo: [String: Any]) {
        self.onReceiveUserInfo?(userInfo)
    }
}
