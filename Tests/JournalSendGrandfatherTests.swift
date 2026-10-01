// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CryptoKit
import SPLTunnel
import SwiftUI
import XCTest
import os

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

nonisolated final class JournalSendGrandfatherTests: XCTestCase {
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
    func testPreExistingPairingIsGrandfatheredOnSettle() throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        // Neither confirmation record nor settle marker is present
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalSendGrandfatherTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )

        // AppConfig init calls settle, which grandfathers the pairing
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))
    }

    @MainActor
    func testNewPairingIsNotGrandfathered() throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalSendGrandfatherTests2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )

        XCTAssertFalse(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        // Apply new pairing
        try appConfig.applyPairing(pairing)

        // Settle marker was written on applyPairing, so confirmed remains false
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertFalse(appConfig.journalSendConfirmed)
        XCTAssertFalse(confirmationStore.allowsSend(pairing: pairing))

        // Retry settle does nothing because marker is present
        let retryFlipped = appConfig.retrySettleIfNeeded()
        XCTAssertFalse(retryFlipped)
        XCTAssertFalse(appConfig.journalSendConfirmed)
    }

    @MainActor
    func testFailFirstReadWritesNoMarkerAndNextSettleConfirms() throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory(failFirstRead: true)
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

        // First settle failed on init
        XCTAssertFalse(appConfig.journalSendConfirmed)

        // Next settle succeeds and grandfathers
        let flipped = appConfig.retrySettleIfNeeded()
        XCTAssertTrue(flipped)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))
    }

    @MainActor
    func testFailedFirstReadFollowedByApplyPairingSuppressesGrandfatherOnLaterSettle() throws {
        let pairing = self.makePairing()
        let holder = StoredHolder(pairing)
        let confirmationStore = JournalSendConfirmationStore.memory(failFirstRead: true)
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
        XCTAssertFalse(appConfig.journalSendConfirmed)

        // applyPairing called while first settle failed
        try appConfig.applyPairing(pairing)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        // Later retrySettle does not grandfather because applyPairing was called
        let flipped = appConfig.retrySettleIfNeeded()
        XCTAssertFalse(flipped)
        XCTAssertFalse(appConfig.journalSendConfirmed)
    }

    @MainActor
    func testMarkerWriteFailureInsideApplyPairingThrows() throws {
        let pairing = self.makePairing()
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

        confirmationStore.failNextMarkerWrite()
        XCTAssertThrowsError(try appConfig.applyPairing(pairing))
    }

    @MainActor
    func testFailFirstReadRetrySettleKicksConfirmedSendAndDispatchesQueuedItems() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        PushManagerURLProtocol.callCount = 0
        PushManagerURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        TransferURLProtocol.handler = { request, body in
            let sha1 = SHA256.hash(data: Data("audio1".utf8)).map { String(format: "%02x", $0) }.joined()
            let sha2 = SHA256.hash(data: Data("audio2".utf8)).map { String(format: "%02x", $0) }.joined()
            let sha = body.contains(Data("audio2".utf8)) ? sha2 : sha1
            let json = #"{"status":"ok","file_descriptors":[{"submitted":"audio.m4a","size":6,"sha256":"\#(sha)","disposition":"written"}]}"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }

        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory(failFirstRead: true)
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalSendGrandfatherTests-Kick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )

        // memory(failFirstRead: true), pairing present, AppConfig init leaves journalSendConfirmed false and does not POST
        XCTAssertFalse(appConfig.journalSendConfirmed)
        XCTAssertFalse(confirmationStore.allowsSend(pairing: pairing))

        let resolver = LoopbackTransferEndpointResolver(
            credentials: credentialStore,
            confirmation: confirmationStore
        )
        await resolver.update(activeLocalPort: 7071)

        let spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spoolDir) }

        let spool = TransferSpool(rootURL: spoolDir)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        let transport = TransferTransport(sessionConfiguration: configuration)
        let pacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300))
        let engine = TransferEngine(spool: spool, transport: transport, endpointResolver: resolver, pacer: pacer)

        let itemID1 = UUID()
        let itemID2 = UUID()
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: itemID1, source: "alpha"),
            payloads: ["audio": Data("audio1".utf8)]
        )
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: itemID2, source: "beta"),
            payloads: ["audio": Data("audio2".utf8)]
        )
        try await engine.start()

        let pushSessionConfig = URLSessionConfiguration.ephemeral
        pushSessionConfig.protocolClasses = [PushManagerURLProtocol.self]
        let pushSession = URLSession(configuration: pushSessionConfig)

        let pushDefaults = UserDefaults(suiteName: "GrandfatherPush.\(UUID().uuidString)")!
        pushDefaults.set(true, forKey: "push.ownerEnabled")
        let pushManager = PushNotificationManager(
            journalSendAllowed: { [weak confirmationStore, weak credentialStore] in
                guard let confirmationStore, let credentialStore else { return false }
                return confirmationStore.allowsSend(pairing: credentialStore.snapshot().pairing)
            },
            defaults: pushDefaults,
            session: pushSession,
            keyStore: .memory(),
            retryDelays: [1],
            sleep: { _ in },
            bundleIdentifierOverride: "app.solstone.swift",
            environmentOverride: "development",
            register: {},
            isSimulator: false,
            profileBytes: { nil }
        )
        await pushManager.submitToken(Data([0x12, 0x34]))
        await pushManager.handleTunnelConnected(localPort: 7071)

        // Give dispatch a cycle to try and hold
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)

        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: engine,
            foregroundDrainGate: ForegroundDrainGate(drive: {
                await engine.endpointAvailabilityChanged()
            }),
            pushManager: pushManager
        )

        // retrySettleIfNeeded() on that same instance returns true. No applyPairing in between.
        let flipped = appConfig.retrySettleIfNeeded()
        XCTAssertTrue(flipped)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))

        // Then kickConfirmedSend()
        release.kickConfirmedSend()

        // Wait for both items to POST and push registration to occur
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if TransferURLProtocol.requests.count >= 2 && PushManagerURLProtocol.callCount >= 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        // Both items POST, soonestNextAttemptAt stays nil, push spy sees exactly one /api/push/register, re-ask is false
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        let snapAfter = await engine.snapshot()
        XCTAssertNil(snapAfter.soonestNextAttemptAt)
        XCTAssertEqual(snapAfter.counters.deliveredCount, 2)
        XCTAssertEqual(snapAfter.counters.queuedCount, 0)

        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)
        XCTAssertFalse(HeldJournalReAskDecision.shouldPresent(
            arguments: [],
            scenePhase: .active,
            tunnelState: .connected(localPort: 7071, via: .lan),
            isPaired: appConfig.isPaired,
            journalSendConfirmed: appConfig.journalSendConfirmed,
            presenceCount: 0,
            isShowingPairingSheet: false
        ))

        // Also: failed first read, then credentialStore.applyPairing (not AppConfig.applyPairing), then confirmationStore.settle before AppConfig.applyPairing: outcome is not confirmed, and retrySettleIfNeeded returns false.
        let pairing2 = self.makePairing()
        let holder2 = StoredHolder(pairing2)
        let confirmationStore2 = JournalSendConfirmationStore.memory(failFirstRead: true)
        let credentialStore2 = PairingCredentialStore(
            confirmationStore: confirmationStore2,
            loadPairing: { holder2.stored },
            savePairing: { holder2.stored = $0 },
            deletePairing: { holder2.stored = nil }
        )
        let appConfig2 = AppConfig(
            confirmationStore: confirmationStore2,
            store: credentialStore2
        )
        XCTAssertFalse(appConfig2.journalSendConfirmed)

        try credentialStore2.applyPairing(pairing2)
        let outcome2 = try confirmationStore2.settle(loadPairing: { holder2.stored })
        XCTAssertFalse(outcome2.isConfirmed)
        XCTAssertFalse(appConfig2.retrySettleIfNeeded())
    }

    @MainActor
    func testLockedFirstLaunchFailsInitAndSettleReadsThenRetrySettleGrandfathers() throws {
        let pairing = self.makePairing()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let loadClosure: @Sendable () throws -> StoredPairing? = {
            let count = loadCount.withLock { count -> Int in
                count += 1
                return count
            }
            if count == 1 {
                throw JournalSendConfirmationStoreError.secItemError(errSecInteractionNotAllowed)
            }
            return pairing
        }

        let backing = GrandfatherBacking(failFirstMarkerRead: true)
        let confirmationStore1 = backing.makeConfirmationStore()
        let credentialStore1 = PairingCredentialStore(
            confirmationStore: confirmationStore1,
            loadPairing: loadClosure,
            savePairing: { _ in },
            deletePairing: {}
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrandfatherLockedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig1 = AppConfig(
            confirmationStore: confirmationStore1,
            store: credentialStore1,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )

        // Init spends call 1; settle failed on marker read and did not call loadClosure
        XCTAssertEqual(loadCount.withLock { $0 }, 1)
        XCTAssertFalse(appConfig1.journalSendConfirmed)
        XCTAssertFalse(appConfig1.isPaired)
        XCTAssertNil(backing.record)
        XCTAssertFalse(backing.marker)

        // retrySettleIfNeeded invokes reloadPairingFromKeychain (call 2)
        let flipped = appConfig1.retrySettleIfNeeded()
        XCTAssertTrue(flipped)
        XCTAssertEqual(loadCount.withLock { $0 }, 2)
        XCTAssertTrue(appConfig1.journalSendConfirmed)
        XCTAssertEqual(try credentialStore1.load(), pairing)
        XCTAssertTrue(appConfig1.isPaired)
        XCTAssertFalse(HeldJournalReAskDecision.shouldPresent(
            arguments: [],
            scenePhase: .active,
            tunnelState: .connected(localPort: 7071, via: .lan),
            isPaired: appConfig1.isPaired,
            journalSendConfirmed: appConfig1.journalSendConfirmed,
            presenceCount: 0,
            isShowingPairingSheet: false
        ))

        // Build a new confirmation store from those same closures (fresh process flags), a new credential store, and a new AppConfig
        let confirmationStore2 = backing.makeConfirmationStore()
        let credentialStore2 = PairingCredentialStore(
            confirmationStore: confirmationStore2,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig2 = AppConfig(
            confirmationStore: confirmationStore2,
            store: credentialStore2,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        XCTAssertTrue(appConfig2.journalSendConfirmed)
        XCTAssertTrue(confirmationStore2.allowsSend(pairing: pairing))
    }

    @MainActor
    func testLoaderFailsOnBothInitAndSettleThenSubsequentRetrySettleGrandfathers() throws {
        let pairing = self.makePairing()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let loadClosure: @Sendable () throws -> StoredPairing? = {
            let count = loadCount.withLock { count -> Int in
                count += 1
                return count
            }
            if count <= 2 {
                throw JournalSendConfirmationStoreError.secItemError(errSecInteractionNotAllowed)
            }
            return pairing
        }

        // Marker read always succeeds, marker starts absent, record starts nil
        let backing = GrandfatherBacking(failFirstMarkerRead: false)
        let confirmationStore = backing.makeConfirmationStore()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: loadClosure,
            savePairing: { _ in },
            deletePairing: {}
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrandfatherLoaderFailTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )

        // Init spends call 1 (cache fill), and call 2 during settle (reloadPairingFromKeychain) which throws
        XCTAssertFalse(backing.marker)
        XCTAssertNil(backing.record)
        XCTAssertEqual(loadCount.withLock { $0 }, 2)
        XCTAssertFalse(appConfig.journalSendConfirmed)
        XCTAssertFalse(appConfig.isPaired)

        // retrySettleIfNeeded makes call 3, loads pairing, grandfathers
        let flipped = appConfig.retrySettleIfNeeded()
        XCTAssertTrue(flipped)
        XCTAssertEqual(loadCount.withLock { $0 }, 3)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertEqual(try credentialStore.load(), pairing)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))
    }

    private func makeManifest(
        itemID: UUID = UUID(),
        source: String = "alpha",
        createdAt: Date = Date()
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: source,
            createdAt: createdAt,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: source),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "audio",
                    kind: .audio,
                    relativePath: "audio.m4a",
                    filename: "audio.m4a",
                    contentType: "audio/mp4"
                ),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                segment: "120000_3",
                day: "20260420",
                startedAt: createdAt,
                durationS: 3,
                sources: ["audio"],
                chunkIndex: 0,
                sessionID: itemID,
                modeRawValue: "meeting",
                segmentID: itemID,
                ingestProtocolVersion: 3
            ),
            meta: .object(["kind": .string("test")]),
            nextAttemptAt: nil
        )
    }
}

private final class GrandfatherBacking: @unchecked Sendable {
    private let lock = NSLock()
    var record: String?
    var marker: Bool = false
    var markerReadCount: Int = 0
    var failFirstMarkerRead: Bool

    init(failFirstMarkerRead: Bool = false) {
        self.failFirstMarkerRead = failFirstMarkerRead
    }

    func readMarker() throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.markerReadCount += 1
        if self.failFirstMarkerRead && self.markerReadCount == 1 {
            throw JournalSendConfirmationStoreError.secItemError(errSecInteractionNotAllowed)
        }
        return self.marker
    }

    func writeMarker() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.marker = true
    }

    func deleteMarker() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.marker = false
    }

    func readRecord() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.record
    }

    func writeRecord(_ key: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.record = key
    }

    func deleteRecord() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.record = nil
    }

    func makeConfirmationStore() -> JournalSendConfirmationStore {
        JournalSendConfirmationStore(
            loadRecord: { try self.readRecord() },
            saveRecord: { try self.writeRecord($0) },
            deleteRecord: { self.deleteRecord() },
            loadMarker: { try self.readMarker() },
            saveMarker: { try self.writeMarker() },
            deleteMarker: { self.deleteMarker() }
        )
    }
}

