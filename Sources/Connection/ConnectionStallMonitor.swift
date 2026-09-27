// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import os

nonisolated struct ConnectionHeardEvent: Sendable, Equatable {
    var pairingIdentity: String?
}

typealias ConnectionHeardSink = @MainActor @Sendable (ConnectionHeardEvent) -> Void

nonisolated final class ConnectionHeardReporter: @unchecked Sendable {
    private struct State: Sendable {
        var dialedIdentity: @Sendable () async -> String? = { nil }
        var sink: @Sendable (ConnectionHeardEvent) async -> Void = { _ in }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    nonisolated init() {}

    func bind(
        dialedIdentity: @escaping @Sendable () async -> String?,
        sink: @escaping @Sendable (ConnectionHeardEvent) async -> Void
    ) {
        self.state.withLock {
            $0.dialedIdentity = dialedIdentity
            $0.sink = sink
        }
    }

    func currentIdentity() async -> String? {
        let closure = self.state.withLock { $0.dialedIdentity }
        return await closure()
    }

    func report(_ event: ConnectionHeardEvent) async {
        let closure = self.state.withLock { $0.sink }
        await closure(event)
    }
}

@MainActor
@Observable
final class ConnectionStallMonitor {
    private(set) var isStalled: Bool = false
    private(set) var displayableLastHeardAt: Date? = nil

    @ObservationIgnored private let store: any ConnectionStallStoring
    @ObservationIgnored private let clock: any ConnectionStallClock
    @ObservationIgnored private let credentials: PairingCredentialStore

    @ObservationIgnored private var networkPathSatisfied: Bool? = nil
    @ObservationIgnored private var foregroundStartedAt: Date? = nil
    @ObservationIgnored private var lastHeardPersistAt: Date? = nil
    @ObservationIgnored private var lastSeenPaired: Bool? = nil
    @ObservationIgnored private var lastSeenPairedAt: Date? = nil
    @ObservationIgnored private var lastSeenPairingIdentity: String? = nil
    @ObservationIgnored private var hasSeenPairing: Bool = false
    @ObservationIgnored private var timerTask: Task<Void, Never>? = nil

    @ObservationIgnored private var isLoaded: Bool = false
    @ObservationIgnored private var inMemoryLastHeardAt: Date? = nil
    @ObservationIgnored private var inMemoryLastHeardIdentity: String? = nil
    @ObservationIgnored private var inMemorySeededAt: Date? = nil
    @ObservationIgnored private var inMemoryCarriedStall: Bool = false

    @ObservationIgnored private let logger = Logger(subsystem: "app.solstone.swift", category: "connection-stall")

    init(
        store: any ConnectionStallStoring,
        clock: any ConnectionStallClock,
        credentials: PairingCredentialStore
    ) {
        self.store = store
        self.clock = clock
        self.credentials = credentials
    }

    private func ensureLoaded() {
        guard !self.isLoaded else { return }
        let snapshot = self.store.load()
        self.inMemoryLastHeardAt = snapshot.lastHeardFromJournalAt
        self.inMemoryLastHeardIdentity = snapshot.lastHeardPairingIdentity
        self.inMemorySeededAt = snapshot.stallClockSeededAt
        self.inMemoryCarriedStall = snapshot.carriedStall
        self.isLoaded = true
    }

    func noteHeard(identity: String?) {
        self.ensureLoaded()
        let snapshot = self.credentials.snapshot()
        guard let identity, identity == snapshot.pairingIdentity else { return }

        let now = self.clock.now
        self.inMemoryLastHeardAt = now
        self.inMemoryLastHeardIdentity = identity
        if self.inMemoryCarriedStall {
            self.inMemoryCarriedStall = false
            self.store.setCarriedStall(false)
        }

        if self.lastHeardPersistAt == nil || (now.timeIntervalSince1970 - self.lastHeardPersistAt!.timeIntervalSince1970) >= 60 {
            self.store.setLastHeard(at: now, pairingIdentity: identity)
            self.lastHeardPersistAt = now
        }

        self.evaluate()
    }

    func setNetworkPathSatisfied(_ satisfied: Bool?) {
        self.networkPathSatisfied = satisfied
        self.evaluate()
    }

    func receiveScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if self.foregroundStartedAt == nil {
                self.foregroundStartedAt = self.clock.now
                self.startTimer()
            }
        case .inactive:
            break
        case .background:
            self.foregroundStartedAt = nil
            self.stopTimer()
        @unknown default:
            break
        }
        self.evaluate()
    }

    private func startTimer() {
        self.stopTimer()
        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    try await self.clock.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self.evaluate()
                } catch {
                    return
                }
            }
        }
    }

    private func stopTimer() {
        self.timerTask?.cancel()
        self.timerTask = nil
    }

    func evaluate() {
        self.ensureLoaded()
        let now = self.clock.now

        // 2. Future-date correction (not throttled)
        if let lastHeard = self.inMemoryLastHeardAt, lastHeard > now {
            self.inMemoryLastHeardAt = now
            if let identity = self.inMemoryLastHeardIdentity {
                self.store.setLastHeard(at: now, pairingIdentity: identity)
            }
            self.lastHeardPersistAt = now
        }
        if let seeded = self.inMemorySeededAt, seeded > now {
            self.inMemorySeededAt = now
            self.store.setStallClockSeededAt(now)
        }
        if let foreground = self.foregroundStartedAt, foreground > now {
            self.foregroundStartedAt = now
        }

        let credSnapshot = self.credentials.snapshot()
        let paired = credSnapshot.pairing != nil
        let pairedAt = credSnapshot.pairing?.pairedAt
        let identity = credSnapshot.pairingIdentity

        // 3. Seed once
        if paired, self.inMemoryLastHeardAt == nil, self.inMemorySeededAt == nil {
            self.inMemorySeededAt = now
            self.store.setStallClockSeededAt(now)
        }

        // 4. Pairing delta
        if self.hasSeenPairing {
            if paired != self.lastSeenPaired || pairedAt != self.lastSeenPairedAt || identity != self.lastSeenPairingIdentity {
                if self.inMemoryCarriedStall {
                    self.inMemoryCarriedStall = false
                    self.store.setCarriedStall(false)
                }
            }
        } else if !paired, self.inMemoryCarriedStall {
            self.inMemoryCarriedStall = false
            self.store.setCarriedStall(false)
        }
        self.hasSeenPairing = true
        self.lastSeenPaired = paired
        self.lastSeenPairedAt = pairedAt
        self.lastSeenPairingIdentity = identity

        // 5. Reference & Displayable
        let nonNilTimestamps = [self.inMemoryLastHeardAt, self.inMemorySeededAt, pairedAt].compactMap { $0 }
        let reference = nonNilTimestamps.max()

        if let pairedAt, let lastHeard = self.inMemoryLastHeardAt, lastHeard >= pairedAt {
            self.displayableLastHeardAt = lastHeard
        } else {
            self.displayableLastHeardAt = nil
        }

        // 6. Stall Condition
        var newStalled = false
        if paired, self.networkPathSatisfied == true, let reference {
            let refAge = now.timeIntervalSince1970 - reference.timeIntervalSince1970
            if refAge >= 30 * 60 {
                let graceSatisfied = (self.foregroundStartedAt != nil && (now.timeIntervalSince1970 - self.foregroundStartedAt!.timeIntervalSince1970) >= 45) || self.inMemoryCarriedStall
                if graceSatisfied {
                    newStalled = true
                }
            }
        }

        // 7. Carried Stall Persistence
        if newStalled, !self.inMemoryCarriedStall {
            self.inMemoryCarriedStall = true
            self.store.setCarriedStall(true)
        }

        // 8. Log only transition
        if self.isStalled != newStalled {
            self.isStalled = newStalled
            if newStalled {
                self.logger.info("connection stall began")
            } else {
                self.logger.info("connection stall cleared")
            }
        }
    }
}
