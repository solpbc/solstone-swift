// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import os
import XCTest

private final class StoredHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: StoredPairing?

    init(_ stored: StoredPairing? = nil) {
        self._stored = stored
    }

    var stored: StoredPairing? {
        get { self.lock.withLock { self._stored } }
        set { self.lock.withLock { self._stored = newValue } }
    }
}

nonisolated final class JournalSendProvenanceTests: XCTestCase {
    private func makePairing(instanceID: String = "inst-1") -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
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
    func testJournalSendReleaseAuthorizesAndPersistsConfirmation() async throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalSendProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        try appConfig.applyPairing(pairing)
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
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))
    }

    @MainActor
    func testRePairWhileResolverHasOldPortAndInstanceMismatchWritesNoRecord() async throws {
        let pairing1 = self.makePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing1)
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore
        )
        try appConfig.applyPairing(pairing1)

        let resolver = LoopbackTransferEndpointResolver(
            credentials: credentialStore,
            confirmation: confirmationStore
        )
        await resolver.update(activeLocalPort: 7071)

        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: TransferEngine(spool: TransferSpool(rootURL: FileManager.default.temporaryDirectory), transport: TransferTransport(), endpointResolver: resolver),
            foregroundDrainGate: ForegroundDrainGate(drive: {})
        )

        _ = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: PairFlowCompletionGate(),
            onComplete: {}
        )
        XCTAssertTrue(appConfig.journalSendConfirmed)

        // Re-pair with new instance while resolver still has port 7071
        let pairing2 = self.makePairing(instanceID: "inst-2")
        try appConfig.applyPairing(pairing2)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let descriptor = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest")
        let resHeld = await resolver.resolve(descriptor)
        XCTAssertEqual(resHeld, TransferEndpointResolution.unavailable("journal-send-held"))

        // resolveConfirmation with initial instanceMismatch followed by case-different match
        let attemptsLock = OSAllocatedUnfairLock(initialState: 0)
        let outcome = await resolveConfirmation(
            timeout: .seconds(2),
            step: .milliseconds(10),
            startDeadlineWhenConnected: false,
            connectedPort: { 7071 },
            fetchResult: { _ in
                let attempt = attemptsLock.withLock { count -> Int in
                    count += 1
                    return count
                }
                if attempt == 1 {
                    return .instanceMismatch
                }
                // Case-different match for "inst-2" -> "INST-2"
                return .match(JournalMark.uiTestSample)
            }
        )

        XCTAssertEqual(outcome, .confirm(JournalMark.uiTestSample))
        // Still held before confirmation is authorized
        XCTAssertFalse(appConfig.journalSendConfirmed)
        let resHeldAgain = await resolver.resolve(descriptor)
        XCTAssertEqual(resHeldAgain, TransferEndpointResolution.unavailable("journal-send-held"))

        // Authorize confirmation
        _ = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: PairFlowCompletionGate(),
            onComplete: {}
        )
        XCTAssertTrue(appConfig.journalSendConfirmed)
        let resAvailable = await resolver.resolve(descriptor)
        XCTAssertEqual(
            resAvailable,
            TransferEndpointResolution.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071/")!, port: 7071))
        )
    }
}
