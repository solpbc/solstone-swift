// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import os

private nonisolated let storeLog = Logger(subsystem: "app.solstone.swift", category: "pairing-store")

public nonisolated enum FailedDurableClearClassification: Sendable, Equatable {
    case uncommittedClear(pairingGen: UInt64, mutationGen: UInt64)
}

public nonisolated struct PairingCredentialSnapshot: Sendable, Equatable {
    public let pairing: StoredPairing?
    public let pairingIdentity: String?
    public let deviceOwnerID: UUID?
    public let pairingGeneration: UInt64
    public let accessMutationGeneration: UInt64
    public let isLiveRelayDisabled: Bool
    public let failedDurableClear: FailedDurableClearClassification?

    public init(
        pairing: StoredPairing?,
        pairingIdentity: String?,
        deviceOwnerID: UUID?,
        pairingGeneration: UInt64,
        accessMutationGeneration: UInt64,
        isLiveRelayDisabled: Bool,
        failedDurableClear: FailedDurableClearClassification?
    ) {
        self.pairing = pairing
        self.pairingIdentity = pairingIdentity
        self.deviceOwnerID = deviceOwnerID
        self.pairingGeneration = pairingGeneration
        self.accessMutationGeneration = accessMutationGeneration
        self.isLiveRelayDisabled = isLiveRelayDisabled
        self.failedDurableClear = failedDurableClear
    }
}

nonisolated final class PairingCredentialStore: @unchecked Sendable {
    private struct State {
        var pairing: StoredPairing? = nil
        var pairingGeneration: UInt64 = 0
        var accessMutationGeneration: UInt64 = 0
        var liveRelayDisabled: Bool = false
        var pairingIdentity: String? = nil
        var deviceOwnerID: UUID? = nil
        var failedDurableClear: FailedDurableClearClassification? = nil
        var migrationGenerationPending = false
    }

    private let lock = NSLock()
    private var state = State()
    private let keychainQueue = DispatchQueue(label: "app.solstone.swift.pairing-store.keychain")

    private let confirmationStore: JournalSendConfirmationStore
    let migrationStore: DeviceMigrationStore
    private let loadPairingClosure: @Sendable () throws -> StoredPairing?
    private let savePairingClosure: @Sendable (StoredPairing) throws -> Void
    private let deletePairingClosure: @Sendable () throws -> Void
    private let deletePushKeyClosure: @Sendable () throws -> Void

    init(
        confirmationStore: JournalSendConfirmationStore = SPLRuntime.confirmationStore,
        migrationStore: DeviceMigrationStore = .memory(),
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLRuntime.keychainStore.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLRuntime.keychainStore.delete() },
        deletePushKey: @escaping @Sendable () throws -> Void = {}
    ) {
        self.confirmationStore = confirmationStore
        self.migrationStore = migrationStore
        self.loadPairingClosure = loadPairing
        self.savePairingClosure = savePairing
        self.deletePairingClosure = deletePairing
        self.deletePushKeyClosure = deletePushKey

        if let existing = try? loadPairing() {
            self.state.pairing = existing
            self.state.pairingIdentity = journalVersionMetadataIdentity(for: existing)
            do {
                self.state.deviceOwnerID = try self.recoverDeviceOwner(for: existing)
            } catch {
                do {
                    self.state.deviceOwnerID = try migrationStore.claimExistingPairing(existing)
                } catch {
                    storeLog.error("stored pairing has no active migration owner")
                }
            }
        }
    }

    convenience init(
        store: SPLKeychainStore,
        confirmationStore: JournalSendConfirmationStore,
        migrationStore: DeviceMigrationStore = DeviceMigrationStore()
    ) {
        self.init(
            confirmationStore: confirmationStore,
            migrationStore: migrationStore,
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            deletePushKey: { try PushKeyStore.production().delete() }
        )
    }

    private var onApplyPairingHook: (@MainActor @Sendable () -> Void)?
    private var onCredentialInvalidationHook: (@MainActor @Sendable () -> Void)?
    private var onCredentialReplacementHooks: [@MainActor @Sendable () -> Void] = []

    func registerOnApplyPairing(_ hook: (@MainActor @Sendable () -> Void)?) {
        self.lock.withLock {
            self.onApplyPairingHook = hook
        }
    }

    func registerOnCredentialInvalidation(_ hook: (@MainActor @Sendable () -> Void)?) {
        self.lock.withLock {
            self.onCredentialInvalidationHook = hook
        }
    }

    func registerOnCredentialReplacement(_ hook: (@MainActor @Sendable () -> Void)?) {
        self.lock.withLock {
            if let hook { self.onCredentialReplacementHooks.append(hook) }
        }
    }

    private func runOnMain(_ hook: (@MainActor @Sendable () -> Void)?) {
        guard let hook else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { hook() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { hook() } }
        }
    }

    func performOnKeychainQueue<T>(_ block: () throws -> T) throws -> T {
        try self.keychainQueue.sync {
            try block()
        }
    }

    func reloadPairingFromKeychain() throws -> StoredPairing? {
        // The loadPairing closure must not hop to the main actor and must not call back onto keychainQueue.
        // Match mutations: Keychain queue before migration-store serialization.
        try self.keychainQueue.sync {
            let loaded = try self.loadPairingClosure()
            guard let loaded else { return nil }
            let ownerID = try self.recoverDeviceOwner(for: loaded)
            self.lock.withLock {
                self.state.pairing = loaded
                self.state.pairingIdentity = journalVersionMetadataIdentity(for: loaded)
                self.state.deviceOwnerID = ownerID
            }
            return loaded
        }
    }

    private func recoverDeviceOwner(for pairing: StoredPairing) throws -> UUID {
        try self.migrationStore.withMigrationMutation {
            if let recovery = try self.migrationStore.recoverPairingReplacement(pairing) {
                if recovery.resetPairingState {
                    try self.confirmationStore.writeMarkerOnApplyPairing()
                    try self.deletePushKeyClosure()
                }
                try self.migrationStore.commitPairingReplacement(ownerID: recovery.ownerID)
                return recovery.ownerID
            }
            return try self.migrationStore.claimExistingPairing(pairing)
        }
    }

    func beginPairingFlow() throws -> DeviceMigrationPairingFlowLease {
        let current = self.snapshot()
        if let pairing = current.pairing {
            guard let ownerID = current.deviceOwnerID,
                  try self.migrationStore.owns(ownerID: ownerID, pairing: pairing) else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
        }
        return try self.migrationStore.beginPairingFlowLease(
            ownerID: current.deviceOwnerID,
            credentialCID: current.pairing?.fingerprint
        )
    }

    private func performMutation(
        mayPublish: @escaping @Sendable () -> Bool,
        _ operation: @escaping @Sendable () throws -> Bool
    ) async throws -> Bool {
        let permit = PairingMutationPermit()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.keychainQueue.async {
                    guard permit.isValid, mayPublish() else {
                        continuation.resume(returning: false)
                        return
                    }
                    do {
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            permit.cancel()
        }
    }

    func snapshot() -> PairingCredentialSnapshot {
        self.lock.withLock {
            PairingCredentialSnapshot(
                pairing: self.state.pairing,
                pairingIdentity: self.state.pairingIdentity,
                deviceOwnerID: self.state.deviceOwnerID,
                pairingGeneration: self.state.pairingGeneration,
                accessMutationGeneration: self.state.accessMutationGeneration,
                isLiveRelayDisabled: self.state.liveRelayDisabled,
                failedDurableClear: self.state.failedDurableClear
            )
        }
    }

    var pairingGeneration: UInt64 {
        self.snapshot().pairingGeneration
    }

    var accessMutationGeneration: UInt64 {
        self.snapshot().accessMutationGeneration
    }

    var isLiveRelayDisabled: Bool {
        self.snapshot().isLiveRelayDisabled
    }

    var pairingIdentity: String? {
        self.snapshot().pairingIdentity
    }

    var failedDurableClear: FailedDurableClearClassification? {
        self.snapshot().failedDurableClear
    }

    var hasActiveOwner: Bool {
        let snapshot = self.snapshot()
        guard let ownerID = snapshot.deviceOwnerID, let pairing = snapshot.pairing else { return false }
        return (try? self.migrationStore.owns(ownerID: ownerID, pairing: pairing)) == true
    }

    private func ownsCurrentCredential(_ snapshot: PairingCredentialSnapshot, pairing: StoredPairing) -> Bool {
        guard let ownerID = snapshot.deviceOwnerID,
              snapshot.pairing?.fingerprint == pairing.fingerprint else { return false }
        return (try? self.migrationStore.owns(ownerID: ownerID, pairing: pairing)) == true
    }

    func recoverCommittedOwner(pairing: StoredPairing, ownerID: UUID) throws {
        var didAdvanceGeneration = false
        try self.keychainQueue.sync {
            let snapshot = self.snapshot()
            guard snapshot.deviceOwnerID == ownerID,
                  snapshot.pairing?.fingerprint == pairing.fingerprint else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            if try self.migrationStore.owns(ownerID: ownerID, pairing: pairing) {
                let shouldAdvance = self.lock.withLock { self.state.migrationGenerationPending }
                guard shouldAdvance else { return }
                self.lock.withLock {
                    self.state.pairingGeneration &+= 1
                    self.state.accessMutationGeneration &+= 1
                    self.state.liveRelayDisabled = false
                    self.state.migrationGenerationPending = false
                }
                didAdvanceGeneration = true
                return
            }
            let identity = try DevicePairingIdentity.make(for: pairing)
            let portable = try self.migrationStore.loadPortable(for: identity)
            guard let transaction = portable.transaction,
                  transaction.phase == .credentialCommitted,
                  transaction.currentCID == pairing.fingerprint,
                  transaction.pairingOwnerID == ownerID,
                  portable.baseline?.cid == pairing.fingerprint else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            try self.migrationStore.updateCredential(ownerID: ownerID, pairing: pairing)
            self.lock.withLock {
                self.state.pairing = pairing
                self.state.pairingGeneration &+= 1
                self.state.accessMutationGeneration &+= 1
                self.state.liveRelayDisabled = false
                self.state.migrationGenerationPending = false
            }
            didAdvanceGeneration = true
        }
        if didAdvanceGeneration {
            let hook = self.lock.withLock { self.onApplyPairingHook }
            self.runOnMain(hook)
        }
    }

    func load() throws -> StoredPairing? {
        self.snapshot().pairing
    }

    func applyPairing(
        _ pairing: StoredPairing,
        ifPairingFlowLease lease: DeviceMigrationPairingFlowLease? = nil,
        shouldCommit: @escaping @Sendable () -> Bool = { true }
    ) throws {
        var pairingCredentialChanged = false
        var pairingWasSaved = false
        do {
        try self.keychainQueue.sync {
            let commit = {
            let previous = self.lock.withLock { (self.state.pairing, self.state.deviceOwnerID) }
            if let lease {
                guard shouldCommit(),
                      try self.migrationStore.ownsPairingFlowLease(lease),
                      previous.1 == lease.ownerID,
                      previous.0?.fingerprint == lease.credentialCID else {
                    throw CancellationError()
                }
            }
            let previousPairing = previous.0
            let previousFingerprint = previousPairing?.fingerprint
            let newIdentity = try DevicePairingIdentity.make(for: pairing)
            let changedCredential = previousFingerprint != pairing.fingerprint
                || previousPairing.flatMap { try? DevicePairingIdentity.make(for: $0) } != newIdentity
            pairingCredentialChanged = changedCredential
            let hadSameJournalBaseline = try self.migrationStore.loadPortable(for: newIdentity).baseline != nil
            let includeFreshPairOffer = changedCredential && (
                previousPairing.flatMap { try? DevicePairingIdentity.make(for: $0) } == newIdentity
                    || (previousPairing == nil && hadSameJournalBaseline)
            )
            let sameOwner = !changedCredential
                && previousPairing.map { (try? DevicePairingIdentity.make(for: $0)) == (try? DevicePairingIdentity.make(for: pairing)) } == true
            let ownerID: UUID
            if sameOwner, let currentOwnerID = previous.1 {
                ownerID = currentOwnerID
            } else {
                ownerID = try self.migrationStore.beginPairingReplacement(
                    from: previous.1,
                    pairing: pairing,
                    includeFreshPairOffer: includeFreshPairOffer,
                    pairingFlowLeaseID: lease?.id
                )
            }

            do {
                try self.confirmationStore.writeMarkerOnApplyPairing()
                try self.savePairingClosure(pairing)
                pairingWasSaved = true
                if changedCredential {
                    try self.migrationStore.finishFreshPairing(
                        pairing: pairing,
                        includeFreshPairOffer: includeFreshPairOffer
                    )
                }
                if changedCredential {
                    try self.deletePushKeyClosure()
                }
                try self.migrationStore.commitPairingReplacement(ownerID: ownerID)
            } catch {
                if !pairingWasSaved {
                    try? self.migrationStore.rollbackPairingReplacement(ownerID: ownerID)
                } else {
                    let pairingOwnerID = (try? self.migrationStore.owns(ownerID: ownerID, pairing: pairing)) == true
                        ? ownerID
                        : nil
                    self.lock.withLock {
                        self.state.pairing = pairing
                        self.state.pairingGeneration &+= 1
                        self.state.accessMutationGeneration &+= 1
                        self.state.pairingIdentity = journalVersionMetadataIdentity(for: pairing)
                        self.state.deviceOwnerID = pairingOwnerID
                        self.state.failedDurableClear = nil
                        self.state.migrationGenerationPending = false
                    }
                }
                throw error
            }
            if self.confirmationStore.firstSettleReadFailed && !self.confirmationStore.hasSettledSuccessfully {
                self.confirmationStore.noteApplyPairingAfterFailedRead()
            }
            self.lock.withLock {
                self.state.pairing = pairing
                self.state.pairingGeneration &+= 1
                self.state.accessMutationGeneration &+= 1
                self.state.liveRelayDisabled = false
                self.state.pairingIdentity = journalVersionMetadataIdentity(for: pairing)
                self.state.deviceOwnerID = ownerID
                self.state.failedDurableClear = nil
                self.state.migrationGenerationPending = false
            }
            }
            if let lease {
                try self.migrationStore.withPairingFlowLease(lease, shouldCommit: shouldCommit) {
                    try commit()
                }
            } else {
                try commit()
            }
        }
        } catch {
            if pairingCredentialChanged && pairingWasSaved {
                let hooks = self.lock.withLock { self.onCredentialReplacementHooks }
                hooks.forEach(self.runOnMain)
            }
            throw error
        }

        if pairingCredentialChanged {
            let hooks = self.lock.withLock { self.onCredentialReplacementHooks }
            hooks.forEach(self.runOnMain)
        }
        let hook = self.lock.withLock { self.onApplyPairingHook }
        self.runOnMain(hook)
    }

    /// Commits a credential already validated by the private migration control session.
    /// All migration metadata is staged before this call; the callback promotes it before
    /// the pairing generation becomes visible to ordinary connection consumers.
    func commitMigratedPairing(
        _ pairing: StoredPairing,
        finalizeMigration: () throws -> Void
    ) throws {
        try self.keychainQueue.sync {
            let current = self.lock.withLock { (self.state.pairing, self.state.deviceOwnerID) }
            guard let ownerID = current.1,
                  try self.migrationStore.owns(ownerID: ownerID) else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            var pairingSaved = false
            do {
                try self.migrationStore.prepareMigrationCredentialCommit(pairing: pairing, ownerID: ownerID)
                if current.0?.fingerprint != pairing.fingerprint {
                    try self.deletePushKeyClosure()
                }
                try self.savePairingClosure(pairing)
                pairingSaved = true
                try finalizeMigration()
                guard try self.migrationStore.owns(ownerID: ownerID, pairing: pairing) else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
            } catch {
                if pairingSaved {
                    self.lock.withLock {
                        self.state.pairing = pairing
                        self.state.pairingIdentity = journalVersionMetadataIdentity(for: pairing)
                        self.state.deviceOwnerID = ownerID
                        self.state.migrationGenerationPending = true
                    }
                }
                throw error
            }
            self.lock.withLock {
                self.state.pairing = pairing
                self.state.pairingGeneration &+= 1
                self.state.accessMutationGeneration &+= 1
                self.state.liveRelayDisabled = false
                self.state.pairingIdentity = journalVersionMetadataIdentity(for: pairing)
                self.state.deviceOwnerID = ownerID
                self.state.failedDurableClear = nil
                self.state.migrationGenerationPending = false
            }
        }

        let hook = self.lock.withLock { self.onApplyPairingHook }
        if let hook {
            if Thread.isMainThread {
                MainActor.assumeIsolated { hook() }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { hook() } }
            }
        }
    }

    @discardableResult
    func commitReadyAccess(
        relayOrigin: String,
        deviceToken: String,
        expiresAt: String?,
        pairingGen: UInt64,
        mutationGen: UInt64,
        mayPublish: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try await self.performMutation(mayPublish: mayPublish) {
            let snap = self.snapshot()
            guard snap.pairingGeneration == pairingGen,
                  snap.accessMutationGeneration == mutationGen,
                  let current = snap.pairing,
                  self.ownsCurrentCredential(snap, pairing: current),
                  Self.isUnexpired(expiresAt) else { return false }
            let updated = Self.replacingAccess(current, origin: relayOrigin,
                enrollment: .enrolled(deviceToken: deviceToken, expiresAt: expiresAt))
            do {
                try self.savePairingClosure(updated)
            } catch {
                storeLog.error("relay access persistence failed")
                return false
            }
            self.lock.withLock {
                self.state.pairing = updated
                self.state.accessMutationGeneration &+= 1
                self.state.liveRelayDisabled = !Self.isUnexpired(expiresAt)
                self.state.failedDurableClear = nil
            }
            return !self.isLiveRelayDisabled
        }
    }

    @discardableResult
    func disableRelayAccess(
        pairingGen: UInt64,
        mutationGen: UInt64,
        mayPublish: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try await self.performMutation(mayPublish: mayPublish) {
            let snap = self.snapshot()
            guard snap.pairingGeneration == pairingGen,
                  snap.accessMutationGeneration == mutationGen,
                  let current = snap.pairing,
                  self.ownsCurrentCredential(snap, pairing: current) else { return false }
            let updated = Self.replacingAccess(current, enrollment: .unavailable)
            let nextMutation = self.lock.withLock {
                self.state.liveRelayDisabled = true
                self.state.accessMutationGeneration &+= 1
                return self.state.accessMutationGeneration
            }
            do {
                try self.savePairingClosure(updated)
            } catch {
                self.lock.withLock {
                    self.state.failedDurableClear = .uncommittedClear(pairingGen: pairingGen, mutationGen: nextMutation)
                }
                throw error
            }
            self.lock.withLock {
                self.state.pairing = updated
                self.state.failedDurableClear = nil
            }
            return true
        }
    }

    @discardableResult
    func retryDurableClear(
        pairingGen: UInt64,
        mutationGen: UInt64,
        mayPublish: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try await self.performMutation(mayPublish: mayPublish) {
            let snap = self.snapshot()
            guard snap.pairingGeneration == pairingGen,
                  snap.accessMutationGeneration == mutationGen,
                  snap.failedDurableClear == .uncommittedClear(pairingGen: pairingGen, mutationGen: mutationGen),
                  let current = snap.pairing,
                  self.ownsCurrentCredential(snap, pairing: current) else { return false }
            let updated = Self.replacingAccess(current, enrollment: .unavailable)
            try self.savePairingClosure(updated)
            self.lock.withLock {
                self.state.pairing = updated
                self.state.failedDurableClear = nil
            }
            return true
        }
    }

    @discardableResult
    func persistRefreshedPairing(
        _ updated: StoredPairing,
        pairingGen: UInt64,
        mutationGen: UInt64,
        mayPublish: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try await self.performMutation(mayPublish: mayPublish) {
            let snap = self.snapshot()
            guard snap.pairingGeneration == pairingGen,
                  snap.accessMutationGeneration == mutationGen,
                  !snap.isLiveRelayDisabled,
                  let current = snap.pairing,
                  current.instanceID == updated.instanceID,
                  current.clientCertPEM == updated.clientCertPEM,
                  current.clientKeyPEM == updated.clientKeyPEM,
                  current.caChainPEM == updated.caChainPEM,
                  self.ownsCurrentCredential(snap, pairing: current),
                  Self.isUnexpired(Self.expiry(of: updated.relayEnrollment)) else { return false }
            do {
                try self.savePairingClosure(updated)
            } catch {
                return false
            }
            self.lock.withLock {
                self.state.pairing = updated
                self.state.accessMutationGeneration &+= 1
                self.state.liveRelayDisabled = !Self.isUnexpired(Self.expiry(of: updated.relayEnrollment))
                self.state.failedDurableClear = nil
            }
            return !self.isLiveRelayDisabled
        }
    }

    @discardableResult
    func revokeIfCurrentGeneration(
        pairingGen: UInt64,
        mutationGen: UInt64,
        mayPublish: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try await self.performMutation(mayPublish: mayPublish) {
            let snap = self.snapshot()
            guard snap.pairingGeneration == pairingGen,
                  snap.accessMutationGeneration == mutationGen,
                  let current = snap.pairing,
                  self.ownsCurrentCredential(snap, pairing: current),
                  let ownerID = snap.deviceOwnerID else { return false }
            let lease = try self.migrationStore.beginInvalidation(ownerID: ownerID)
            self.lock.withLock {
                self.state.deviceOwnerID = nil
                self.state.pairingGeneration &+= 1
                self.state.accessMutationGeneration &+= 1
            }
            let hook = self.lock.withLock { self.onCredentialInvalidationHook }
            self.runOnMain(hook)
            try self.deletePairingClosure()
            try self.clearOwnedState(lease)
            self.publishClearedPairing()
            return true
        }
    }

    func clearPairing() throws {
        let snapshot = self.snapshot()
        let durablePairing = try self.keychainQueue.sync { try self.loadPairingClosure() }
        let invalidation = try self.migrationStore.resumeInvalidation()
        let ownership = try self.migrationStore.ownershipRecord()
        if snapshot.pairing == nil, durablePairing == nil, invalidation == nil,
           ownership.active == nil, ownership.pendingReplacement == nil {
            try self.keychainQueue.sync { try self.deletePairingClosure() }
            return
        }
        let lease = try self.beginPairingInvalidation()
        guard try self.clearPairing(invalidation: lease) else { throw DeviceMigrationStoreError.ownershipUnavailable }
    }

    func beginPairingInvalidation(
        expectedOwnerID: UUID? = nil,
        expectedPairingGeneration: UInt64? = nil
    ) throws -> DeviceMigrationInvalidationLease {
        let lease = try self.keychainQueue.sync {
            let snapshot = self.snapshot()
            if let expectedPairingGeneration {
                guard snapshot.pairingGeneration == expectedPairingGeneration else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
            }
            if let expectedOwnerID {
                guard snapshot.deviceOwnerID == expectedOwnerID,
                      let durablePairing = try self.loadPairingClosure(),
                      try self.migrationStore.owns(ownerID: expectedOwnerID, pairing: durablePairing) else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
            }
            if let lease = try self.migrationStore.resumeInvalidation() {
                guard expectedOwnerID == nil, expectedPairingGeneration == nil else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
                return lease
            }
            let durablePairing = try self.loadPairingClosure()
            let ownership = try self.migrationStore.ownershipRecord()
            let ownerID: UUID?
            if let expectedOwnerID {
                ownerID = expectedOwnerID
            } else if let snapshotOwnerID = snapshot.deviceOwnerID {
                ownerID = snapshotOwnerID
            } else if let activeOwner = ownership.active {
                if let durablePairing {
                    ownerID = (try? self.migrationStore.owns(ownerID: activeOwner.id, pairing: durablePairing)) == true
                        ? activeOwner.id
                        : nil
                } else {
                    ownerID = activeOwner.id
                }
            } else {
                ownerID = nil
            }
            guard let ownerID else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            let lease = try self.migrationStore.beginInvalidation(ownerID: ownerID)
            self.lock.withLock {
                self.state.deviceOwnerID = nil
                self.state.pairingGeneration &+= 1
                self.state.accessMutationGeneration &+= 1
            }
            return lease
        }
        let hook = self.lock.withLock { self.onCredentialInvalidationHook }
        self.runOnMain(hook)
        return lease
    }

    @discardableResult
    func clearPairing(invalidation lease: DeviceMigrationInvalidationLease) throws -> Bool {
        try self.keychainQueue.sync {
            guard try self.migrationStore.ownsInvalidation(lease) else { return false }
            if let pairing = try self.loadPairingClosure() {
                guard try self.durablePairingMatches(lease.owner, pairing: pairing) else { return false }
                try self.deletePairingClosure()
            }
            try self.clearOwnedState(lease)
            self.publishClearedPairing()
            return true
        }
    }

    private func durablePairingMatches(
        _ owner: DeviceMigrationCredentialOwner,
        pairing: StoredPairing
    ) throws -> Bool {
        guard try DevicePairingIdentity.make(for: pairing) == owner.identity else { return false }
        if pairing.fingerprint == owner.credentialCID { return true }

        let portable = try self.migrationStore.loadPortable(for: owner.identity)
        guard let transaction = portable.transaction,
              transaction.pairingOwnerID == owner.id,
              transaction.previousCID == owner.credentialCID,
              transaction.currentCID == pairing.fingerprint,
              transaction.phase == .credentialPrepared || transaction.phase == .credentialCommitted,
              let baseline = portable.baseline,
              baseline.identity == owner.identity,
              baseline.cid == owner.credentialCID,
              let staged = portable.stagedBaseline,
              staged.identity == owner.identity,
              staged.cid == pairing.fingerprint,
              let marker = try self.migrationStore.loadMarker() else { return false }

        let markerMatches: Bool
        switch marker.adoption {
        case .migrating(let identity), .adopted(let identity):
            markerMatches = identity == owner.identity
        case .pending, .none:
            markerMatches = false
        }
        guard markerMatches,
              baseline.deviceMarkerFingerprint == marker.fingerprint,
              staged.deviceMarkerFingerprint == marker.fingerprint else { return false }

        let pending = try self.migrationStore.loadPendingRekey(ownerID: owner.id)
        switch transaction.phase {
        case .credentialPrepared:
            guard let pending,
                  pending.pairingOwnerID == owner.id,
                  pending.previousCID == owner.credentialCID,
                  transaction.rekeyOperationID == nil || transaction.rekeyOperationID == pending.operationID else {
                return false
            }
        case .credentialCommitted:
            guard let operationID = transaction.rekeyOperationID else { return false }
            if let pending {
                guard pending.pairingOwnerID == owner.id,
                      pending.operationID == operationID,
                      pending.previousCID == owner.credentialCID else { return false }
            } else {
                guard let receipt = try self.migrationStore.loadReceipt(ownerID: owner.id),
                      receipt.operationID == operationID,
                      receipt.pairingOwnerID == owner.id,
                      receipt.previousCID == owner.credentialCID,
                      receipt.currentCID == pairing.fingerprint else { return false }
            }
        case .rekeyPending:
            return false
        }
        return true
    }

    private func clearOwnedState(_ lease: DeviceMigrationInvalidationLease) throws {
        try self.confirmationStore.clearRecord()
        try self.deletePushKeyClosure()
        try self.migrationStore.finishInvalidation(lease)
    }

    private func publishClearedPairing() {
        self.lock.withLock {
            self.state.pairing = nil
            self.state.pairingGeneration &+= 1
            self.state.accessMutationGeneration &+= 1
            self.state.liveRelayDisabled = false
            self.state.pairingIdentity = nil
            self.state.deviceOwnerID = nil
            self.state.failedDurableClear = nil
            self.state.migrationGenerationPending = false
        }
    }

    private static func replacingAccess(
        _ pairing: StoredPairing,
        origin: String? = nil,
        enrollment: RelayEnrollment
    ) -> StoredPairing {
        StoredPairing(
            instanceID: pairing.instanceID,
            homeLabel: pairing.homeLabel,
            relayEndpoint: origin ?? pairing.relayEndpoint,
            fingerprint: pairing.fingerprint,
            clientCertPEM: pairing.clientCertPEM,
            clientKeyPEM: pairing.clientKeyPEM,
            caChainPEM: pairing.caChainPEM,
            relayEnrollment: enrollment,
            localEndpoints: pairing.localEndpoints,
            pairedAt: pairing.pairedAt
        )
    }

    private static func expiry(of enrollment: RelayEnrollment) -> String? {
        if case .enrolled(_, let expiresAt) = enrollment { return expiresAt }
        return nil
    }

    private static func isUnexpired(_ expiresAt: String?) -> Bool {
        guard let expiresAt else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        return date.map { $0 > Date() } ?? false
    }
}

nonisolated final class PairingMutationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: ContinuousClock.Instant?

    init(deadline: ContinuousClock.Instant? = nil) {
        self.deadline = deadline
    }

    var isValid: Bool {
        self.lock.withLock { !self.cancelled && (self.deadline.map { ContinuousClock.now < $0 } ?? true) }
    }

    func cancel() {
        self.lock.withLock { self.cancelled = true }
    }
}
