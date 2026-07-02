// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockObserverClock: ObserverClock {
    private var currentDate: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = []

    init(now: Date = Date(timeIntervalSince1970: 1_713_624_000)) {
        self.currentDate = now
    }

    var pendingSleeperCount: Int {
        self.sleepers.count
    }

    func now() -> Date {
        self.currentDate
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let nanoseconds = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
            let deadline = self.currentDate.addingTimeInterval(TimeInterval(nanoseconds) / 1_000_000_000)
            self.sleepers.append((deadline, continuation))
        }
    }

    func advance(by seconds: TimeInterval) {
        self.currentDate.addTimeInterval(seconds)
        let ready = self.sleepers.enumerated().filter { $0.element.deadline <= self.currentDate }
        for (index, sleeper) in ready.reversed() {
            self.sleepers.remove(at: index)
            sleeper.continuation.resume()
        }
    }
}
