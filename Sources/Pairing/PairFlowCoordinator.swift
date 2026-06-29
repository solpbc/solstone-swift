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

enum PairFlowState: Equatable, Sendable {
    case idle
    case scanning
    case pairing
    case reconnecting
    case failed(error: String)
    case connected
    case alreadyConnected
    case reconnected

    var isPairingInputInProgress: Bool {
        switch self {
        case .pairing, .reconnecting:
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
    var canStartPairingInput: Bool {
        switch state {
        case .idle, .failed:
            true
        case .scanning, .pairing, .reconnecting, .connected, .alreadyConnected, .reconnected:
            false
        }
    }

    private let pairOperation: PairOperation
    private let endpointCache: EndpointCache
    private let networkReader: any OwnNetworkReading

    init(
        pairClient: PairClient = PairClient(),
        endpointCache: EndpointCache = EndpointCache(),
        networkReader: any OwnNetworkReading = GetifaddrsNetworkReader(),
        pairOperation: PairOperation? = nil
    ) {
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

    func handlePairURL(_ pairURL: PairURL) async throws {
        let priorPairing = try? SPLKeychain.load()
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
            if let priorPairing,
               Self.sameInstance(priorPairing.instanceID, pairing.instanceID),
               priorPairing.fingerprint == pairing.fingerprint {
                state = .alreadyConnected
                pairFlowLog.info("pairing completed against existing journal")
                return
            }
            try SPLKeychain.save(pairing)
            await endpointCache.bootstrap(from: pairing)
            state = priorInstance == nil ? .connected : .reconnected
            pairFlowLog.info("pairing saved for \(pairing.homeLabel, privacy: .public)")
        } catch {
            let message: String
            if case PairError.lanCandidatesExhausted(let sawCAFingerprintMismatch) = error {
                message = PairFailureReason.classifyExhausted(
                    sawCAFingerprintMismatch: sawCAFingerprintMismatch,
                    candidateAddresses: pairURL.candidates.map(\.address),
                    interfaces: interfaces
                ).message
            } else {
                message = Self.message(
                    for: error,
                    targetAddress: pairURL.addressString,
                    interfaces: interfaces
                )
            }
            state = .failed(error: message)
            hasAutoPaired = false
            pairFlowLog.error("pairing failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func unpair() async {
        do {
            try SPLKeychain.delete()
        } catch {
            pairFlowLog.error("unpair keychain delete failed: \(String(describing: error), privacy: .public)")
        }
        await endpointCache.wipe()
        hasAutoPaired = false
        state = .idle
    }

    private static func deviceLabel() -> String {
        "\(UIDevice.current.name)'s \(UIDevice.current.model)"
    }

    private static func sameInstance(_ lhs: String?, _ rhs: String) -> Bool {
        lhs?.caseInsensitiveCompare(rhs) == .orderedSame
    }

    internal static func message(for error: Error, targetAddress: String?, interfaces: [IPv4Interface]) -> String {
        switch error {
        // PairURLError surface cases — router pre-validation makes these unreachable
        // via UniversalLinkRouter; reachable only if PairURL.parse is called directly.
        case PairURLError.wrongScheme,
             PairURLError.wrongHost,
             PairURLError.wrongPath,
             PairURLError.missingFragment,
             PairURLError.malformedOuterURL:
            "this doesn't look like a pairing link."

        // Blob-level parse failures — these are the cases this lode is wiring up
        // through UniversalLinkRouter.
        case PairURLError.invalidBase32,
             PairURLError.invalidLength:
            "this pairing link is damaged."
        case PairURLError.invalidVersion:
            "this pairing link is from a newer version of solstone."
        case PairURLError.unsupportedAddrType:
            "this pairing link uses an unsupported address format."
        case PairURLError.unsupportedCAFingerprintTag:
            "this pairing link uses an unsupported verification format."
        case PairURLError.invalidRelayOrigin:
            "this pairing link is damaged."

        case PairError.relayInstanceMismatch:
            "the relay connected to the wrong solstone."

        default:
            PairFailureReason.classify(error: error, targetAddress: targetAddress, interfaces: interfaces).message
        }
    }
}
