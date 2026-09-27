// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import SPLTunnel

nonisolated final class ConnectionStallMonitorTests: XCTestCase {
    private func makeCredentials(pairing: StoredPairing? = nil) -> PairingCredentialStore {
        PairingCredentialStore(
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {},
            deletePushKey: {}
        )
    }

    private func makePairing(
        instanceID: String = "test-instance",
        pairedAt: Date = Date(),
        leafPEM: String = CertlessTrustFixtures.leafPEM,
        caPEM: String = CertlessTrustFixtures.caPEM,
        homeLabel: String = "Home"
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: homeLabel,
            relayEndpoint: "https://relay.example.com",
            fingerprint: "fingerprint",
            clientCertPEM: leafPEM,
            clientKeyPEM: "KEY",
            caChainPEM: caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: pairedAt
        )
    }

    @MainActor
    private func settleTimer(_ clock: ManualConnectionStallClock) async {
        while clock.pendingSleeperCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // Acceptance 1: Paired, path true, foreground 45s, reference >= 30m -> stalled. 44s -> not. 30m - 1s -> not.
    @MainActor
    func testAcceptance1_StallThresholds() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-1800),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2000))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)

        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(14))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(1))
        XCTAssertTrue(monitor.isStalled)

        // Reference 30 min - 1s -> not stalled (even with 45s foreground)
        let clock2 = ManualConnectionStallClock(now: t0)
        let store2 = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-1754), // At t0 + 45s, age is 1799s (30m - 1s)
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let monitor2 = ConnectionStallMonitor(store: store2, clock: clock2, credentials: credentials)
        monitor2.setNetworkPathSatisfied(true)
        monitor2.receiveScenePhase(.active)
        await self.settleTimer(clock2)

        await clock2.advance(by: .seconds(15))
        await clock2.advance(by: .seconds(15))
        await clock2.advance(by: .seconds(15))
        XCTAssertFalse(monitor2.isStalled)

        await clock2.advance(by: .seconds(15))
        XCTAssertTrue(monitor2.isStalled)
    }

    // Acceptance 2: Reference >= 30m. Heard event at 31s / 40s clears isStalled and carriedStall.
    @MainActor
    func testAcceptance2_HeardEventClearance() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)
        let expectedIdentity = credentials.snapshot().pairingIdentity

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(1))
        XCTAssertFalse(monitor.isStalled)
        XCTAssertFalse(store.load().carriedStall)

        monitor.noteHeard(identity: expectedIdentity)
        XCTAssertFalse(monitor.isStalled)
        XCTAssertFalse(store.load().carriedStall)

        // Separately ~40s
        let clock2 = ManualConnectionStallClock(now: t0)
        let store2 = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let monitor2 = ConnectionStallMonitor(store: store2, clock: clock2, credentials: credentials)
        monitor2.setNetworkPathSatisfied(true)
        monitor2.receiveScenePhase(.active)
        await self.settleTimer(clock2)
        XCTAssertFalse(monitor2.isStalled)

        await clock2.advance(by: .seconds(15))
        await clock2.advance(by: .seconds(15))
        await clock2.advance(by: .seconds(10))
        XCTAssertFalse(monitor2.isStalled)
        XCTAssertFalse(store2.load().carriedStall)

        monitor2.noteHeard(identity: expectedIdentity)
        XCTAssertFalse(monitor2.isStalled)
        XCTAssertFalse(store2.load().carriedStall)
    }

    // Acceptance 3: carriedStall false, background, advance 2h, active -> requires full 45s foreground
    @MainActor
    func testAcceptance3_BackgroundReset() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(5))
        XCTAssertFalse(monitor.isStalled)

        monitor.receiveScenePhase(.background)
        await clock.advance(by: .seconds(7200))

        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(14))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(1))
        XCTAssertTrue(monitor.isStalled)
    }

    // Acceptance 4: Store has carriedStall true and old last-heard -> .active stalls immediately without clock advance
    @MainActor
    func testAcceptance4_CarriedStallImmediate() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        XCTAssertTrue(monitor.isStalled)
    }

    // Acceptance 5: .active 20s, .inactive, .active -> stalls 45s from first .active
    @MainActor
    func testAcceptance5_InactivePhasePreserved() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(5))

        monitor.receiveScenePhase(.inactive)
        await clock.advance(by: .seconds(10))

        monitor.receiveScenePhase(.active)
        await clock.advance(by: .seconds(14))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(1))
        XCTAssertTrue(monitor.isStalled)
    }

    // Acceptance 6: Path false and nil -> not stalled; carriedStall stays true
    @MainActor
    func testAcceptance6_NetworkPathGating() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(false)
        monitor.receiveScenePhase(.active)
        XCTAssertFalse(monitor.isStalled)
        XCTAssertTrue(store.load().carriedStall)

        monitor.setNetworkPathSatisfied(nil)
        XCTAssertFalse(monitor.isStalled)
        XCTAssertTrue(store.load().carriedStall)
    }

    // Acceptance 7: Throttled last-heard persistence and identity filtering
    @MainActor
    func testAcceptance7_ThrottledLastHeardAndIdentity() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: nil,
            lastHeardPairingIdentity: nil,
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2000))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)
        let identity = credentials.snapshot().pairingIdentity!

        // Event 1 at T0
        monitor.noteHeard(identity: identity)
        XCTAssertEqual(store.load().lastHeardFromJournalAt, t0)
        XCTAssertEqual(store.load().lastHeardPairingIdentity, identity)
        XCTAssertEqual(monitor.displayableLastHeardAt, t0)
        XCTAssertFalse(store.load().carriedStall)

        // Event 2 at T0 + 30s (within 60s)
        await clock.advance(by: .seconds(30))
        let t30 = clock.now
        monitor.noteHeard(identity: identity)
        XCTAssertEqual(monitor.displayableLastHeardAt, t30)
        XCTAssertEqual(store.load().lastHeardFromJournalAt, t0) // Still T0 in store

        // Event 3 at T0 + 60s (60s elapsed since last persist)
        await clock.advance(by: .seconds(30))
        let t60 = clock.now
        monitor.noteHeard(identity: identity)
        XCTAssertEqual(monitor.displayableLastHeardAt, t60)
        XCTAssertEqual(store.load().lastHeardFromJournalAt, t60)

        // Other identity and nil change nothing
        await clock.advance(by: .seconds(70))
        monitor.noteHeard(identity: "wrong-identity")
        XCTAssertEqual(monitor.displayableLastHeardAt, t60)
        XCTAssertEqual(store.load().lastHeardFromJournalAt, t60)

        monitor.noteHeard(identity: nil)
        XCTAssertEqual(monitor.displayableLastHeardAt, t60)
        XCTAssertEqual(store.load().lastHeardFromJournalAt, t60)
    }

    // Acceptance 8: Pairing changes, refreshed pairings, and carriedStall clearing
    @MainActor
    func testAcceptance8_PairingChangesAndRefreshes() async throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "initial-identity",
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let initialPairing = self.makePairing(instanceID: "inst-1", pairedAt: t0.addingTimeInterval(-3000))
        let credentials = self.makeCredentials(pairing: initialPairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)
        XCTAssertTrue(monitor.isStalled)

        // Apply new pairing with new pairedAt
        let newPairing = self.makePairing(instanceID: "inst-2", pairedAt: t0)
        try credentials.applyPairing(newPairing)

        await clock.advance(by: .seconds(15))
        XCTAssertFalse(store.load().carriedStall)
        XCTAssertNil(monitor.displayableLastHeardAt)
        XCTAssertFalse(monitor.isStalled)

        monitor.receiveScenePhase(.background)
        await clock.setNow(t0.addingTimeInterval(1800))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        monitor.receiveScenePhase(.active)
        XCTAssertFalse(monitor.isStalled)
        await self.settleTimer(clock)

        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(14))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(1))
        XCTAssertTrue(monitor.isStalled)

        // Re-apply equal pairing preserves carriedStall
        let store2 = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: credentials.snapshot().pairingIdentity,
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let monitor2 = ConnectionStallMonitor(store: store2, clock: clock, credentials: credentials)
        monitor2.setNetworkPathSatisfied(true)
        monitor2.evaluate()
        XCTAssertTrue(monitor2.isStalled)
        XCTAssertTrue(store2.load().carriedStall)

        try credentials.applyPairing(newPairing)
        monitor2.evaluate()
        XCTAssertTrue(store2.load().carriedStall)

        // Refreshed pairing preserves carriedStall
        let snap = credentials.snapshot()
        let refreshed = self.makePairing(instanceID: "inst-2", pairedAt: t0, homeLabel: "Renamed Home")
        let refreshedSuccess = try await credentials.persistRefreshedPairing(
            refreshed,
            pairingGen: snap.pairingGeneration,
            mutationGen: snap.accessMutationGeneration
        )
        XCTAssertTrue(refreshedSuccess)
        monitor2.evaluate()
        XCTAssertTrue(store2.load().carriedStall)
    }

    // Acceptance 9: Seeding lifecycle
    @MainActor
    func testAcceptance9_SeedingLifecycle() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore()
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-100))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)

        XCTAssertEqual(store.load().stallClockSeededAt, t0)
        XCTAssertNil(monitor.displayableLastHeardAt)
        XCTAssertFalse(monitor.isStalled)

        // Second monitor sharing same store
        let monitor2 = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)
        monitor2.setNetworkPathSatisfied(true)
        monitor2.receiveScenePhase(.active)
        await self.settleTimer(clock)
        XCTAssertEqual(store.load().stallClockSeededAt, t0)

        // Stalls 30 min after seed + 45s foreground. At t0 + 1785s (119 * 15s), not stalled:
        for _ in 0..<119 {
            await clock.advance(by: .seconds(15))
        }
        XCTAssertFalse(monitor2.isStalled)
        // 120th step = 1800s (30m after seed, foreground is 1800s >= 45s) -> stalls
        await clock.advance(by: .seconds(15))
        XCTAssertTrue(monitor2.isStalled)
    }

    // Acceptance 10: Future-date corrections
    @MainActor
    func testAcceptance10_FutureDateCorrections() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let futureDate = t0.addingTimeInterval(7 * 86400)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: futureDate,
            lastHeardPairingIdentity: "future-id",
            stallClockSeededAt: futureDate,
            carriedStall: false
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-100))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.evaluate()

        XCTAssertEqual(store.load().lastHeardFromJournalAt, t0)
        XCTAssertEqual(store.load().stallClockSeededAt, t0)

        // Second evaluate with clock unchanged does not move it
        monitor.evaluate()
        XCTAssertEqual(store.load().lastHeardFromJournalAt, t0)

        // Prove stall timing from corrected now (t0):
        // Path satisfied, foreground interval running, reference is the corrected t0.
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)

        // At t0 + 1800 - 1 seconds (1799s): 119 * 15s = 1785s + 14s = 1799s
        for _ in 0..<119 {
            await clock.advance(by: .seconds(15))
        }
        await clock.advance(by: .seconds(14))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        // At t0 + 1800 seconds (1s more, foreground already past 45s) -> isStalled == true
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(monitor.isStalled)

        // Separate case: in-memory foreground start rewritten when clock jumps backward
        let clock2 = ManualConnectionStallClock(now: t0)
        let store2 = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-1900), // > 31 minutes before t0
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let pairing2 = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials2 = self.makeCredentials(pairing: pairing2)
        let monitor2 = ConnectionStallMonitor(store: store2, clock: clock2, credentials: credentials2)

        // .active at t0 (foreground start = t0)
        monitor2.receiveScenePhase(.active)
        await self.settleTimer(clock2)

        // setNow(t0 - 30) so the in-memory foreground start is in the future and stored last-heard is still in past
        await clock2.setNow(t0.addingTimeInterval(-30))

        // setNetworkPathSatisfied(true) to evaluate -> start must be rewritten to new now (t0 - 30)
        monitor2.setNetworkPathSatisfied(true)

        // Advance 44s (elapsed 44s from t0 - 30) -> isStalled == false
        await clock2.advance(by: .seconds(15))
        await clock2.advance(by: .seconds(15))
        await clock2.advance(by: .seconds(14))
        monitor2.evaluate()
        XCTAssertFalse(monitor2.isStalled)

        // Advance 1s (elapsed 45s from t0 - 30) -> isStalled == true
        await clock2.advance(by: .seconds(1))
        XCTAssertTrue(monitor2.isStalled)
    }

    // Acceptance 11: Timer loop and background cancellation
    @MainActor
    func testAcceptance11_TimerExecution() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-1790),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let pairing = self.makePairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        await self.settleTimer(clock)
        XCTAssertFalse(monitor.isStalled)

        // Step 15s -> timer wakes up at t0 + 15s (age 1805s >= 1800s) and evaluate flips stalled
        await clock.advance(by: .seconds(15))
        XCTAssertTrue(monitor.isStalled)

        // Reference old, carriedStall false -> stalls on advance reaching 45s
        let clock2 = ManualConnectionStallClock(now: t0)
        let store2 = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let monitor2 = ConnectionStallMonitor(store: store2, clock: clock2, credentials: credentials)
        monitor2.setNetworkPathSatisfied(true)
        monitor2.receiveScenePhase(.active)
        await self.settleTimer(clock2)

        await clock2.advance(by: .seconds(15))
        XCTAssertFalse(monitor2.isStalled)
        await clock2.advance(by: .seconds(15))
        XCTAssertFalse(monitor2.isStalled)
        await clock2.advance(by: .seconds(15))
        XCTAssertTrue(monitor2.isStalled)

        // Background cancels sleeper
        monitor2.receiveScenePhase(.background)
        while clock2.pendingSleeperCount > 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(clock2.pendingSleeperCount, 0)

        // Active arms sleeper again
        monitor2.receiveScenePhase(.active)
        await self.settleTimer(clock2)
        XCTAssertEqual(clock2.pendingSleeperCount, 1)
    }

    // Acceptance 15: Factory behavior and PairingCredentialStore generation isolation
    @MainActor
    func testAcceptance15_FactoryAndStoreIsolation() throws {
        // Factory argument branches
        let userDefaultsStore = ConnectionStallStoreFactory.make(arguments: [], environment: [:])
        XCTAssertTrue(userDefaultsStore is UserDefaultsConnectionStallStore)

        let uiTestStore = ConnectionStallStoreFactory.make(arguments: ["--ui-test"], environment: [:])
        XCTAssertTrue(uiTestStore is InMemoryConnectionStallStore)

        let integrationStore = ConnectionStallStoreFactory.make(arguments: ["--integration-test"], environment: [:])
        XCTAssertTrue(integrationStore is InMemoryConnectionStallStore)

        let integrationLiveStore = ConnectionStallStoreFactory.make(arguments: ["--integration-test-live"], environment: [:])
        XCTAssertTrue(integrationLiveStore is InMemoryConnectionStallStore)

        let envStore = ConnectionStallStoreFactory.make(arguments: [], environment: ["XCTestConfigurationFilePath": "/path"])
        XCTAssertTrue(envStore is InMemoryConnectionStallStore)

        // Zero-arg in XCTest process returns InMemoryConnectionStallStore
        let defaultStore = ConnectionStallStoreFactory.make()
        XCTAssertTrue(defaultStore is InMemoryConnectionStallStore)

        // Monitor with fresh store is not stalled
        let clock = ManualConnectionStallClock()
        let pairing = self.makePairing()
        let credentials = self.makeCredentials(pairing: pairing)
        let monitor = ConnectionStallMonitor(store: defaultStore, clock: clock, credentials: credentials)
        XCTAssertFalse(monitor.isStalled)
        monitor.setNetworkPathSatisfied(true)
        monitor.receiveScenePhase(.active)
        XCTAssertFalse(monitor.isStalled)

        // Private suite UserDefaultsConnectionStallStore does not change pairingGeneration
        let suiteName = "test.stall.store.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let customStore = UserDefaultsConnectionStallStore(defaults: userDefaults)
        try credentials.applyPairing(pairing)
        let generationBefore = credentials.pairingGeneration

        customStore.setCarriedStall(true)
        customStore.setLastHeard(at: Date(), pairingIdentity: "ident")

        let generationAfter = credentials.pairingGeneration
        XCTAssertEqual(generationBefore, generationAfter)
    }

    @MainActor
    func testSeedUITestStallPreservesCarriedStallAndSurvivesReevaluation() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore()
        let credentials = self.makeCredentials(pairing: nil)
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)

        monitor.setNetworkPathSatisfied(true)
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        let threeDaysAgo = t0.addingTimeInterval(-3 * 24 * 60 * 60)
        let pairing = self.makePairing(pairedAt: threeDaysAgo)
        try credentials.applyPairing(pairing)

        monitor.seedUITestStall(
            lastHeardAt: threeDaysAgo,
            stallClockSeededAt: threeDaysAgo,
            carriedStall: true
        )

        XCTAssertTrue(monitor.isStalled)
        XCTAssertEqual(monitor.displayableLastHeardAt, threeDaysAgo)
        let snapshot = store.load()
        XCTAssertTrue(snapshot.carriedStall)
        XCTAssertEqual(snapshot.stallClockSeededAt, threeDaysAgo)
        if let identity = credentials.snapshot().pairingIdentity {
            XCTAssertEqual(snapshot.lastHeardPairingIdentity, identity)
        }

        monitor.evaluate()
        XCTAssertTrue(monitor.isStalled)

        // Fresh seed is not stalled
        let freshStore = InMemoryConnectionStallStore()
        let freshMonitor = ConnectionStallMonitor(store: freshStore, clock: clock, credentials: credentials)
        freshMonitor.setNetworkPathSatisfied(true)
        freshMonitor.seedUITestStall(
            lastHeardAt: clock.now,
            stallClockSeededAt: clock.now,
            carriedStall: false
        )
        XCTAssertFalse(freshMonitor.isStalled)
    }
}
