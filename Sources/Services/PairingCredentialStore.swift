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
        try self.keychainQueue.sync {
            try self.savePairingClosure(pairing)
            self.lock.withLock {
                self.state.pairing = pairing
                self.state.pairingGeneration &+= 1
                self.state.accessMutationGeneration &+= 1
                self.state.liveRelayDisabled = false
                self.state.pairingIdentity = journalVersionMetadataIdentity(for: pairing)
                self.state.failedDurableClear = nil
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
                  let current = snap.pairing else { return false }
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
                  let current = snap.pairing else { return false }
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
                  snap.accessMutationGeneration == mutationGen else { return false }
            do {
                try self.deletePairingClosure()
            } catch {
                return false
            }
            self.publishClearedPairing()
            return true
        }
    }

    func clearPairing() throws {
        try self.keychainQueue.sync {
            try self.deletePairingClosure()
            self.publishClearedPairing()
        }
    }

    private func publishClearedPairing() {
        self.lock.withLock {
            self.state.pairing = nil
            self.state.pairingGeneration &+= 1
            self.state.accessMutationGeneration &+= 1
            self.state.liveRelayDisabled = false
            self.state.pairingIdentity = nil
            self.state.failedDurableClear = nil
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
