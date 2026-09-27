// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class ManualConnectionStallClock: ConnectionStallClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var now: Date
    private var sleepers: [Sleeper] = []

    init(now: Date = Date()) {
        self.now = now
    }

    var pendingSleeperCount: Int {
        self.sleepers.count
    }

    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        let deadline = self.now.addingTimeInterval(seconds)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= self.now {
                    continuation.resume()
                    return
                }
                self.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let index = self.sleepers.firstIndex(where: { $0.id == id }) {
                    let sleeper = self.sleepers.remove(at: index)
                    sleeper.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func advance(by duration: Duration) async {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        self.now = self.now.addingTimeInterval(seconds)
        let ready = self.sleepers.filter { $0.deadline <= self.now }
        self.sleepers.removeAll { $0.deadline <= self.now }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }

    func setNow(_ date: Date) async {
        self.now = date
        let ready = self.sleepers.filter { $0.deadline <= self.now }
        self.sleepers.removeAll { $0.deadline <= self.now }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
