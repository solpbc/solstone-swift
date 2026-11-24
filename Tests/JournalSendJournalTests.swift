// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import SwiftUI
import XCTest

nonisolated final class JournalSendJournalTests: XCTestCase {
    func testJournalWebPresentationConnectionLostMessage() {
        XCTAssertEqual(
            JournalWebPresentation.connectionLostMessage,
            "lost the connection to your journal. keep the solstone app open and try again."
        )
    }

    func testShouldLoadWebViewRequiresConfirmationAndURL() {
        let testURL = URL(string: "http://127.0.0.1:7071/")!

        // True: confirmed and non-nil URL
        XCTAssertTrue(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: true, resolvedURL: testURL))

        // False: unconfirmed even with non-nil URL
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: false, resolvedURL: testURL))

        // False: confirmed but nil URL
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: true, resolvedURL: nil))

        // False: unconfirmed and nil URL
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: false, resolvedURL: nil))
    }

    func testJournalWebMountCanWaitOnlyForTheSameConfirmedPairingAndPath() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/"))
        let owner = UUID()
        let mount = InAppJournalPresentation.WebMount(url: url, ownerID: owner, path: "/")

        XCTAssertTrue(mount.canWaitForReconnect(confirmed: true, ownerID: owner, path: "/"))
        XCTAssertFalse(mount.canWaitForReconnect(confirmed: false, ownerID: owner, path: "/"))
        XCTAssertFalse(mount.canWaitForReconnect(confirmed: true, ownerID: UUID(), path: "/"))
        XCTAssertFalse(mount.canWaitForReconnect(confirmed: true, ownerID: nil, path: "/"))
        XCTAssertFalse(mount.canWaitForReconnect(confirmed: true, ownerID: owner, path: "/app/network/"))
        let otherURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7072/"))
        XCTAssertNotEqual(mount, .init(url: otherURL, ownerID: owner, path: "/"))
    }

    func testActiveMountChangeActionKeepsLoadedDocumentAndRetriesFailedSamePort() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/"))
        let otherURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7072/"))
        let owner = UUID()
        let mount = InAppJournalPresentation.WebMount(url: url, ownerID: owner, path: "/")
        let otherMount = InAppJournalPresentation.WebMount(url: otherURL, ownerID: owner, path: "/")

        // First mount or changed origin always mounts the new origin.
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: nil, nextActive: mount, mounted: nil, loadState: .loading
            ),
            .mountNew
        )
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: nil, nextActive: otherMount, mounted: mount, loadState: .loaded
            ),
            .mountNew
        )
        // Disconnecting keeps the mounted view in place while waiting for reconnect.
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: mount, nextActive: nil, mounted: mount, loadState: .loaded
            ),
            .keepCurrent
        )
        // Same origin returning while loaded preserves the live document and sessionStorage.
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: nil, nextActive: mount, mounted: mount, loadState: .loaded
            ),
            .keepCurrent
        )
        // Same origin returning after an error or incomplete load retries automatically.
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: nil, nextActive: mount, mounted: mount, loadState: .error(message: "failed")
            ),
            .retryCurrent
        )
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: nil, nextActive: mount, mounted: mount, loadState: .loading
            ),
            .retryCurrent
        )
        // A steady connected error without a disconnect does not spin-reload.
        XCTAssertEqual(
            InAppJournalPresentation.activeMountChangeAction(
                previousActive: mount, nextActive: mount, mounted: mount, loadState: .error(message: "failed")
            ),
            .keepCurrent
        )
    }

    @MainActor
    func testResolvedShellIsPhoneHoldsForegroundShapeDuringBackgroundSnapshots() {
        XCTAssertFalse(
            RootShellView.resolvedShellIsPhone(
                horizontalSizeClass: .regular,
                dynamicTypeSize: .large,
                scenePhase: .active,
                lastForegroundIsPhone: nil
            )
        )
        // Transient compact snapshot while backgrounded keeps the iPad split mounted.
        XCTAssertFalse(
            RootShellView.resolvedShellIsPhone(
                horizontalSizeClass: .compact,
                dynamicTypeSize: .large,
                scenePhase: .background,
                lastForegroundIsPhone: false
            )
        )
        // Transient regular snapshot while backgrounded keeps the compact stack mounted.
        XCTAssertTrue(
            RootShellView.resolvedShellIsPhone(
                horizontalSizeClass: .regular,
                dynamicTypeSize: .large,
                scenePhase: .background,
                lastForegroundIsPhone: true
            )
        )
        // Leaving background immediately honors the live size class again.
        XCTAssertTrue(
            RootShellView.resolvedShellIsPhone(
                horizontalSizeClass: .compact,
                dynamicTypeSize: .large,
                scenePhase: .inactive,
                lastForegroundIsPhone: false
            )
        )
        XCTAssertTrue(
            RootShellView.resolvedShellIsPhone(
                horizontalSizeClass: .compact,
                dynamicTypeSize: .large,
                scenePhase: .active,
                lastForegroundIsPhone: false
            )
        )
        XCTAssertTrue(
            RootShellView.resolvedShellIsPhone(
                horizontalSizeClass: .compact,
                dynamicTypeSize: .large,
                scenePhase: .background,
                lastForegroundIsPhone: nil
            )
        )
    }

    @MainActor
    func testAppConfigConfirmationTransitionsForJournalWebView() throws {
        let pairing = StoredPairing(
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
        let confirmationStore = JournalSendConfirmationStore.memory()
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

        // Held: web view should not load
        XCTAssertFalse(appConfig.journalSendConfirmed)
        let url = URL(string: "http://127.0.0.1:7071/")!
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: appConfig.journalSendConfirmed, resolvedURL: url))

        // Confirm
        try confirmationStore.writeRecord(for: pairing)
        appConfig.journalSendConfirmed = true

        // Confirmed: web view loads
        XCTAssertTrue(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: appConfig.journalSendConfirmed, resolvedURL: url))
    }

    func testInAppJournalPresentationContent() {
        let testURL = URL(string: "http://127.0.0.1:7071/")!

        // Confirmed with valid URL and connected status -> web
        XCTAssertEqual(
            InAppJournalPresentation.content(
                journalSendConfirmed: true,
                resolvedURL: testURL,
                awaitingMarkConfirmation: false,
                status: .connectedIdle,
                isStalled: false
            ),
            .web
        )

        // Awaiting mark confirmation when connected and not stalled -> awaitingMarkConfirmation
        XCTAssertEqual(
            InAppJournalPresentation.content(
                journalSendConfirmed: false,
                resolvedURL: testURL,
                awaitingMarkConfirmation: true,
                status: .connectedIdle,
                isStalled: false
            ),
            .awaitingMarkConfirmation
        )

        // Stalled -> connectionLost even if awaiting
        XCTAssertEqual(
            InAppJournalPresentation.content(
                journalSendConfirmed: false,
                resolvedURL: testURL,
                awaitingMarkConfirmation: true,
                status: .connectedIdle,
                isStalled: true
            ),
            .connectionLost
        )

        // Offline / not connected -> connectionLost
        XCTAssertEqual(
            InAppJournalPresentation.content(
                journalSendConfirmed: false,
                resolvedURL: testURL,
                awaitingMarkConfirmation: true,
                status: .offline,
                isStalled: false
            ),
            .connectionLost
        )

        // Confirmed but nil URL -> connectionLost
        XCTAssertEqual(
            InAppJournalPresentation.content(
                journalSendConfirmed: true,
                resolvedURL: nil,
                awaitingMarkConfirmation: false,
                status: .connectedIdle,
                isStalled: false
            ),
            .connectionLost
        )
    }
}
