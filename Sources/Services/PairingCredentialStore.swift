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
    public let pairingGeneration: UInt64
    public let accessMutationGeneration: UInt64
    public let isLiveRelayDisabled: Bool
    public let failedDurableClear: FailedDurableClearClassification?

    public init(
        pairing: StoredPairing?,
        pairingIdentity: String?,
        pairingGeneration: UInt64,
        accessMutationGeneration: UInt64,
        isLiveRelayDisabled: Bool,
        failedDurableClear: FailedDurableClearClassification?
    ) {
        self.pairing = pairing
        self.pairingIdentity = pairingIdentity
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
        var failedDurableClear: FailedDurableClearClassification? = nil
    }

    private let lock = NSLock()
    private var state = State()
    private let keychainQueue = DispatchQueue(label: "app.solstone.swift.pairing-store.keychain")

    private let loadPairingClosure: @Sendable () throws -> StoredPairing?
    private let savePairingClosure: @Sendable (StoredPairing) throws -> Void
    private let deletePairingClosure: @Sendable () throws -> Void

    init(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLRuntime.keychainStore.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLRuntime.keychainStore.delete() }
    ) {
        self.loadPairingClosure = loadPairing
        self.savePairingClosure = savePairing
        self.deletePairingClosure = deletePairing

        if let existing = try? loadPairing() {
            self.state.pairing = existing
            self.state.pairingIdentity = journalVersionMetadataIdentity(for: existing)
        }
    }

    convenience init(store: SPLKeychainStore) {
        self.init(
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() }
        )
    }

    private func performKeychainWrite<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.keychainQueue.async {
                do {
                    let result = try operation()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performKeychainWriteSync<T>(_ operation: () throws -> T) throws -> T {
        try self.keychainQueue.sync {
            try operation()
        }
    }

    func snapshot() -> PairingCredentialSnapshot {
        self.lock.withLock {
            PairingCredentialSnapshot(
                pairing: self.state.pairing,
                pairingIdentity: self.state.pairingIdentity,
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

    func load() throws -> StoredPairing? {
        self.snapshot().pairing
    }

    func applyPairing(_ pairing: StoredPairing) throws {
        try self.performKeychainWriteSync {
            try self.savePairingClosure(pairing)
        }

        self.lock.withLock {
            let newIdentity = journalVersionMetadataIdentity(for: pairing)
            self.state.pairing = pairing
            self.state.pairingGeneration &+= 1
            self.state.accessMutationGeneration &+= 1
            self.state.liveRelayDisabled = false
            self.state.pairingIdentity = newIdentity
            self.state.failedDurableClear = nil
        }
    }

    @discardableResult
    func commitReadyAccess(
        relayOrigin: String,
        deviceToken: String,
        expiresAt: String?,
        pairingGen: UInt64,
        mutationGen: UInt64
    ) async throws -> Bool {
        let updated: StoredPairing? = self.lock.withLock {
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen,
                  let current = self.state.pairing else {
                return nil
            }
            return StoredPairing(
                instanceID: current.instanceID,
                homeLabel: current.homeLabel,
                relayEndpoint: relayOrigin,
                fingerprint: current.fingerprint,
                clientCertPEM: current.clientCertPEM,
                clientKeyPEM: current.clientKeyPEM,
                caChainPEM: current.caChainPEM,
                relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: expiresAt),
                localEndpoints: current.localEndpoints,
                pairedAt: current.pairedAt
            )
        }
        guard let updated else { return false }

        do {
            try await self.performKeychainWrite {
                try self.savePairingClosure(updated)
            }
        } catch {
            storeLog.error("commitReadyAccess keychain save failed: \(String(describing: error), privacy: .public)")
            return false
        }

        return self.lock.withLock {
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen else {
                return false
            }
            self.state.pairing = updated
            self.state.accessMutationGeneration &+= 1
            self.state.liveRelayDisabled = false
            self.state.failedDurableClear = nil
            return true
        }
    }

    @discardableResult
    func disableRelayAccess(pairingGen: UInt64, mutationGen: UInt64) async throws -> Bool {
        struct PreCheck {
            let updated: StoredPairing
            let newMutationGen: UInt64
        }
        let preCheck: PreCheck? = self.lock.withLock {
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen,
                  let current = self.state.pairing else {
                return nil
            }
            self.state.liveRelayDisabled = true
            self.state.accessMutationGeneration &+= 1
            let newMutationGen = self.state.accessMutationGeneration
            let updated = StoredPairing(
                instanceID: current.instanceID,
                homeLabel: current.homeLabel,
                relayEndpoint: current.relayEndpoint,
                fingerprint: current.fingerprint,
                clientCertPEM: current.clientCertPEM,
                clientKeyPEM: current.clientKeyPEM,
                caChainPEM: current.caChainPEM,
                relayEnrollment: .unavailable,
                localEndpoints: current.localEndpoints,
                pairedAt: current.pairedAt
            )
            return PreCheck(updated: updated, newMutationGen: newMutationGen)
        }
        guard let preCheck else { return false }

        var saveError: (any Error)? = nil
        do {
            try await self.performKeychainWrite {
                try self.savePairingClosure(preCheck.updated)
            }
        } catch {
            saveError = error
        }

        return try self.lock.withLock {
            if let saveError {
                if self.state.pairingGeneration == pairingGen && self.state.accessMutationGeneration == preCheck.newMutationGen {
                    self.state.failedDurableClear = .uncommittedClear(pairingGen: pairingGen, mutationGen: preCheck.newMutationGen)
                }
                throw saveError
            }

            if self.state.pairingGeneration == pairingGen && self.state.accessMutationGeneration == preCheck.newMutationGen {
                self.state.pairing = preCheck.updated
                self.state.failedDurableClear = nil
            }
            return true
        }
    }

    @discardableResult
    func retryDurableClear(pairingGen: UInt64, mutationGen: UInt64) async throws -> Bool {
        let updated: StoredPairing? = self.lock.withLock {
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen,
                  self.state.failedDurableClear == .uncommittedClear(pairingGen: pairingGen, mutationGen: mutationGen),
                  let current = self.state.pairing else {
                return nil
            }
            return StoredPairing(
                instanceID: current.instanceID,
                homeLabel: current.homeLabel,
                relayEndpoint: current.relayEndpoint,
                fingerprint: current.fingerprint,
                clientCertPEM: current.clientCertPEM,
                clientKeyPEM: current.clientKeyPEM,
                caChainPEM: current.caChainPEM,
                relayEnrollment: .unavailable,
                localEndpoints: current.localEndpoints,
                pairedAt: current.pairedAt
            )
        }
        guard let updated else { return false }

        var saveError: (any Error)? = nil
        do {
            try await self.performKeychainWrite {
                try self.savePairingClosure(updated)
            }
        } catch {
            saveError = error
        }

        return try self.lock.withLock {
            if let saveError {
                throw saveError
            }
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen else {
                return false
            }
            self.state.pairing = updated
            self.state.failedDurableClear = nil
            return true
        }
    }

    @discardableResult
    func persistRefreshedPairing(
        _ updated: StoredPairing,
        pairingGen: UInt64,
        mutationGen: UInt64
    ) async throws -> Bool {
        let canPersist = self.lock.withLock {
            self.state.pairingGeneration == pairingGen &&
            self.state.accessMutationGeneration == mutationGen &&
            !self.state.liveRelayDisabled &&
            self.state.pairing?.instanceID == updated.instanceID
        }
        guard canPersist else { return false }

        do {
            try await self.performKeychainWrite {
                try self.savePairingClosure(updated)
            }
        } catch {
            return false
        }

        return self.lock.withLock {
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen,
                  !self.state.liveRelayDisabled,
                  let current = self.state.pairing,
                  current.instanceID == updated.instanceID else {
                return false
            }
            self.state.pairing = updated
            return true
        }
    }

    @discardableResult
    func revokeIfCurrentGeneration(pairingGen: UInt64, mutationGen: UInt64) async throws -> Bool {
        let canRevoke = self.lock.withLock {
            self.state.pairingGeneration == pairingGen &&
            self.state.accessMutationGeneration == mutationGen
        }
        guard canRevoke else { return false }

        do {
            try await self.performKeychainWrite {
                try self.deletePairingClosure()
            }
        } catch {
            return false
        }

        return self.lock.withLock {
            guard self.state.pairingGeneration == pairingGen,
                  self.state.accessMutationGeneration == mutationGen else {
                return false
            }
            self.state.pairing = nil
            self.state.pairingGeneration &+= 1
            self.state.accessMutationGeneration &+= 1
            self.state.liveRelayDisabled = false
            self.state.pairingIdentity = nil
            self.state.failedDurableClear = nil
            return true
        }
    }

    func clearPairing() throws {
        try self.performKeychainWriteSync {
            try self.deletePairingClosure()
        }
        self.lock.withLock {
            self.state.pairing = nil
            self.state.pairingGeneration &+= 1
            self.state.accessMutationGeneration &+= 1
            self.state.liveRelayDisabled = false
            self.state.pairingIdentity = nil
            self.state.failedDurableClear = nil
        }
    }
}
