// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift

@MainActor
final class MockLocationLiveActivity: LocationLiveActivitying {
    var startCalls: [(tierLabel: String, sessionID: String)] = []
    var updateCalls: [(tierLabel: String, segmentCount: Int)] = []
    var endCallCount = 0

    func start(tierLabel: String, sessionID: String) async {
        self.startCalls.append((tierLabel, sessionID))
    }

    func update(tierLabel: String, segmentCount: Int) async {
        self.updateCalls.append((tierLabel, segmentCount))
    }

    func end() async {
        self.endCallCount += 1
    }
}
