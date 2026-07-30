// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let connectionSyncLog = Logger(subsystem: "app.solstone.swift", category: "connection-sync")

@MainActor
@Observable
final class ConnectionSyncModel {
    private(set) var status: ConnectionSyncStatus

    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let debounceInterval: Duration
    @ObservationIgnored private let pollCadence: Duration
    @ObservationIgnored private let sample: @MainActor () -> ConnectionSyncInputs
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var publishGeneration: UInt64 = 0

    init(
        clock: any ObserverClock,
        debounceInterval: Duration = .seconds(1.5),
        pollCadence: Duration = .seconds(1),
        sample: @escaping @MainActor () -> ConnectionSyncInputs
    ) {
        self.clock = clock
        self.debounceInterval = debounceInterval
        self.pollCadence = pollCadence
        self.sample = sample
        self.status = ConnectionSyncStatus.derive(sample())
    }

    func run() async {
        guard !self.isRunning else { return }
        self.isRunning = true
        defer { self.isRunning = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.pollInputChanges()
            }
            group.addTask { [weak self] in
                await self?.observeInputChanges()
            }
            await group.waitForAll()
        }
    }

    func refreshNow() {
        let raw = ConnectionSyncStatus.derive(self.sample())
        self.publish(raw, verb: "refreshed")
    }

    func refreshFromInputChange() {
        let inputs = self.sample()
        let derived = ConnectionSyncStatus.derive(inputs)
        guard derived != self.status else { return }
        guard self.shouldPublishImmediately(inputs: inputs, derived: derived) else { return }
        self.publish(derived, verb: "changed")
    }

    private func pollInputChanges() async {
        while !Task.isCancelled {
            try? await self.clock.sleep(for: self.pollCadence)
            guard !Task.isCancelled else { return }

            let inputs = self.sample()
            let raw = ConnectionSyncStatus.derive(inputs)
            guard raw != self.status else { continue }

            if self.shouldPublishImmediately(inputs: inputs, derived: raw) {
                self.publish(raw, verb: "changed")
                continue
            }

            let generation = self.publishGeneration
            try? await self.clock.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            guard generation == self.publishGeneration else { continue }

            let confirmed = ConnectionSyncStatus.derive(self.sample())
            guard confirmed == raw, confirmed != self.status else { continue }

            self.publish(confirmed, verb: "changed")
        }
    }

    private func observeInputChanges() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.installInputTracking(yielding: continuation)

        for await _ in stream {
            self.installInputTracking(yielding: continuation)
            self.refreshFromInputChange()
        }
    }

    private func installInputTracking(yielding continuation: AsyncStream<Void>.Continuation) {
        withObservationTracking {
            _ = self.sample()
        } onChange: {
            continuation.yield()
        }
    }

    private func shouldPublishImmediately(
        inputs: ConnectionSyncInputs,
        derived: ConnectionSyncStatus
    ) -> Bool {
        let publishedReachable = isJournalReachable(self.status)
        let derivedReachable = isJournalReachable(derived)

        if publishedReachable, !derivedReachable {
            return !ConnectionSyncStatus.isNetworkBlipWhileTunnelConnected(
                inputs: inputs,
                derived: derived
            )
        }

        if publishedReachable, derivedReachable {
            return true
        }

        return false
    }

    private func publish(_ next: ConnectionSyncStatus, verb: String) {
        guard next != self.status else { return }
        let previous = self.status
        self.status = next
        self.publishGeneration &+= 1
        connectionSyncLog.debug("connection sync status \(verb, privacy: .public) \(previous.statusLine, privacy: .public) -> \(next.statusLine, privacy: .public)")
    }

#if DEBUG && targetEnvironment(simulator)
    func integrationGateCurrentInputs() -> ConnectionSyncInputs {
        self.sample()
    }
#endif
}
