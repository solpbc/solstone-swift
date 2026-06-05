// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockObserverLiveActivity: ObserverLiveActivitying {
    var startCalls: [(ObserverMode, UUID, TimeInterval)] = []
    var updateCalls: [(ObserverMode, TimeInterval)] = []
    var endCalls: [(ObserverMode, TimeInterval)] = []
    var endAllCallCount = 0

    func start(mode: ObserverMode, sessionID: UUID, elapsed: TimeInterval) async {
        self.startCalls.append((mode, sessionID, elapsed))
    }

    func update(mode: ObserverMode, elapsed: TimeInterval) async {
        self.updateCalls.append((mode, elapsed))
    }

    func end(mode: ObserverMode, elapsed: TimeInterval) async {
        self.endCalls.append((mode, elapsed))
    }

    func endAll() async {
        self.endAllCallCount += 1
    }
}
