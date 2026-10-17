// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

@MainActor
final class WelcomeSetupRouteTests: XCTestCase {
    private func makeIsolatedEnvironment() -> (OnboardingFlow, AppConfig, UserDefaults, String) {
        let suiteName = "WelcomeSetupRouteTests-\(UUID().uuidString)"
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

    private func makePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "inst-1",
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
    }

    @MainActor
    func testSetOneUpShareLinkAndCancelPairingLeaveStateUnchanged() {
        let (onboarding, appConfig, defaults, suiteName) = self.makeIsolatedEnvironment()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let setURL = WelcomeSetup.setOneUp(onboarding: onboarding, appConfig: appConfig)
        XCTAssertEqual(setURL, JournalSetupLink.installURL)
        XCTAssertFalse(onboarding.isCompleted)
        XCTAssertFalse(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let shareURL = WelcomeSetup.shareLink(onboarding: onboarding, appConfig: appConfig)
        XCTAssertEqual(shareURL, JournalSetupLink.installURL)
        XCTAssertFalse(onboarding.isCompleted)
        XCTAssertFalse(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        WelcomeSetup.cancelPairing(onboarding: onboarding)
        XCTAssertFalse(onboarding.isCompleted)
        XCTAssertFalse(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)
    }

    @MainActor
    func testNotNowSetsIsCompleted() {
        let (onboarding, _, defaults, suiteName) = self.makeIsolatedEnvironment()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(onboarding.isCompleted)
        WelcomeSetup.notNow(onboarding: onboarding)
        XCTAssertTrue(onboarding.isCompleted)
        XCTAssertEqual(onboarding.step, .done)
    }

    @MainActor
    func testFinishIfMarkConfirmedRefusesWhenPairedWithoutConfirmation() throws {
        let (onboarding, appConfig, defaults, suiteName) = self.makeIsolatedEnvironment()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pairing = self.makePairing()
        try appConfig.applyPairing(pairing)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let finished = WelcomeSetup.finishIfMarkConfirmed(onboarding: onboarding, appConfig: appConfig)
        XCTAssertFalse(finished)
        XCTAssertFalse(onboarding.isCompleted)
    }

    @MainActor
    func testFinishIfMarkConfirmedCompletesWhenAuthorized() async throws {
        let suiteName = "WelcomeSetupRouteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let onboarding = OnboardingFlow(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WelcomeSetupRouteTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        try appConfig.applyPairing(pairing)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let spool = try TransferSpool(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transferEngine = TransferEngine(
            spool: spool,
            transport: TransferTransport(),
            endpointResolver: LoopbackTransferEndpointResolver(credentials: credentialStore, confirmation: confirmationStore)
        )
        let foregroundDrainGate = ForegroundDrainGate(drive: {})
        let pushManager = PushNotificationManager(
            journalSendAllowed: { confirmationStore.allowsSend(pairing: credentialStore.snapshot().pairing) }
        )
        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: transferEngine,
            foregroundDrainGate: foregroundDrainGate,
            pushManager: pushManager
        )

        try release.authorize(appConfig, writeMarker: false)
        XCTAssertTrue(appConfig.journalSendConfirmed)

        let finished = WelcomeSetup.finishIfMarkConfirmed(onboarding: onboarding, appConfig: appConfig)
        XCTAssertTrue(finished)
        XCTAssertTrue(onboarding.isCompleted)
    }
}
