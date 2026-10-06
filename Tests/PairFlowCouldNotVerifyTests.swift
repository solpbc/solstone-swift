// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

private final class PairFlowCouldNotVerifyPairingStore: @unchecked Sendable {
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

nonisolated final class PairFlowCouldNotVerifyTests: XCTestCase {
    // AC1: timeout outcome transitions phase to .couldNotVerify without completing gate or tearing down
    @MainActor
    func testOutcomeTimeoutTransitionsToCouldNotVerifyWithoutCompletionOrTeardown() {
        var teardownCalled = false
        let gate = PairFlowCompletionGate()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .connecting,
            completionGate: gate,
            tearDown: { teardownCalled = true }
        )

        applicator.apply(.fallback(.timeout))

        XCTAssertEqual(applicator.phase, .couldNotVerify)
        XCTAssertFalse(teardownCalled)

        var count = 0
        applicator.continueAnyway {
            count += 1
        }
        XCTAssertEqual(count, 1)
    }

    // AC2: missingOrInvalidMark outcome transitions phase to .couldNotVerify without completing gate or tearing down
    @MainActor
    func testOutcomeMissingOrInvalidMarkTransitionsToCouldNotVerifyWithoutCompletionOrTeardown() {
        var teardownCalled = false
        let gate = PairFlowCompletionGate()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .connecting,
            completionGate: gate,
            tearDown: { teardownCalled = true }
        )

        applicator.apply(.fallback(.missingOrInvalidMark))

        XCTAssertEqual(applicator.phase, .couldNotVerify)
        XCTAssertFalse(teardownCalled)

        var count = 0
        applicator.continueAnyway {
            count += 1
        }
        XCTAssertEqual(count, 1)
    }

    // AC3: cancelled outcome leaves phase unchanged (.connecting) without completing gate or tearing down
    @MainActor
    func testOutcomeCancelledLeavesPhaseUnchangedWithoutCompletionOrTeardown() {
        var teardownCalled = false
        let gate = PairFlowCompletionGate()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .connecting,
            completionGate: gate,
            tearDown: { teardownCalled = true }
        )

        applicator.apply(.fallback(.cancelled))

        XCTAssertEqual(applicator.phase, .connecting)
        XCTAssertFalse(teardownCalled)

        var count = 0
        applicator.continueAnyway {
            count += 1
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(applicator.phase, .connecting)
    }

    // AC4: continueAnyway delegates through PairFlowCompletionGate exactly once
    @MainActor
    func testContinueAnywayThroughGateFiresOnceAcrossRepeatedAttempts() {
        let gate = PairFlowCompletionGate()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .couldNotVerify,
            completionGate: gate,
            tearDown: {}
        )
        var count = 0

        applicator.continueAnyway {
            count += 1
        }
        applicator.continueAnyway {
            count += 1
        }

        XCTAssertEqual(count, 1)
    }

    // AC5: cancelPairing from couldNotVerify uses real tearDownMismatchedPairing to clear store, disconnect tunnel, and idle coordinator
    @MainActor
    func testCancelPairingClearsAppPairingAndDisconnectsTunnel() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }

        try? SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }

        let store = PairFlowCouldNotVerifyPairingStore()
        let pairing = Self.fixturePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowCouldNotVerifyTests-\(UUID().uuidString)", isDirectory: true)
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
            deletePairing: { store.delete() },
            store: credentials
        )
        tunnel.forceConnected(port: 7071, via: .lan)

        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            pairOperation: { _, _, _, _ in pairing }
        )

        let transportAsked1 = BoolBox()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .couldNotVerify,
            completionGate: PairFlowCompletionGate(),
            tearDown: {
                await tearDownMismatchedPairing(
                    appConfig: appConfig,
                    tunnelManager: tunnel,
                    coordinator: coordinator,
                    transport: { request in
                        transportAsked1.value = true
                        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                        return (Data(), response)
                    }
                )
            }
        )

        await applicator.cancelPairing()

        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.counters.queuedCount, 1)

        XCTAssertTrue(transportAsked1.value)
        XCTAssertFalse(appConfig.isPaired)
        XCTAssertNil(store.load())
        XCTAssertEqual(tunnel.state, .disconnected)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(applicator.phase, .pairing)
    }

    // AC6: reaching couldNotVerify does not clear pairing, disconnect tunnel, or unpair coordinator
    @MainActor
    func testReachingCouldNotVerifyPreservesPairingAndConnection() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }

        let store = PairFlowCouldNotVerifyPairingStore()
        let pairing = Self.fixturePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowCouldNotVerifyPreserve-\(UUID().uuidString)", isDirectory: true)
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

        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

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

        var teardownInvoked = false
        let transportAsked2 = BoolBox()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .connecting,
            completionGate: PairFlowCompletionGate(),
            tearDown: {
                teardownInvoked = true
                await tearDownMismatchedPairing(
                    appConfig: appConfig,
                    tunnelManager: tunnel,
                    coordinator: coordinator,
                    transport: { request in
                        transportAsked2.value = true
                        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                        return (Data(), response)
                    }
                )
            }
        )

        applicator.apply(.fallback(.timeout))
        XCTAssertNotNil(store.load())

        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.counters.queuedCount, 1)
        XCTAssertEqual(snap.counters.inFlightCount, 0)
        XCTAssertEqual(snap.counters.deliveredCount, 0)

        XCTAssertEqual(applicator.phase, .couldNotVerify)
        XCTAssertFalse(teardownInvoked)
        XCTAssertFalse(transportAsked2.value)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertEqual(tunnel.state, .connected(localPort: 7071, via: .lan))
    }

    // AC7: once in couldNotVerify, applying confirm / timeout / missingOrInvalidMark / cancelled must not change phase, complete gate, or teardown
    @MainActor
    func testLateOutcomesAreDiscardedOnceInCouldNotVerify() throws {
        let store = PairFlowCouldNotVerifyPairingStore()
        let pairing = Self.fixturePairing()
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowCouldNotVerifyLate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() },
            confirmationStore: JournalSendConfirmationStore.memory(),
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        try appConfig.applyPairing(pairing)

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

        var teardownCalled = false
        let transportAsked3 = BoolBox()
        let gate = PairFlowCompletionGate()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .couldNotVerify,
            completionGate: gate,
            tearDown: {
                teardownCalled = true
                await tearDownMismatchedPairing(
                    appConfig: appConfig,
                    tunnelManager: tunnel,
                    coordinator: coordinator,
                    transport: { request in
                        transportAsked3.value = true
                        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                        return (Data(), response)
                    }
                )
            }
        )

        applicator.apply(.confirm(.uiTestSample))
        XCTAssertEqual(applicator.phase, .couldNotVerify)

        applicator.apply(.fallback(.timeout))
        XCTAssertEqual(applicator.phase, .couldNotVerify)

        applicator.apply(.fallback(.missingOrInvalidMark))
        XCTAssertEqual(applicator.phase, .couldNotVerify)

        applicator.apply(.fallback(.cancelled))
        XCTAssertEqual(applicator.phase, .couldNotVerify)

        XCTAssertFalse(teardownCalled)
        XCTAssertFalse(transportAsked3.value)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertNotNil(store.load())
        XCTAssertEqual(tunnel.state, .connected(localPort: 7071, via: .lan))
        XCTAssertEqual(coordinator.state, .idle)

        var count = 0
        applicator.continueAnyway {
            count += 1
        }
        XCTAssertEqual(count, 1)
    }

    // AC8: cancelPairing from couldNotVerify returns to .pairing, not .mismatch, and idles coordinator
    @MainActor
    func testCancelPairingReturnsToPairingNotMismatch() async throws {
        let store = PairFlowCouldNotVerifyPairingStore()
        let pairing = Self.fixturePairing()
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowCouldNotVerifyCancelToPairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() },
            confirmationStore: JournalSendConfirmationStore.memory(),
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        try appConfig.applyPairing(pairing)

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

        let transportAsked4 = BoolBox()
        let applicator = PairFlowConfirmationApplicator(
            initialPhase: .couldNotVerify,
            completionGate: PairFlowCompletionGate(),
            tearDown: {
                await tearDownMismatchedPairing(
                    appConfig: appConfig,
                    tunnelManager: tunnel,
                    coordinator: coordinator,
                    transport: { request in
                        transportAsked4.value = true
                        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                        return (Data(), response)
                    }
                )
            }
        )

        await applicator.cancelPairing()

        XCTAssertTrue(transportAsked4.value)
        XCTAssertEqual(applicator.phase, .pairing)
        XCTAssertNotEqual(applicator.phase, .mismatch)
        XCTAssertEqual(coordinator.state, .idle)
    }

    // Vocabulary structural check
    func testCouldNotVerifyDoesNotUseMismatchVocabulary() {
        XCTAssertNotEqual(SourceVocabulary.journalMarkCouldNotVerifyTitle, SourceVocabulary.journalMarkMismatchTitle)
        XCTAssertNotEqual(SourceVocabulary.journalMarkCouldNotVerifyBody, SourceVocabulary.journalMarkMismatchBody)
        XCTAssertNotEqual(SourceVocabulary.journalMarkCouldNotVerifyCancel, SourceVocabulary.journalMarkMismatchScanAgain)
        XCTAssertFalse(SourceVocabulary.journalMarkCouldNotVerifyBody.contains("doesn't match"))
        XCTAssertFalse(SourceVocabulary.journalMarkCouldNotVerifyTitle.contains("not connected"))
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
}
