// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import SwiftUI
import XCTest

nonisolated final class JournalSendReAskTests: XCTestCase {
    @MainActor
    func testHeldJournalReAskDecisionShouldPresent() {
        let emptyArgs: [String] = []

        // True case
        XCTAssertTrue(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: background or inactive
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .background,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .inactive,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: tunnelState not connected
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connecting,
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .waitingForHome,
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .disconnected,
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: not paired
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: false,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: already confirmed
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: true,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: presenceCount > 0
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 1,
                isShowingPairingSheet: false
            )
        )

        // False: showing pairing sheet
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: true
            )
        )

        // False: test arguments
        for testArg in ["--ui-test", "--integration-test", "--integration-test-live"] {
            XCTAssertFalse(
                HeldJournalReAskDecision.shouldPresent(
                    arguments: [testArg],
                    scenePhase: .active,
                    tunnelState: .connected(localPort: 7071, via: .lan),
                    isPaired: true,
                    journalSendConfirmed: false,
                    presenceCount: 0,
                    isShowingPairingSheet: false
                )
            )
        }
    }

    @MainActor
    func testResolveConfirmationCancelledWithStartDeadlineWhenConnected() async {
        let task = Task { @MainActor in
            await resolveConfirmation(
                timeout: .seconds(10),
                step: .milliseconds(50),
                startDeadlineWhenConnected: true,
                connectedPort: { nil },
                fetchResult: { _ in .missingOrInvalid }
            )
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, ConfirmOutcome.fallback(.cancelled))
    }

    @MainActor
    func testPairFlowViewConfirmHeldJournalRendersConnectingFirstAndCompletesViaYes() throws {
        let onboardingSuite = "test.onboarding.\(UUID().uuidString)"
        let markSuite = "test.mark.\(UUID().uuidString)"
        let onboardingDefaults = UserDefaults(suiteName: onboardingSuite)!
        let markDefaults = UserDefaults(suiteName: markSuite)!
        onboardingDefaults.removePersistentDomain(forName: onboardingSuite)
        markDefaults.removePersistentDomain(forName: markSuite)
        defer {
            onboardingDefaults.removePersistentDomain(forName: onboardingSuite)
            markDefaults.removePersistentDomain(forName: markSuite)
        }

        let pairing = StoredPairing(
            instanceID: "inst-held",
            homeLabel: "Home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")],
            pairedAt: Date()
        )

        let confirmationStore = JournalSendConfirmationStore.memory(initialMarker: true)
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore
        )
        try appConfig.applyPairing(pairing)

        let flow = OnboardingFlow(defaults: onboardingDefaults)
        XCTAssertFalse(flow.isCompleted)

        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: TransferEngine(
                spool: TransferSpool(rootURL: FileManager.default.temporaryDirectory),
                transport: TransferTransport(),
                endpointResolver: LoopbackTransferEndpointResolver(credentials: credentialStore, confirmation: confirmationStore)
            ),
            foregroundDrainGate: ForegroundDrainGate(drive: {})
        )

        let presence = PairFlowPresence()
        let handoff = PairingHandoffState()
        let tunnel = TunnelManager(
            transport: MockCFTunnelTransport(),
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        var renderedPhases: [PairFlowPhase] = []
        var scanPhaseMountedCount = 0
        var pairOperationCount = 0

        let view = PairFlowView(
            startMode: .confirmHeldJournal,
            pairOperation: { _, _, _, _ in
                pairOperationCount += 1
                throw PairError.pairingWindowClosed
            },
            onRenderPhase: { phase in
                renderedPhases.append(phase)
            },
            onScanPhaseMounted: {
                scanPhaseMountedCount += 1
            },
            onBack: {},
            onComplete: {}
        )
        .environment(appConfig)
        .environment(release)
        .environment(presence)
        .environment(handoff)
        .environment(tunnel)

        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()

        window.isHidden = true
        window.rootViewController = nil

        XCTAssertEqual(renderedPhases.first, .connecting)
        XCTAssertFalse(renderedPhases.contains(.pairing))
        XCTAssertEqual(scanPhaseMountedCount, 0)
        XCTAssertEqual(pairOperationCount, 0)

        let markStore = JournalMarkStore(suiteName: markSuite)
        let gate = PairFlowCompletionGate()
        try completeJournalSend(
            mark: .uiTestSample,
            markStore: markStore,
            release: release,
            appConfig: appConfig,
            gate: gate,
            onComplete: {
                flow.completeViaPairing()
            }
        )

        XCTAssertTrue(flow.isCompleted)
        XCTAssertEqual(markStore.load(), .uiTestSample)
        XCTAssertTrue(appConfig.journalSendConfirmed)
    }
}
