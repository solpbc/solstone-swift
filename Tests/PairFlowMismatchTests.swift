// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

private final class PairFlowMismatchPairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?

    func load() -> StoredPairing? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pairing
    }

    func save(_ pairing: StoredPairing) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairing = pairing
    }

    func delete() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairing = nil
    }
}

private final class BoolBox: @unchecked Sendable {
    var value = false
}

nonisolated final class PairFlowMismatchTests: XCTestCase {
    @MainActor
    func testMismatchTeardownClearsAppPairingAndDisconnectsTunnel() async throws {
        try? SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }

        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }

        let store = PairFlowMismatchPairingStore()
        let pairing = Self.fixturePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowMismatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        try appConfig.applyPairing(pairing)

        let resolver = LoopbackTransferEndpointResolver(
            credentials: credentials,
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
        let engine = TransferEngine(spool: spool, transport: transport, endpointResolver: resolver)

        let itemID = UUID()
        _ = try await engine.enqueue(
            manifest: Self.makeManifest(itemID: itemID),
            payloads: ["audio": Data("audio".utf8)]
        )
        try await engine.start()

        let tunnel = TunnelManager(
            transport: MockCFTunnelTransport(),
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        tunnel.forceConnected(port: 7071, via: .lan)

        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            pairOperation: { _, _, _, _ in pairing }
        )

        let transportAsked = BoolBox()
        await tearDownMismatchedPairing(
            appConfig: appConfig,
            tunnelManager: tunnel,
            coordinator: coordinator,
            transport: { request in
                transportAsked.value = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )

        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.counters.queuedCount, 1)

        XCTAssertTrue(transportAsked.value)
        XCTAssertFalse(appConfig.isPaired)
        XCTAssertNil(store.load())
        XCTAssertEqual(tunnel.state, .disconnected)
        XCTAssertEqual(coordinator.state, .idle)
    }

    private static func makeManifest(
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

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("endpoints.json")
    }

    private static func fixturePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "instance-123",
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .enrolled(deviceToken: "device-token", expiresAt: nil),
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}
