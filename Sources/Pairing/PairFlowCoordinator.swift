// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import UIKit
import os

private let pairFlowLog = Logger(subsystem: "app.solstone.swift", category: "pair-flow")

typealias PairOperation = @Sendable (
    PairURL,
    String,
    URL,
    @Sendable ([PairCandidate]) -> [PairCandidate]
) async throws -> StoredPairing

enum SPLPairingConstants {
    static let relayEndpoint = URL(string: "https://link.solstone.app")!
}

/// A ceremony that finished while this device has a pairing, kept in memory until the owner answers
/// about its mark. Nothing stored has changed: the current pairing, its tunnel and its mark all
/// carry on, and quitting the app simply loses this.
struct HeldReplacement: Equatable, Sendable {
    let pairing: StoredPairing
    let lease: DeviceMigrationPairingFlowLease
}

enum PairFlowState: Equatable, Sendable {
    case idle
    case scanning
    case pairing
    case reconnecting
    case heldForAnswer
    case failed(error: String)
    case connected
    case alreadyConnected
    case reconnected

    var isPairingInputInProgress: Bool {
        switch self {
        case .pairing, .reconnecting, .heldForAnswer:
            return true
        case .idle, .scanning, .failed, .connected, .alreadyConnected, .reconnected:
            return false
        }
    }
}

@MainActor
@Observable
final class PairFlowCoordinator {
    var state: PairFlowState = .idle
    var hasAutoPaired = false
    private(set) var pairingFlowGeneration: UInt64 = 0
    private(set) var heldReplacement: HeldReplacement?
    var canStartPairingInput: Bool {
        switch state {
        case .idle, .failed:
            true
        case .scanning, .pairing, .reconnecting, .heldForAnswer, .connected, .alreadyConnected, .reconnected:
            false
        }
    }

    private let store: PairingCredentialStore
    private let pairOperation: PairOperation
    private let endpointCache: EndpointCache
    private let networkReader: any OwnNetworkReading

    init(
        store: PairingCredentialStore = SPLRuntime.pairingStore,
        pairClient: PairClient = PairClient(clientInfo: SPLRuntime.clientInfo),
        endpointCache: EndpointCache = .shared,
        networkReader: any OwnNetworkReading = GetifaddrsNetworkReader(),
        pairOperation: PairOperation? = nil
    ) {
        self.store = store
        if let pairOperation {
            self.pairOperation = pairOperation
        } else {
            self.pairOperation = { pairURL, deviceLabel, relayEndpoint, orderCandidates in
                try await pairClient.pair(
                    pairURL: pairURL,
                    deviceLabel: deviceLabel,
                    relayEndpoint: relayEndpoint,
                    orderCandidates: orderCandidates
                )
            }
        }
        self.endpointCache = endpointCache
        self.networkReader = networkReader
    }

    func handlePairURL(
        _ pairURL: PairURL,
        shouldCommit: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        let lease = try self.store.beginPairingFlow()
        self.pairingFlowGeneration &+= 1
        let flowGeneration = self.pairingFlowGeneration
        let priorPairing = try? self.store.load()
        let priorInstance = priorPairing?.instanceID

        state = priorInstance == nil ? .pairing : .reconnecting
        let interfaces = networkReader.interfaces()
        do {
            let pairing = try await pairOperation(
                pairURL,
                Self.deviceLabel(),
                SPLPairingConstants.relayEndpoint,
                { orderCandidatesBySubnet($0, interfaces: interfaces) }
            )
            guard !Task.isCancelled,
                  shouldCommit(),
                  (try? self.store.migrationStore.ownsPairingFlowLease(lease)) == true else {
                throw CancellationError()
            }
            if let priorPairing,
               journalInstanceIDsMatch(priorPairing.instanceID, pairing.instanceID),
               priorPairing.fingerprint == pairing.fingerprint {
                state = .alreadyConnected
                pairFlowLog.info("pairing completed against existing journal")
                return true
            }
            // why: applying here would replace a pairing that may be healthy before the owner has
            // seen the new mark, and an owner who answers no would have lost it.
            if priorPairing != nil {
                self.heldReplacement = HeldReplacement(pairing: pairing, lease: lease)
                state = .heldForAnswer
                pairFlowLog.info("pairing held for the owner's answer")
                return true
            }
            try self.store.applyPairing(
                pairing,
                ifPairingFlowLease: lease,
                shouldCommit: { !Task.isCancelled && shouldCommit() }
            )
            let committedGeneration = self.store.pairingGeneration
            let committedOwnerID = self.store.snapshot().deviceOwnerID
            await endpointCache.bootstrap(from: pairing)
            guard !Task.isCancelled,
                  shouldCommit(),
                  (try? self.store.migrationStore.ownsPairingFlowLease(lease)) == true,
                  self.store.pairingGeneration == committedGeneration,
                  self.pairingFlowGeneration == flowGeneration,
                  self.store.snapshot().deviceOwnerID == committedOwnerID,
                  let committedOwnerID,
                  (try? self.store.migrationStore.owns(ownerID: committedOwnerID, pairing: pairing)) == true,
                  self.store.snapshot().pairing?.fingerprint == pairing.fingerprint,
                  shouldCommit() else { return false }
            state = .connected
            pairFlowLog.info("pairing saved for \(pairing.homeLabel, privacy: .public)")
            return true
        } catch {
            if error is CancellationError { return false }
            guard (try? self.store.migrationStore.ownsPairingFlowLease(lease)) == true else { return false }
            let message: String
            if case PairError.lanCandidatesExhausted(let sawCAFingerprintMismatch) = error {
                message = PairFailureReason.classifyExhausted(
                    sawCAFingerprintMismatch: sawCAFingerprintMismatch,
                    candidateAddresses: pairURL.candidates.map(\.address),
                    interfaces: interfaces
                ).showingPorts(of: pairURL.candidates).message
            } else {
                message = Self.message(
                    for: error,
                    targetAddress: pairURL.candidates.first?.address ?? "",
                    targetPort: pairURL.candidates.first?.port,
                    interfaces: interfaces
                )
            }
            state = .failed(error: message)
            hasAutoPaired = false
            pairFlowLog.error("pairing failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The owner answered yes. The answer goes in with the pairing, so neither lands without the
    /// other. Replacing a pairing in place does not tell the previous journal. A changed certificate
    /// fingerprint rotates the push key, so the new journal receives a fresh key. The previous
    /// journal can keep sending the fixed fallback line until the owner removes this phone there.
    func commitHeldReplacement() async throws -> StoredPairing? {
        guard let held = self.heldReplacement else { return nil }
        do {
            try self.store.applyPairing(held.pairing, ifPairingFlowLease: held.lease, recordingOwnerAnswer: true)
        } catch {
            // Past the save the pairing has landed, and only the answer on it can still be retried.
            if self.store.snapshot().pairing?.fingerprint == held.pairing.fingerprint {
                self.heldReplacement = nil
                self.state = .reconnected
            }
            pairFlowLog.error("held pairing failed to commit: \(String(describing: error), privacy: .public)")
            throw error
        }
        self.heldReplacement = nil
        await self.endpointCache.bootstrap(from: held.pairing)
        self.state = .reconnected
        pairFlowLog.info("pairing saved for \(held.pairing.homeLabel, privacy: .public)")
        return held.pairing
    }

    /// The owner answered no, cancelled or left. Only the memory goes: nothing stored ever changed.
    func dropHeldReplacement() {
        guard self.heldReplacement != nil else { return }
        self.heldReplacement = nil
        self.hasAutoPaired = false
        self.state = .idle
    }

    func unpair() async {
        self.pairingFlowGeneration &+= 1
        do {
            try self.store.clearPairing()
        } catch {
            pairFlowLog.error("unpair keychain delete failed: \(String(describing: error), privacy: .public)")
            return
        }
        await endpointCache.wipe()
        hasAutoPaired = false
        state = .idle
    }

    @discardableResult
    func reflectUnpairedIfClear(
        expectedFlowGeneration: UInt64,
        expectedPairingGeneration: UInt64
    ) -> Bool {
        let snapshot = self.store.snapshot()
        guard self.pairingFlowGeneration == expectedFlowGeneration,
              snapshot.pairingGeneration == expectedPairingGeneration,
              snapshot.pairing == nil,
              snapshot.deviceOwnerID == nil else { return false }
        self.hasAutoPaired = false
        self.state = .idle
        return true
    }

    static func deviceLabel() -> String {
        DeviceRegistrationDescriptor.currentDisplayName()
    }

    internal static func message(
        for error: Error,
        targetAddress: String?,
        targetPort: UInt16? = nil,
        interfaces: [IPv4Interface]
    ) -> String {
        switch error {
        // PairURLError surface cases — router pre-validation makes these unreachable
        // via UniversalLinkRouter; reachable only if PairURL.parse is called directly.
        case PairURLError.wrongScheme,
             PairURLError.wrongHost,
             PairURLError.wrongPath,
             PairURLError.missingFragment,
             PairURLError.malformedOuterURL:
            "this doesn't look like a pairing link."

        // Blob-level parse failures.
        case PairURLError.invalidBase32,
             PairURLError.truncated,
             PairURLError.lengthMismatch,
             PairURLError.invalidCandidateCount:
            "this pairing link is damaged."
        case PairURLError.invalidVersion:
            "this pairing link is from a newer version of your journal."
        case PairURLError.unsupportedAddrType:
            "this pairing link uses an unsupported address format."
        case PairURLError.unsupportedCAFingerprintTag:
            "this pairing link uses an unsupported verification format."
        case PairURLError.invalidRelayOrigin:
            "this pairing link is damaged."

        default:
            PairFailureReason.classify(error: error, targetAddress: targetAddress, interfaces: interfaces)
                .showingPorts(of: targetAddress.flatMap { address in
                    targetPort.map { [PairCandidate(address: address, port: $0)] }
                } ?? [])
                .message
        }
    }
}
