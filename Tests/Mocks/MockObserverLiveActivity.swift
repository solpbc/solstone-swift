// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockObserverLiveActivity: ObserverLiveActivitying {
    var startDelay: Duration?
    var startCalls: [(ObserverMode, UUID, Date)] = []
    var endCalls: [UUID] = []
    var endAllCallCount = 0

    func start(mode: ObserverMode, sessionID: UUID, startedAt: Date) async {
        self.startCalls.append((mode, sessionID, startedAt))
        if let startDelay {
            try? await Task.sleep(for: startDelay)
        }
    }

    func end(sessionID: UUID) async {
        self.endCalls.append(sessionID)
    }

    func endAll() async {
        self.endAllCallCount += 1
    }
}
