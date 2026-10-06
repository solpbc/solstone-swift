// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CryptoKit
import SPLTunnel
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

nonisolated final class JournalSendHoldTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalSendHoldTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

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

    @MainActor
    func testQueuedItemsHeldUntilConfirmedThenDispatched() async throws {
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
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let tempDir = self.tempDirectory!
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { tempDir })
        )
        try appConfig.applyPairing(pairing)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let resolver = LoopbackTransferEndpointResolver(
            credentials: credentialStore,
            confirmation: confirmationStore
        )
        await resolver.update(activeLocalPort: 7071)

        let spool = TransferSpool(rootURL: self.tempDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        let transport = TransferTransport(sessionConfiguration: configuration)
        let pacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300))
        let engine = TransferEngine(
            spool: spool,
            transport: transport,
            endpointResolver: resolver,
            pacer: pacer
        )

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

        // Give dispatch a cycle to try and hold
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let initialSnap = await engine.snapshot()
        XCTAssertNil(initialSnap.soonestNextAttemptAt)
        XCTAssertEqual(initialSnap.counters.queuedCount, 2)
        XCTAssertEqual(initialSnap.counters.inFlightCount, 0)

        // Resolve while held
        let heldDescriptor = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest")
        let heldRes = await resolver.resolve(heldDescriptor)
        XCTAssertEqual(heldRes, TransferEndpointResolution.unavailable("journal-send-held"))

        // Port nil resolve
        await resolver.update(activeLocalPort: nil)
        let waitingRes = await resolver.resolve(heldDescriptor)
        XCTAssertEqual(waitingRes, TransferEndpointResolution.unavailable("waiting"))
        await resolver.update(activeLocalPort: 7071)

        let drainGate = ForegroundDrainGate(drive: {
            await engine.endpointAvailabilityChanged()
        })
        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: engine,
            foregroundDrainGate: drainGate
        )

        let didConfirm = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: PairFlowCompletionGate(),
            onComplete: {}
        )
        XCTAssertTrue(didConfirm)
        XCTAssertTrue(appConfig.journalSendConfirmed)

        // Wait for both items to POST
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if TransferURLProtocol.requests.count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        let snapAfter = await engine.snapshot()
        XCTAssertNil(snapAfter.soonestNextAttemptAt)
        XCTAssertEqual(snapAfter.counters.deliveredCount, 2)
        XCTAssertEqual(snapAfter.counters.queuedCount, 0)
    }

    @MainActor
    func testConfirmedPairingRePairReturnsHeld() async throws {
        let pairing1 = self.makePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing1)
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )
        let tempDir = self.tempDirectory!
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            appGroupMirror: AppGroupMirror(rootURLProvider: { tempDir })
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
            transferEngine: TransferEngine(spool: TransferSpool(rootURL: self.tempDirectory), transport: TransferTransport(), endpointResolver: resolver),
            foregroundDrainGate: ForegroundDrainGate(drive: {})
        )

        let didConfirm = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: PairFlowCompletionGate(),
            onComplete: {}
        )
        XCTAssertTrue(didConfirm)
        XCTAssertTrue(appConfig.journalSendConfirmed)

        let descriptor = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest")
        let res1 = await resolver.resolve(descriptor)
        guard case .available(let endpoint) = res1 else {
            return XCTFail("confirmed current pairing must resolve")
        }
        XCTAssertEqual(endpoint.baseURL, URL(string: "http://127.0.0.1:7071/"))
        XCTAssertEqual(endpoint.port, 7071)
        let owner = try XCTUnwrap(endpoint.dispatchOwner)
        let snapshot = credentialStore.snapshot()
        XCTAssertEqual(owner.ownerID, snapshot.deviceOwnerID)
        XCTAssertEqual(owner.pairingGeneration, snapshot.pairingGeneration)
        XCTAssertEqual(owner.credentialCID, pairing1.fingerprint)
        XCTAssertGreaterThan(owner.admissionGeneration, 0)

        // Re-pair with different instance
        let pairing2 = self.makePairing(instanceID: "inst-2")
        try appConfig.applyPairing(pairing2)

        XCTAssertFalse(appConfig.journalSendConfirmed)
        let res2 = await resolver.resolve(descriptor)
        XCTAssertEqual(res2, TransferEndpointResolution.unavailable("journal-send-held"))
        let oldEndpointStillCurrent = await resolver.isCurrent(endpoint)
        XCTAssertFalse(oldEndpointStillCurrent)
    }
}
