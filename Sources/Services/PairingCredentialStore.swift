// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import os

private let storeLog = Logger(subsystem: "app.solstone.swift", category: "pairing-store")

nonisolated final class PairingCredentialStore: @unchecked Sendable {
    private struct State {
        var pairingGeneration: UInt64 = 0
        var accessMutationGeneration: UInt64 = 0
        var liveRelayDisabled: Bool = false
        var pairingIdentity: String? = nil
    }

    private let lock = NSLock()
    private var state = State()

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

    var pairingGeneration: UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state.pairingGeneration
    }

    var accessMutationGeneration: UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state.accessMutationGeneration
    }

    var isLiveRelayDisabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state.liveRelayDisabled
    }

    var pairingIdentity: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.state.pairingIdentity
    }

    func load() throws -> StoredPairing? {
        try self.loadPairingClosure()
    }

    func applyPairing(_ pairing: StoredPairing) throws {
        self.lock.lock()
        defer { self.lock.unlock() }

        try self.savePairingClosure(pairing)

        let newIdentity = journalVersionMetadataIdentity(for: pairing)
        if let newIdentity, self.state.pairingIdentity == newIdentity {
            return
        }

        self.state.pairingGeneration &+= 1
        self.state.accessMutationGeneration &+= 1
        self.state.liveRelayDisabled = false
        self.state.pairingIdentity = newIdentity
    }

    func commitReadyAccess(
        relayOrigin: String,
        deviceToken: String,
        expiresAt: String?,
        pairingGen: UInt64,
        mutationGen: UInt64
    ) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard self.state.pairingGeneration == pairingGen,
              self.state.accessMutationGeneration == mutationGen else {
            return false
        }

        guard let current = try self.loadPairingClosure() else {
            return false
        }

        let updated = StoredPairing(
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

        try self.savePairingClosure(updated)

        self.state.accessMutationGeneration &+= 1
        self.state.liveRelayDisabled = false
        return true
    }

    func disableRelayAccess(pairingGen: UInt64, mutationGen: UInt64) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard self.state.pairingGeneration == pairingGen,
              self.state.accessMutationGeneration == mutationGen else {
            return false
        }

        self.state.liveRelayDisabled = true

        guard let current = try self.loadPairingClosure() else {
            return false
        }

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

        try self.savePairingClosure(updated)

        self.state.accessMutationGeneration &+= 1
        return true
    }

    func persistRefreshedPairing(
        _ updated: StoredPairing,
        pairingGen: UInt64,
        mutationGen: UInt64
    ) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard self.state.pairingGeneration == pairingGen,
              self.state.accessMutationGeneration == mutationGen,
              !self.state.liveRelayDisabled else {
            return false
        }

        try self.savePairingClosure(updated)

        self.state.accessMutationGeneration &+= 1
        return true
    }

    func revokeIfCurrentGeneration(pairingGen: UInt64) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard self.state.pairingGeneration == pairingGen else {
            return false
        }

        try self.deletePairingClosure()

        self.state.pairingGeneration &+= 1
        self.state.accessMutationGeneration &+= 1
        self.state.liveRelayDisabled = false
        self.state.pairingIdentity = nil
        return true
    }

    func clearPairing() throws {
        self.lock.lock()
        defer { self.lock.unlock() }

        try self.deletePairingClosure()
        self.state.pairingGeneration &+= 1
        self.state.accessMutationGeneration &+= 1
        self.state.liveRelayDisabled = false
        self.state.pairingIdentity = nil
    }
}
