// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

@MainActor
final class ExternalPairLinkStagingTests: XCTestCase {
    private func makeIsolatedEnvironment() -> (OnboardingFlow, AppConfig, UserDefaults, String) {
        let suiteName = "ExternalPairLinkStagingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let onboarding = OnboardingFlow(defaults: defaults)

        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore
        )
        return (onboarding, appConfig, defaults, suiteName)
    }

    func testStageExternalLinkWithAliasAndCanonicalHTTPS() {
        let (onboarding, appConfig, defaults, suiteName) = self.makeIsolatedEnvironment()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let handoff = PairingHandoffState()
        let aliasURL = URL(string: "solstone://pair#\(UniversalLinkRouterTests.canonicalBlob)")!
        let aliasStaged = handoff.stageExternalLink(aliasURL)

        XCTAssertTrue(aliasStaged)
        XCTAssertEqual(handoff.stagedDraft, aliasURL.absoluteString)
        XCTAssertNil(handoff.pairURL)
        XCTAssertFalse(appConfig.journalSendConfirmed)
        XCTAssertFalse(onboarding.isCompleted)

        let relayHTTPS = URL(string: "https://go.solstone.app/p#\(UniversalLinkRouterTests.wellKnownRelayBlob)")!
        let relayStaged = handoff.stageExternalLink(relayHTTPS)

        XCTAssertTrue(relayStaged)
        XCTAssertEqual(handoff.stagedDraft, relayHTTPS.absoluteString)
        XCTAssertNil(handoff.pairURL)
        XCTAssertFalse(appConfig.journalSendConfirmed)
        XCTAssertFalse(onboarding.isCompleted)
    }

    func testSecondCallWithSameURLLeavesPairURLNilAndSingleDraft() {
        let handoff = PairingHandoffState()
        let aliasURL = URL(string: "solstone://pair#\(UniversalLinkRouterTests.canonicalBlob)")!

        XCTAssertTrue(handoff.stageExternalLink(aliasURL))
        XCTAssertEqual(handoff.stagedDraft, aliasURL.absoluteString)
        XCTAssertNil(handoff.pairURL)

        XCTAssertTrue(handoff.stageExternalLink(aliasURL))
        XCTAssertEqual(handoff.stagedDraft, aliasURL.absoluteString)
        XCTAssertNil(handoff.pairURL)
    }

    func testColdCollectAndStageThenWarmIntakeLeavesOneDraftAndPairURLNil() {
        let (_, appConfig, defaults, suiteName) = self.makeIsolatedEnvironment()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = ExternalPairLinkQueue.shared.drain()
        let handoff = PairingHandoffState()
        let aliasURL = URL(string: "solstone://pair#\(UniversalLinkRouterTests.canonicalBlob)")!

        let collected = ExternalPairLinkIntake.collect(urlContextURLs: [aliasURL], browsingWebURLs: [])
        XCTAssertEqual(collected, [aliasURL])

        ExternalPairLinkQueue.shared.enqueue(collected)
        let drained = ExternalPairLinkQueue.shared.drain()

        for url in drained {
            ExternalPairLinkIntake.handle(url: url, pairingHandoff: handoff, appConfig: appConfig)
        }
        XCTAssertEqual(handoff.stagedDraft, aliasURL.absoluteString)
        XCTAssertNil(handoff.pairURL)

        ExternalPairLinkIntake.handle(url: aliasURL, pairingHandoff: handoff, appConfig: appConfig)
        XCTAssertEqual(handoff.stagedDraft, aliasURL.absoluteString)
        XCTAssertNil(handoff.pairURL)
    }

    func testBusyStatesRefuseStagingAndLeaveStateUnchanged() {
        let aliasURL = URL(string: "solstone://pair#\(UniversalLinkRouterTests.canonicalBlob)")!

        // 1. externalLinkAttemptInFlight
        let handoff1 = PairingHandoffState()
        handoff1.stagedDraft = "initial-1"
        handoff1.externalLinkAttemptInFlight = true
        XCTAssertFalse(handoff1.stageExternalLink(aliasURL))
        XCTAssertEqual(handoff1.stagedDraft, "initial-1")
        XCTAssertNil(handoff1.pairURL)

        // 2. heldMarkConfirmation
        let handoff2 = PairingHandoffState()
        handoff2.stagedDraft = "initial-2"
        handoff2.heldMarkConfirmation = true
        XCTAssertFalse(handoff2.stageExternalLink(aliasURL))
        XCTAssertEqual(handoff2.stagedDraft, "initial-2")
        XCTAssertNil(handoff2.pairURL)

        // 3. pairingInProgress
        let handoff3 = PairingHandoffState()
        handoff3.stagedDraft = "initial-3"
        handoff3.pairingInProgress = true
        XCTAssertFalse(handoff3.stageExternalLink(aliasURL))
        XCTAssertEqual(handoff3.stagedDraft, "initial-3")
        XCTAssertNil(handoff3.pairURL)
    }

    func testSolstoneDeepLinksNotClaimedByStageExternalLink() {
        let handoff = PairingHandoffState()

        let journalURL = URL(string: "solstone://journal")!
        XCTAssertFalse(handoff.stageExternalLink(journalURL))
        XCTAssertNil(handoff.stagedDraft)
        XCTAssertNil(handoff.pairURL)
        XCTAssertEqual(SolstoneDeepLink.parse(journalURL), .journal)

        let stopURL = URL(string: "solstone://observer/stop")!
        XCTAssertFalse(handoff.stageExternalLink(stopURL))
        XCTAssertNil(handoff.stagedDraft)
        XCTAssertNil(handoff.pairURL)
        XCTAssertEqual(SolstoneDeepLink.parse(stopURL), .observerStop)
    }

    func testPercentEncodedAliasShowsErrorWithoutStoringDraft() {
        let handoff = PairingHandoffState()
        let badAlias = URL(string: "solstone://pair#%30" + UniversalLinkRouterTests.canonicalBlob.dropFirst())!

        XCTAssertTrue(handoff.stageExternalLink(badAlias))
        XCTAssertNil(handoff.stagedDraft)
        XCTAssertNil(handoff.pairURL)
        XCTAssertNotNil(handoff.pairURLError)
    }

    func testPersistedUnansweredMarkRejectsArrivalAfterPresentationFlagsClear() throws {
        let (_, appConfig, defaults, suiteName) = self.makeIsolatedEnvironment()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pairing = StoredPairing(
            instanceID: "held-journal", homeLabel: "Home", relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM, clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM, relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")], pairedAt: Date()
        )
        try appConfig.applyPairing(pairing)
        XCTAssertTrue(appConfig.awaitingMarkConfirmation)
        let handoff = PairingHandoffState()
        ExternalPairLinkIntake.handle(
            url: URL(string: "solstone://pair#\(UniversalLinkRouterTests.canonicalBlob)")!,
            pairingHandoff: handoff, appConfig: appConfig
        )
        XCTAssertNil(handoff.stagedDraft)
        XCTAssertNil(handoff.pairURL)
        XCTAssertNil(handoff.pairURLError)
        XCTAssertTrue(appConfig.awaitingMarkConfirmation)
        XCTAssertEqual(appConfig.loadStoredPairing()?.instanceID, pairing.instanceID)
    }
}
