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

        while !Task.isCancelled {
            try? await self.clock.sleep(for: self.pollCadence)
            guard !Task.isCancelled else { return }

            let raw = ConnectionSyncStatus.derive(self.sample())
            guard raw != self.status else { continue }

            try? await self.clock.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            let confirmed = ConnectionSyncStatus.derive(self.sample())
            guard confirmed == raw, confirmed != self.status else { continue }

            let previous = self.status
            self.status = confirmed
            connectionSyncLog.debug("connection sync status changed \(previous.statusLine, privacy: .public) -> \(confirmed.statusLine, privacy: .public)")
        }
    }

    func refreshNow() {
        let raw = ConnectionSyncStatus.derive(self.sample())
        guard raw != self.status else { return }
        let previous = self.status
        self.status = raw
        connectionSyncLog.debug("connection sync status refreshed \(previous.statusLine, privacy: .public) -> \(raw.statusLine, privacy: .public)")
    }
}
