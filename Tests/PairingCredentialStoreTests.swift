// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
import SPLTunnel
@testable import solstone_swift

private final class StoredHolder: @unchecked Sendable {
    var stored: StoredPairing?
    var shouldThrowOnSave = false
    init(_ stored: StoredPairing? = nil) {
        self.stored = stored
    }
}

private struct TestSaveError: Error {}

final class PairingCredentialStoreTests: XCTestCase {
    private var testKeychainStores: [SPLKeychainStore] = []

    override func tearDown() {
        for store in testKeychainStores {
            _ = try? store.delete()
        }
        testKeychainStores.removeAll()
        super.tearDown()
    }

    private func makeRealKeychainStore() -> (PairingCredentialStore, SPLKeychainStore) {
        let service = "app.solstone.swift.test.\(UUID().uuidString)"
        let keychain = SPLKeychainStore(
            policy: KeychainPolicy(
                service: service,
                account: "pairing",
                accessGroup: nil,
                useDataProtectionKeychain: false,
                accessibility: .afterFirstUnlock
            )
        )
        testKeychainStores.append(keychain)
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { try keychain.save($0) },
            deletePairing: { try keychain.delete() }
        )
        return (store, keychain)
    }

    private func makeSamplePairing(
        instanceID: String = "test-instance",
        relayEnrollment: RelayEnrollment = .unavailable
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "Alice Journal",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "0123456789abcdef",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: relayEnrollment,
            localEndpoints: [LocalEndpoint(host: "192.168.1.100", port: 7071, scope: "local")],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testRealKeychainStoreLifecycle() async throws {
        let (store, _) = makeRealKeychainStore()

        XCTAssertEqual(store.pairingGeneration, 0)
        XCTAssertEqual(store.accessMutationGeneration, 0)

        let pairing1 = makeSamplePairing(instanceID: "real-inst-1")
        try store.applyPairing(pairing1)

        XCTAssertEqual(store.pairingGeneration, 1)
        XCTAssertEqual(store.accessMutationGeneration, 1)
        XCTAssertEqual(try store.load()?.instanceID, "real-inst-1")

        // Same identity pairing always bumps generations on applyPairing
        try store.applyPairing(pairing1)
        XCTAssertEqual(store.pairingGeneration, 2)
        XCTAssertEqual(store.accessMutationGeneration, 2)

        let committed = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "real-token",
            expiresAt: "2036-01-01T00:00:00Z",
            pairingGen: 2,
            mutationGen: 2
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(store.accessMutationGeneration, 3)
        if case .enrolled(let token, _) = try store.load()?.relayEnrollment {
            XCTAssertEqual(token, "real-token")
        } else {
            XCTFail("Expected enrolled")
        }

        let disabled = try await store.disableRelayAccess(pairingGen: 2, mutationGen: 3)
        XCTAssertTrue(disabled)
        XCTAssertEqual(store.accessMutationGeneration, 4)
        XCTAssertEqual(try store.load()?.relayEnrollment, .unavailable)

        let revoked = try await store.revokeIfCurrentGeneration(pairingGen: 2, mutationGen: 4)
        XCTAssertTrue(revoked)
        XCTAssertNil(try store.load())
    }

    func testSaveFailureLeavesLiveRelayDisabledTrueAndBumpsMutationAndSetsFailedClear() async throws {
        let holder = StoredHolder(makeSamplePairing(
            instanceID: "inst-1",
            relayEnrollment: .enrolled(deviceToken: "tok-1", expiresAt: nil)
        ))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: {
                if holder.shouldThrowOnSave {
                    throw TestSaveError()
                }
                holder.stored = $0
            },
            deletePairing: { holder.stored = nil }
        )

        let pairGen = store.pairingGeneration
        let mutGen = store.accessMutationGeneration

        holder.shouldThrowOnSave = true
        do {
            _ = try await store.disableRelayAccess(pairingGen: pairGen, mutationGen: mutGen)
            XCTFail("Expected throw")
        } catch {
            // expected
        }

        // Overlay is set to true immediately even though disk save failed
        XCTAssertTrue(store.isLiveRelayDisabled)
        // Mutation generation IS bumped
        let newMutGen = mutGen + 1
        XCTAssertEqual(store.accessMutationGeneration, newMutGen)
        XCTAssertEqual(store.failedDurableClear, .uncommittedClear(pairingGen: pairGen, mutationGen: newMutGen))

        // Ready captured against old mutation fails CAS
        let oldReadyCommitted = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "tok-old",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: mutGen
        )
        XCTAssertFalse(oldReadyCommitted)

        // Retry of durable clear with newMutGen succeeds when save stops throwing
        holder.shouldThrowOnSave = false
        let retrySucceeded = try await store.retryDurableClear(pairingGen: pairGen, mutationGen: newMutGen)
        XCTAssertTrue(retrySucceeded)
        XCTAssertNil(store.failedDurableClear)
        XCTAssertEqual(holder.stored?.relayEnrollment, .unavailable)
    }

    func testInterveningReadySupersedesFailedClearRetry() async throws {
        let holder = StoredHolder(makeSamplePairing(
            instanceID: "inst-1",
            relayEnrollment: .enrolled(deviceToken: "tok-1", expiresAt: nil)
        ))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: {
                if holder.shouldThrowOnSave {
                    throw TestSaveError()
                }
                holder.stored = $0
            },
            deletePairing: { holder.stored = nil }
        )

        let pairGen = store.pairingGeneration
        let mutGen = store.accessMutationGeneration

        holder.shouldThrowOnSave = true
        do {
            _ = try await store.disableRelayAccess(pairingGen: pairGen, mutationGen: mutGen)
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        XCTAssertTrue(store.isLiveRelayDisabled)
        let failedClearMutGen = mutGen + 1
        XCTAssertEqual(store.accessMutationGeneration, failedClearMutGen)

        // Ready captured against the new disabled revision arrives and succeeds
        holder.shouldThrowOnSave = false
        let readyCommitted = try await store.commitReadyAccess(
            relayOrigin: "https://new-relay.example.com",
            deviceToken: "new-token",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: failedClearMutGen
        )
        XCTAssertTrue(readyCommitted)
        XCTAssertFalse(store.isLiveRelayDisabled)
        XCTAssertNil(store.failedDurableClear)
        XCTAssertEqual(store.accessMutationGeneration, failedClearMutGen + 1)

        // Stale retry against failedClearMutGen now fails CAS
        let staleRetrySucceeded = try await store.retryDurableClear(pairingGen: pairGen, mutationGen: failedClearMutGen)
        XCTAssertFalse(staleRetrySucceeded)
        if case .enrolled(let token, _) = holder.stored?.relayEnrollment {
            XCTAssertEqual(token, "new-token")
        } else {
            XCTFail("Expected new-token to remain intact")
        }
    }

    func testSameHomeApplyPairingBumpsGenerations() throws {
        let holder = StoredHolder()
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let pairing = makeSamplePairing(instanceID: "inst-1")
        try store.applyPairing(pairing)
        XCTAssertEqual(store.pairingGeneration, 1)
        XCTAssertEqual(store.accessMutationGeneration, 1)

        // Apply same pairing again
        try store.applyPairing(pairing)
        XCTAssertEqual(store.pairingGeneration, 2)
        XCTAssertEqual(store.accessMutationGeneration, 2)
    }

    func testRevokeIfCurrentGenerationCannotDeleteNewerReady() async throws {
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let initialPairGen = store.pairingGeneration
        let initialMutGen = store.accessMutationGeneration

        // Ready commits and bumps mutationGen
        let committed = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "tok-2",
            expiresAt: nil,
            pairingGen: initialPairGen,
            mutationGen: initialMutGen
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(store.accessMutationGeneration, initialMutGen + 1)

        // Stale revoke attempt using initialMutGen fails CAS
        let staleRevoked = try await store.revokeIfCurrentGeneration(
            pairingGen: initialPairGen,
            mutationGen: initialMutGen
        )
        XCTAssertFalse(staleRevoked)
        XCTAssertNotNil(holder.stored)
    }

    func testReadySaveFailurePreservesUsableState() async throws {
        let sample = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(sample)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: {
                if holder.shouldThrowOnSave {
                    throw TestSaveError()
                }
                holder.stored = $0
            },
            deletePairing: { holder.stored = nil }
        )

        let pairGen = store.pairingGeneration
        let mutGen = store.accessMutationGeneration

        holder.shouldThrowOnSave = true
        let committed = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "tok-fail",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: mutGen
        )
        XCTAssertFalse(committed)
        XCTAssertEqual(store.accessMutationGeneration, mutGen)
        XCTAssertFalse(store.isLiveRelayDisabled)
        XCTAssertEqual(holder.stored?.instanceID, "inst-1")
    }
    @MainActor
    func testQueuedStaleSaveAndDeleteCannotChangeReplacementKeychain() async throws {
        let (_, keychain) = makeRealKeychainStore()
        let original = makeSamplePairing(instanceID: "original")
        let replacement = makeSamplePairing(instanceID: "replacement")
        try keychain.save(original)
        let entered = expectation(description: "replacement save entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { pairing in
                if pairing.instanceID == "replacement" {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw TestSaveError() }
                }
                try keychain.save(pairing)
            },
            deletePairing: { try keychain.delete() }
        )
        let apply = Task.detached { try store.applyPairing(replacement) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(store.snapshot().pairing, original)
        let ready = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "stale",
                expiresAt: nil, pairingGen: 0, mutationGen: 0)
        }
        let revoke = Task { try await store.revokeIfCurrentGeneration(pairingGen: 0, mutationGen: 0) }
        try await Task.sleep(for: .milliseconds(50))
        release.signal()
        try await apply.value
        let didSave = try await ready.value
        let didDelete = try await revoke.value
        XCTAssertFalse(didSave)
        XCTAssertFalse(didDelete)
        XCTAssertEqual(try keychain.load(), replacement)
        XCTAssertEqual(store.snapshot().pairing, replacement)
    }

    @MainActor
    func testCancelledQueuedReadyCannotWriteKeychainAfterOwnedSaveFinishes() async throws {
        let (_, keychain) = makeRealKeychainStore()
        try keychain.save(makeSamplePairing())
        let entered = expectation(description: "first save entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { pairing in
                if case .enrolled("first", _) = pairing.relayEnrollment {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw TestSaveError() }
                }
                try keychain.save(pairing)
            },
            deletePairing: { try keychain.delete() }
        )
        let first = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "first",
                expiresAt: nil, pairingGen: 0, mutationGen: 0)
        }
        await fulfillment(of: [entered], timeout: 2)
        let cancelled = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "cancelled",
                expiresAt: nil, pairingGen: 0, mutationGen: 0)
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        release.signal()
        let firstResult = try await first.value
        let cancelledResult = try await cancelled.value
        XCTAssertTrue(firstResult)
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(try keychain.load()?.relayEnrollment, .enrolled(deviceToken: "first", expiresAt: nil))
        XCTAssertEqual(store.snapshot().pairing, try keychain.load())
    }

    @MainActor
    func testReadyExpiryIsCheckedAfterWaitingForClearRetryOwner() async throws {
        let (_, keychain) = makeRealKeychainStore()
        try keychain.save(makeSamplePairing(relayEnrollment: .enrolled(deviceToken: "old", expiresAt: nil)))
        let entered = expectation(description: "retry save entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let saveCount = StoreTestCounter()
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { pairing in
                let count = saveCount.next()
                if count == 1 { throw TestSaveError() }
                if count == 2 {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw TestSaveError() }
                }
                try keychain.save(pairing)
            },
            deletePairing: { try keychain.delete() }
        )
        do {
            _ = try await store.disableRelayAccess(pairingGen: 0, mutationGen: 0)
            XCTFail("clear should fail")
        } catch {}
        let retry = Task { try await store.retryDurableClear(pairingGen: 0, mutationGen: 1) }
        await fulfillment(of: [entered], timeout: 2)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.string(from: Date().addingTimeInterval(0.15))
        let ready = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "expired",
                expiresAt: expiry, pairingGen: 0, mutationGen: 1)
        }
        try await Task.sleep(for: .milliseconds(250))
        release.signal()
        let retried = try await retry.value
        let committed = try await ready.value
        XCTAssertTrue(retried)
        XCTAssertFalse(committed)
        XCTAssertEqual(saveCount.value, 2)
        XCTAssertEqual(try keychain.load()?.relayEnrollment, .unavailable)
        XCTAssertTrue(store.isLiveRelayDisabled)
    }

    func testAcceptedRefreshAdvancesRevisionAndRejectsOlderReadyAndRevoke() async throws {
        let (store, keychain) = makeRealKeychainStore()
        let pairing = makeSamplePairing()
        try store.applyPairing(pairing)
        let updated = makeSamplePairing(relayEnrollment: .enrolled(deviceToken: "refreshed", expiresAt: nil))
        let refreshed = try await store.persistRefreshedPairing(updated, pairingGen: 1, mutationGen: 1)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.accessMutationGeneration, 2)
        let ready = try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "old",
            expiresAt: nil, pairingGen: 1, mutationGen: 1)
        let revoked = try await store.revokeIfCurrentGeneration(pairingGen: 1, mutationGen: 1)
        XCTAssertFalse(ready)
        XCTAssertFalse(revoked)
        XCTAssertEqual(try keychain.load(), updated)
    }

}


private final class StoreTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
