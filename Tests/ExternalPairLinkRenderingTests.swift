// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import SwiftUI
import XCTest

nonisolated final class ExternalPairLinkRenderingTests: XCTestCase {
    private actor PairCallCounter {
        private(set) var count = 0
        func increment() { self.count += 1 }
    }
    @MainActor
    func testStagedPasteNeverMountsScannerAndOrdinaryScanDoes() async throws {
        let handoff = PairingHandoffState()
        for staged in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let confirmation = JournalSendConfirmationStore.memory()
            let credentials = PairingCredentialStore(
                confirmationStore: confirmation, loadPairing: { nil }, savePairing: { _ in }, deletePairing: {}
            )
            let config = AppConfig(confirmationStore: confirmation, store: credentials)
            let release = JournalSendRelease(
                credentialStore: credentials, confirmationStore: confirmation,
                transferEngine: TransferEngine(
                    spool: TransferSpool(rootURL: root), transport: TransferTransport(),
                    endpointResolver: LoopbackTransferEndpointResolver(credentials: credentials, confirmation: confirmation)
                ),
                foregroundDrainGate: ForegroundDrainGate(drive: {})
            )
            if staged {
                handoff.stagedDraft = "https://go.solstone.app/p#\(UniversalLinkRouterTests.canonicalBlob)"
            }
            var scannerMounts = 0
            let pairCalls = PairCallCounter()
            let presence = PairFlowPresence()
            let view = PairFlowView(
                pairOperation: { _, _, _, _ in
                    await pairCalls.increment()
                    throw PairError.pairingWindowClosed
                },
                onScanPhaseMounted: { scannerMounts += 1 }, onBack: {}
            )
            .environment(config)
            .environment(release)
            .environment(presence)
            .environment(handoff)
            .environment(TunnelManager(
                transport: MockCFTunnelTransport(), loadPairing: { nil }, savePairing: { _ in }, deletePairing: {}
            ))
            let host = UIHostingController(rootView: view)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.loadViewIfNeeded()
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let initialPairCalls = await pairCalls.count
            XCTAssertEqual(initialPairCalls, 0)
            if staged {
                XCTAssertEqual(scannerMounts, 0)
                XCTAssertNil(handoff.stagedDraft, "presentation consumes staging into its field")
                ExternalPairLinkIntake.handle(
                    url: URL(string: "https://go.solstone.app/p#\(UniversalLinkRouterTests.wellKnownRelayBlob)")!,
                    pairingHandoff: handoff, appConfig: config
                )
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertNil(handoff.stagedDraft, "the mounted flow consumes a warm arrival")
                XCTAssertEqual(scannerMounts, 0)
                let warmPairCalls = await pairCalls.count
                XCTAssertEqual(warmPairCalls, 0)
                XCTAssertFalse(PairingHandoffPresentation.shouldPresent(
                    pairURL: handoff.pairURL, pairURLError: handoff.pairURLError,
                    stagedDraft: handoff.stagedDraft, presenceCount: presence.count
                ))
            } else {
                XCTAssertGreaterThan(scannerMounts, 0, "the hook must observe an actual scanner mount")
            }
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
