// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import XCTest
import os

private final class WiringProbeURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var statusCode: Int = 200
        var responseData: Data = Data(#"{"status":"ok","relay_listen_generation":1}"#.utf8)
        var error: (any Error)? = nil
        var capturedRequests: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset(
        statusCode: Int = 200,
        responseData: Data = Data(#"{"status":"ok","relay_listen_generation":1}"#.utf8),
        error: (any Error)? = nil
    ) {
        self.state.withLock {
            $0 = State(statusCode: statusCode, responseData: responseData, error: error, capturedRequests: [])
        }
    }

    static var capturedRequests: [URLRequest] {
        self.state.withLock { $0.capturedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/app/network/api/status"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = Self.state.withLock { state -> State in
            var updated = state
            updated.capturedRequests.append(self.request)
            state = updated
            return updated
        }

        if let error = current.error {
            self.client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: current.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: current.responseData)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated final class ConnectionStallWiringTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStallWiringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory = self.tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return await condition()
    }

    private func makeCertlessPairing(instanceID: String = "test-instance", pairedAt: Date = Date()) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "Home",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "fingerprint",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 54321, scope: "")],
            pairedAt: pairedAt
        )
    }

    @MainActor
    private func makeWiringManager(
        transport: MockCFTunnelTransport,
        store: PairingCredentialStore,
        probeSession: URLSession
    ) -> TunnelManager {
        let probeWatchdogPolicy = ProbeWatchdogPolicy(
            healthyInterval: .milliseconds(20),
            degradedInterval: .milliseconds(20),
            silentFailureLimit: 2,
            activeInboundFailureLimit: 6,
            forcedReconnectDegradedIntervalCap: .seconds(120)
        )
        return TunnelManager(
            transport: transport,
            endpointCache: EndpointCache(fileURL: self.tempDirectory.appendingPathComponent("endpoints.json")),
            pathMonitor: PathMonitor(),
            loadPairing: { try store.load() },
            savePairing: { try store.applyPairing($0) },
            deletePairing: {},
            store: store,
            deviceTokenRefresher: DeviceTokenRefresher(clientInfo: SPLRuntime.clientInfo),
            connectDeadline: .milliseconds(50),
            clock: LiveTunnelClock(),
            probeSession: probeSession,
            probeURLBuilder: { port in URL(string: "http://127.0.0.1:\(port)/app/network/api/status") },
            probeWatchdogPolicy: probeWatchdogPolicy,
            random: { _ in 1.0 },
            activeLocalTransferCountProvider: { 0 }
        )
    }

    // Acceptance 12: TunnelManager probe wiring with 503, timeout, and 200 OK
    @MainActor
    func testAcceptance12_TunnelProbeWiring() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WiringProbeURLProtocol.self]
        let probeSession = URLSession(configuration: config)
        defer { probeSession.invalidateAndCancel() }

        let pairing = self.makeCertlessPairing()
        let expectedIdentity = try XCTUnwrap(journalVersionMetadataIdentity(for: pairing))

        // 1. 503 handler
        WiringProbeURLProtocol.reset(statusCode: 503)
        let store1 = InMemoryConnectionStallStore()
        let clock1 = ManualConnectionStallClock()
        let creds1 = PairingCredentialStore(loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {}, deletePushKey: {})
        let monitor1 = ConnectionStallMonitor(store: store1, clock: clock1, credentials: creds1)
        let transport1 = MockCFTunnelTransport()
        transport1.nextResult = .success(54321)
        let manager1 = self.makeWiringManager(transport: transport1, store: creds1, probeSession: probeSession)
        manager1.connectionHeardSink = { [weak monitor1] event in
            monitor1?.noteHeard(identity: event.pairingIdentity)
        }

        await manager1.connect()
        let didRun503Probes = await Self.waitUntil { WiringProbeURLProtocol.capturedRequests.count >= 4 }
        XCTAssertTrue(didRun503Probes)
        XCTAssertNil(store1.load().lastHeardFromJournalAt)
        await manager1.disconnect()

        // 2. Timeout handler
        WiringProbeURLProtocol.reset(error: URLError(.timedOut))
        let store2 = InMemoryConnectionStallStore()
        let clock2 = ManualConnectionStallClock()
        let creds2 = PairingCredentialStore(loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {}, deletePushKey: {})
        let monitor2 = ConnectionStallMonitor(store: store2, clock: clock2, credentials: creds2)
        let transport2 = MockCFTunnelTransport()
        transport2.nextResult = .success(54321)
        let manager2 = self.makeWiringManager(transport: transport2, store: creds2, probeSession: probeSession)
        manager2.connectionHeardSink = { [weak monitor2] event in
            monitor2?.noteHeard(identity: event.pairingIdentity)
        }

        await manager2.connect()
        let didRunTimeoutProbes = await Self.waitUntil { WiringProbeURLProtocol.capturedRequests.count >= 4 }
        XCTAssertTrue(didRunTimeoutProbes)
        XCTAssertNil(store2.load().lastHeardFromJournalAt)
        await manager2.disconnect()

        // 3. 200 OK handler
        WiringProbeURLProtocol.reset(statusCode: 200)
        let store3 = InMemoryConnectionStallStore()
        let clock3 = ManualConnectionStallClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let t0 = clock3.now
        let creds3 = PairingCredentialStore(loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {}, deletePushKey: {})
        let monitor3 = ConnectionStallMonitor(store: store3, clock: clock3, credentials: creds3)
        let transport3 = MockCFTunnelTransport()
        transport3.nextResult = .success(54321)
        let manager3 = self.makeWiringManager(transport: transport3, store: creds3, probeSession: probeSession)
        manager3.connectionHeardSink = { [weak monitor3] event in
            monitor3?.noteHeard(identity: event.pairingIdentity)
        }

        await manager3.connect()
        let didRecordFirstHeard = await Self.waitUntil { store3.load().lastHeardFromJournalAt != nil }
        XCTAssertTrue(didRecordFirstHeard)
        XCTAssertEqual(store3.load().lastHeardFromJournalAt, t0)
        XCTAssertEqual(store3.load().lastHeardPairingIdentity, expectedIdentity)

        // Let more probes land
        let reqCountBefore = WiringProbeURLProtocol.capturedRequests.count
        let didRunMoreProbes = await Self.waitUntil { WiringProbeURLProtocol.capturedRequests.count > reqCountBefore + 2 }
        XCTAssertTrue(didRunMoreProbes)
        XCTAssertEqual(store3.load().lastHeardFromJournalAt, t0) // Still t0

        // Advance 60s on monitor clock
        await clock3.advance(by: .seconds(60))
        let t60 = clock3.now
        let didRecordAfterAdvance = await Self.waitUntil { store3.load().lastHeardFromJournalAt == t60 }
        XCTAssertTrue(didRecordAfterAdvance)
        await manager3.disconnect()
    }

    private func makeManifest(
        itemID: UUID = UUID(),
        source: String = "alpha",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        sha256: String
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
            meta: .object(["kind": .string("test")])
        )
    }

    // Acceptance 13: Observer ingest transfer receipt wiring
    func testAcceptance13_ObserverIngestTransferWiring() async throws {
        let root = self.tempDirectory.appendingPathComponent("observer-ingest-wiring", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let itemID = UUID()
        let payload = Data("abc".utf8)
        let expectedSha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        let pairing = self.makeCertlessPairing()
        let expectedIdentity = try XCTUnwrap(journalVersionMetadataIdentity(for: pairing))
        let creds = PairingCredentialStore(loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {}, deletePushKey: {})

        let store = await InMemoryConnectionStallStore()
        let clock = await ManualConnectionStallClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let monitor = await ConnectionStallMonitor(store: store, clock: clock, credentials: creds)

        let dialedIdentityLock = OSAllocatedUnfairLock(initialState: expectedIdentity)
        let heardReporter = ConnectionHeardReporter()
        heardReporter.bind(
            dialedIdentity: {
                dialedIdentityLock.withLock { $0 }
            },
            sink: { event in
                await monitor.noteHeard(identity: event.pairingIdentity)
            }
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransferURLProtocol.self]
        let transport = TransferTransport(sessionConfiguration: config)
        let resolver = TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        let engine = TransferEngine(
            spool: spool,
            transport: transport,
            endpointResolver: resolver,
            clock: FakeTransferClock(wall: Date(timeIntervalSince1970: 1_700_000_000)),
            heardReporter: heardReporter
        )
        try await engine.start()

        // 1. Matching receipt with identity flipped during send
        TransferURLProtocol.handler = { request, _ in
            dialedIdentityLock.withLock { $0 = "different-flipped-identity" }
            let receiptJSON = """
            {
                "status": "ok",
                "file_descriptors": [
                    {
                        "submitted": "audio.m4a",
                        "size": 3,
                        "sha256": "\(expectedSha256)",
                        "disposition": "written"
                    }
                ]
            }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(receiptJSON.utf8))
        }

        let manifest = self.makeManifest(itemID: itemID, sha256: expectedSha256)
        _ = try await engine.enqueue(manifest: manifest, payloads: ["audio": payload])

        let didDeliver = await Self.waitUntil {
            let snap = await store.load()
            return snap.lastHeardFromJournalAt != nil
        }
        XCTAssertTrue(didDeliver)
        let snap = await store.load()
        XCTAssertEqual(snap.lastHeardPairingIdentity, expectedIdentity)

        // 2. Mismatched receipt (uppercased sha256)
        let itemID2 = UUID()
        let store2 = await InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: nil,
            lastHeardPairingIdentity: nil,
            stallClockSeededAt: nil,
            carriedStall: true
        ))
        let monitor2 = await ConnectionStallMonitor(store: store2, clock: clock, credentials: creds)
        let heardReporter2 = ConnectionHeardReporter()
        heardReporter2.bind(
            dialedIdentity: { expectedIdentity },
            sink: { event in
                await monitor2.noteHeard(identity: event.pairingIdentity)
            }
        )
        let engine2 = TransferEngine(
            spool: spool,
            transport: transport,
            endpointResolver: resolver,
            clock: FakeTransferClock(wall: Date(timeIntervalSince1970: 1_700_000_000)),
            heardReporter: heardReporter2
        )
        try await engine2.start()

        TransferURLProtocol.handler = { request, _ in
            let receiptJSON = """
            {
                "status": "ok",
                "file_descriptors": [
                    {
                        "submitted": "audio.m4a",
                        "size": 3,
                        "sha256": "\(expectedSha256.uppercased())",
                        "disposition": "written"
                    }
                ]
            }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(receiptJSON.utf8))
        }

        let manifest2 = self.makeManifest(itemID: itemID2, sha256: expectedSha256)
        _ = try await engine2.enqueue(manifest: manifest2, payloads: ["audio": payload])

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let item = await engine2.itemSnapshot(itemID: itemID2),
               item.state == .attention,
               item.manifest.attention?.reason == "receipt_sha256" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let itemSnap = await engine2.itemSnapshot(itemID: itemID2)
        XCTAssertEqual(itemSnap?.state, .attention)
        XCTAssertEqual(itemSnap?.manifest.attention?.reason, "receipt_sha256")

        let snap2 = await store2.load()
        XCTAssertNil(snap2.lastHeardFromJournalAt)
        XCTAssertTrue(snap2.carriedStall)
    }

    @MainActor
    private func settleTimer(_ clock: ManualConnectionStallClock) async {
        while clock.pendingSleeperCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // Acceptance 14: ConnectionScenePhaseFanout wiring
    @MainActor
    func testAcceptance14_ScenePhaseFanoutWiring() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualConnectionStallClock(now: t0)
        let store = InMemoryConnectionStallStore(snapshot: ConnectionStallSnapshot(
            lastHeardFromJournalAt: t0.addingTimeInterval(-2000),
            lastHeardPairingIdentity: "test-identity",
            stallClockSeededAt: nil,
            carriedStall: false
        ))
        let pairing = self.makeCertlessPairing(pairedAt: t0.addingTimeInterval(-2500))
        let credentials = PairingCredentialStore(loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {}, deletePushKey: {})
        let monitor = ConnectionStallMonitor(store: store, clock: clock, credentials: credentials)
        monitor.setNetworkPathSatisfied(true)

        let transport = MockCFTunnelTransport()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WiringProbeURLProtocol.self]
        let probeSession = URLSession(configuration: config)
        defer { probeSession.invalidateAndCancel() }
        let manager = self.makeWiringManager(transport: transport, store: credentials, probeSession: probeSession)

        ConnectionScenePhaseFanout.deliver(.active, tunnel: manager, monitor: monitor)
        await self.settleTimer(clock)

        XCTAssertTrue(manager.diagnosticSnapshotLines().contains { $0.contains("scene phase: active") })

        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(15))
        await clock.advance(by: .seconds(14))
        monitor.evaluate()
        XCTAssertFalse(monitor.isStalled)

        await clock.advance(by: .seconds(1))
        XCTAssertTrue(monitor.isStalled)
    }
}
