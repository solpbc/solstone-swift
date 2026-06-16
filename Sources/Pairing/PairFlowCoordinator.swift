// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import UIKit
import os

private let pairFlowLog = Logger(subsystem: "app.solstone.swift", category: "pair-flow")

enum SPLPairingConstants {
    static let relayEndpoint = URL(string: "https://link.solstone.app")!
}

enum PairFlowState: Equatable, Sendable {
    case idle
    case scanning
    case entering
    case pairing
    case failed(error: String)
    case success
}

@MainActor
@Observable
final class PairFlowCoordinator {
    var state: PairFlowState = .idle

    private let pairClient: PairClient
    private let endpointCache: EndpointCache
    private let networkReader: any OwnNetworkReading

    init(
        pairClient: PairClient = PairClient(),
        endpointCache: EndpointCache = EndpointCache(),
        networkReader: any OwnNetworkReading = GetifaddrsNetworkReader()
    ) {
        self.pairClient = pairClient
        self.endpointCache = endpointCache
        self.networkReader = networkReader
    }

    func handlePairURL(_ pairURL: PairURL) async throws {
        state = .pairing
        do {
            let pairing = try await pairClient.pair(
                pairURL: pairURL,
                deviceLabel: Self.deviceLabel(),
                relayEndpoint: SPLPairingConstants.relayEndpoint
            )
            try SPLKeychain.save(pairing)
            await endpointCache.bootstrap(from: pairing)
            state = .success
            pairFlowLog.info("pairing saved for \(pairing.homeLabel, privacy: .public)")
        } catch {
            let message = Self.message(
                for: error,
                targetAddress: pairURL.addressString,
                interfaces: networkReader.interfaces()
            )
            state = .failed(error: message)
            pairFlowLog.error("pairing failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func handleManualCode(_ code: String, homeURL: URL) async throws {
        state = .pairing
        do {
            let pairing = try await pairClient.pair(
                manualCode: code,
                homeURL: homeURL,
                deviceLabel: Self.deviceLabel(),
                relayEndpoint: SPLPairingConstants.relayEndpoint
            )
            try SPLKeychain.save(pairing)
            await endpointCache.bootstrap(from: pairing)
            state = .success
            pairFlowLog.info("manual-code pairing saved for \(pairing.homeLabel, privacy: .public)")
        } catch {
            let message = Self.message(
                for: error,
                targetAddress: homeURL.host,
                interfaces: networkReader.interfaces()
            )
            state = .failed(error: message)
            pairFlowLog.error("manual-code pairing failed: \(String(describing: error), privacy: .public)")
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
        state = .idle
    }

    private static func deviceLabel() -> String {
        "\(UIDevice.current.name)'s \(UIDevice.current.model)"
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
