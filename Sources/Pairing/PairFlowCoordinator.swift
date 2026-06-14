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

    init(
        pairClient: PairClient = PairClient(),
        endpointCache: EndpointCache = EndpointCache()
    ) {
        self.pairClient = pairClient
        self.endpointCache = endpointCache
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
            let message = Self.message(for: error)
            state = .failed(error: message)
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
        state = .idle
    }

    private static func deviceLabel() -> String {
        "\(UIDevice.current.name)'s \(UIDevice.current.model)"
    }

    internal static func message(for error: Error) -> String {
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

        // Existing live cases — unchanged.
        case PairError.lanCAFingerprintMismatch:
            "this isn't your solstone — re-pair if you intended to."
        case PairError.nonceExpired:
            "this pairing code has expired."
        case PairError.pairingWindowClosed:
            "the pairing window closed — generate a new code on your solstone."

        // Default catch-all — lowercase fix folded into this lode for voice
        // consistency (was "Try again.").
        default:
            "pairing failed. try again."
        }
    }
}
