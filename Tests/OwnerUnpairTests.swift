// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CryptoKit
import SPLTunnel
import Security
import XCTest

private final class MockUnpairTransport: @unchecked Sendable {
    private let lock = NSLock()
    var responseStatus: Int = 200
    var shouldThrow: Bool = false
    var sleepDuration: Duration? = nil
    var lastRequestedURL: URL?
    var lastHTTPMethod: String?
    var lastCookieHeader: String?
    var wasPairedDuringRequest: Bool = false
    var callCount: Int = 0
    var checkIsPaired: (@Sendable () -> Bool)? = nil

    func send(request: URLRequest) async throws -> (Data, URLResponse) {
        self.lock.withLock {
            self.callCount += 1
            self.lastRequestedURL = request.url
            self.lastHTTPMethod = request.httpMethod
            self.lastCookieHeader = request.value(forHTTPHeaderField: "Cookie")
            if let check = self.checkIsPaired {
                self.wasPairedDuringRequest = check()
            }
        }
        if let sleepDuration = self.sleepDuration {
            try await Task.sleep(for: sleepDuration)
        }
        if self.shouldThrow {
            throw URLError(.cannotConnectToHost)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: self.responseStatus, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}

private actor PausedUnpairTransport {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var requestURL: URL?

    func send(request: URLRequest) async throws -> (Data, URLResponse) {
        self.requestURL = request.url
        return try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func waitForRequest() async {
        while self.continuation == nil { await Task.yield() }
    }

    func resume(statusCode: Int) {
        guard let continuation = self.continuation,
              let requestURL = self.requestURL,
              let response = HTTPURLResponse(url: requestURL, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
            return
        }
        self.continuation = nil
        continuation.resume(returning: (Data(), response))
    }
}

private final class MemoryPairingStore: @unchecked Sendable {
    private let lock = NSLock()
    var pairing: StoredPairing?
    var deleteCallCount = 0

    init(pairing: StoredPairing?) {
        self.pairing = pairing
    }

    func load() -> StoredPairing? {
        self.lock.withLock { self.pairing }
    }

    func save(_ pairing: StoredPairing) {
        self.lock.withLock { self.pairing = pairing }
    }

    func delete() {
        self.lock.withLock {
            self.pairing = nil
            self.deleteCallCount += 1
        }
    }
}

nonisolated final class OwnerUnpairTests: XCTestCase {
    @MainActor
    func testFailedDurableInvalidationDoesNotRetireOrPresentNewPairFlow() async throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let confirmation = JournalSendConfirmationStore.memory()
        let pairing = StoredPairing(
            instanceID: "invalidation-test-instance",
            homeLabel: "Journal",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:" + String(repeating: "a", count: 64),
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "unused",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = MemoryPairingStore(pairing: nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() },
            deletePushKey: {}
        )
        let appConfig = AppConfig(
            confirmationStore: confirmation,
            store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
        )
        try appConfig.applyPairing(pairing)
        let tunnelTransport = MockCFTunnelTransport()
        let tunnel = TunnelManager(
            transport: tunnelTransport,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        tunnel.forceConnected(port: 9090, via: .lan)
        let suiteName = "OwnerUnpairTests.invalidation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notice = JournalUnpairNoticeStore(defaults: defaults)
        let transport = MockUnpairTransport()
        let generation = credentials.snapshot().pairingGeneration
        persistence.failMutation(after: 0)

        let didUnpair = await unpairForNewPair(
            appConfig: appConfig,
            tunnelManager: tunnel,
            noticeStore: notice,
            transport: { request in try await transport.send(request: request) }
        )

        XCTAssertFalse(didUnpair)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(store.load(), pairing)
        XCTAssertEqual(store.deleteCallCount, 0)
        XCTAssertEqual(credentials.snapshot().pairingGeneration, generation)
        XCTAssertTrue(credentials.hasActiveOwner)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertTrue(tunnel.state.isConnected)
    }

    @MainActor
    func testDelayedOldUnpairCannotClearOrDisconnectFreshSameJournalPairing() async throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let confirmation = JournalSendConfirmationStore.memory()
        let original = Self.makeFixturePairing()
        let fresh = StoredPairing(
            instanceID: original.instanceID,
            homeLabel: original.homeLabel,
            relayEndpoint: original.relayEndpoint,
            fingerprint: "sha256:" + String(repeating: "b", count: 64),
            clientCertPEM: original.clientCertPEM,
            clientKeyPEM: original.clientKeyPEM,
            caChainPEM: original.caChainPEM,
            relayEnrollment: original.relayEnrollment,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 8080, scope: "")],
            pairedAt: original.pairedAt
        )
        let pairingStore = MemoryPairingStore(pairing: nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { pairingStore.load() },
            savePairing: { pairingStore.save($0) },
            deletePairing: { pairingStore.delete() }
        )
        let appConfig = AppConfig(
            confirmationStore: confirmation,
            store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
        )
        try appConfig.applyPairing(original)
        let tunnelTransport = MockCFTunnelTransport()
        let tunnel = TunnelManager(
            transport: tunnelTransport,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            loadPairing: { pairingStore.load() },
            savePairing: { pairingStore.save($0) },
            deletePairing: { pairingStore.delete() },
            store: credentials
        )
        tunnel.forceConnected(port: 9090, via: .lan)
        let suiteName = "OwnerUnpairTests.paused.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let onboarding = OnboardingFlow(defaults: defaults)
        onboarding.completeOnboarding()
        let transport = PausedUnpairTransport()
        let notice = JournalUnpairNoticeStore(defaults: defaults)

        let unpairTask = Task {
            await unpairAndReturnToOnboarding(
                appConfig: appConfig,
                onboardingFlow: onboarding,
                tunnelManager: tunnel,
                noticeStore: notice,
                transport: { request in try await transport.send(request: request) }
            )
        }
        await transport.waitForRequest()

        try appConfig.applyPairing(fresh)
        for _ in 0..<1_000 {
            if tunnel.activeConnection != nil, tunnelTransport.connectCallCount > 0 { break }
            await Task.yield()
        }
        let freshConnection = tunnel.activeConnection
        XCTAssertNotNil(freshConnection)
        await transport.resume(statusCode: 200)
        await unpairTask.value

        XCTAssertEqual(pairingStore.load(), fresh)
        XCTAssertEqual(credentials.snapshot().pairing, fresh)
        XCTAssertTrue(credentials.hasActiveOwner)
        XCTAssertTrue(appConfig.isPaired)
        XCTAssertEqual(tunnel.activeConnection?.epoch, freshConnection?.epoch)
        XCTAssertTrue(onboarding.isCompleted)
        XCTAssertEqual(onboarding.step, .done)
    }

    @MainActor
    func testConnectedDELETEWithCIDAndLoopbackCapability() async throws {
        let leafPEM = CertlessTrustFixtures.leafPEM
        let localEndpoint = LocalEndpoint(host: "192.168.1.10", port: 8080, scope: "")
        let pairing = StoredPairing(
            instanceID: "test-instance",
            homeLabel: "Journal",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:abc",
            clientCertPEM: leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [localEndpoint],
            pairedAt: Date()
        )

        let store = MemoryPairingStore(pairing: pairing)
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmationStore,
            migrationStore: .memory(),
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
        )
        try appConfig.applyPairing(pairing)

        // Tunnel port (9090) differs from localEndpoints.first.port (8080)
        let tunnel = TunnelManager(
            transport: MockCFTunnelTransport(),
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() },
            store: appConfig.store
        )
        tunnel.forceConnected(port: 9090, via: .lan)

        let cert = try XCTUnwrap(CertChain.certificates(fromPEM: leafPEM).first)
        let der = try XCTUnwrap(SecCertificateCopyData(cert) as Data?)
        let cidHex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let expectedURL = "http://127.0.0.1:9090/app/network/api/clients/sha256%3A\(cidHex)"

        let suiteName = "OwnerUnpairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let noticeStore = JournalUnpairNoticeStore(defaults: defaults)

        let transport = MockUnpairTransport()
        transport.responseStatus = 200
        transport.checkIsPaired = { store.load() != nil }

        await ownerUnpair(
            appConfig: appConfig,
            tunnelManager: tunnel,
            notice: noticeStore,
            transport: { try await transport.send(request: $0) }
        )

        XCTAssertFalse(appConfig.isPaired)
        XCTAssertNil(store.load())
        XCTAssertEqual(store.deleteCallCount, 1)
        XCTAssertFalse(noticeStore.isSet)
        XCTAssertTrue(transport.wasPairedDuringRequest)
        XCTAssertEqual(transport.lastHTTPMethod, "DELETE")
        XCTAssertEqual(transport.lastRequestedURL?.absoluteString, expectedURL)
        XCTAssertEqual(transport.lastCookieHeader, LoopbackCapability.process.cookieHeaderValue)
    }

    @MainActor
    func testResponseStatusesAndErrors() async throws {
        let leafPEM = CertlessTrustFixtures.leafPEM

        func makeSetup() throws -> (AppConfig, TunnelManager, JournalUnpairNoticeStore, MemoryPairingStore) {
            let pairing = StoredPairing(
                instanceID: "test-instance",
                homeLabel: "Journal",
                relayEndpoint: "wss://relay.example.com",
                fingerprint: "sha256:abc",
                clientCertPEM: leafPEM,
                clientKeyPEM: "key",
                caChainPEM: CertlessTrustFixtures.caPEM,
                relayEnrollment: .unavailable,
                localEndpoints: [],
                pairedAt: Date()
            )
            let store = MemoryPairingStore(pairing: pairing)
            let confirmationStore = JournalSendConfirmationStore.memory()
            let credentials = PairingCredentialStore(
                confirmationStore: confirmationStore,
                migrationStore: .memory(),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() }
            )
            let appConfig = AppConfig(
                confirmationStore: confirmationStore,
                store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
            )
            try appConfig.applyPairing(pairing)
            let tunnel = TunnelManager(
                transport: MockCFTunnelTransport(),
                endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() },
                store: appConfig.store
            )
            let defaults = UserDefaults(suiteName: "OwnerUnpairTests.\(UUID().uuidString)")!
            let notice = JournalUnpairNoticeStore(defaults: defaults)
            return (appConfig, tunnel, notice, store)
        }

        // 204: clears and does not set notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            tunnel.forceConnected(port: 9090, via: .lan)
            let transport = MockUnpairTransport()
            transport.responseStatus = 204
            await ownerUnpair(appConfig: appConfig, tunnelManager: tunnel, notice: notice, transport: { try await transport.send(request: $0) })
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertFalse(notice.isSet)
        }

        // 404: clears and does not set notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            tunnel.forceConnected(port: 9090, via: .lan)
            let transport = MockUnpairTransport()
            transport.responseStatus = 404
            await ownerUnpair(appConfig: appConfig, tunnelManager: tunnel, notice: notice, transport: { try await transport.send(request: $0) })
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertFalse(notice.isSet)
        }

        // 500: clears and sets notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            tunnel.forceConnected(port: 9090, via: .lan)
            let transport = MockUnpairTransport()
            transport.responseStatus = 500
            await ownerUnpair(appConfig: appConfig, tunnelManager: tunnel, notice: notice, transport: { try await transport.send(request: $0) })
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertTrue(notice.isSet)
        }

        // Thrown error: clears and sets notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            tunnel.forceConnected(port: 9090, via: .lan)
            let transport = MockUnpairTransport()
            transport.shouldThrow = true
            await ownerUnpair(appConfig: appConfig, tunnelManager: tunnel, notice: notice, transport: { try await transport.send(request: $0) })
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertTrue(notice.isSet)
        }

        // Transport that sleeps until cancelled (short timeout): clears inside bound and sets notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            tunnel.forceConnected(port: 9090, via: .lan)
            let transport = MockUnpairTransport()
            transport.sleepDuration = .seconds(2)
            let start = ContinuousClock.now
            await ownerUnpair(
                appConfig: appConfig,
                tunnelManager: tunnel,
                notice: notice,
                transport: { try await transport.send(request: $0) },
                timeout: .milliseconds(50)
            )
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(1))
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertTrue(notice.isSet)
        }

        // Disconnected: sends nothing, returns promptly, sets notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            let transport = MockUnpairTransport()
            await ownerUnpair(appConfig: appConfig, tunnelManager: tunnel, notice: notice, transport: { try await transport.send(request: $0) })
            XCTAssertEqual(transport.callCount, 0)
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertTrue(notice.isSet)
        }

        // Revoked error: sends nothing, returns promptly, does not set notice
        do {
            let (appConfig, tunnel, notice, store) = try makeSetup()
            tunnel.state = .error(.revoked)
            let transport = MockUnpairTransport()
            await ownerUnpair(appConfig: appConfig, tunnelManager: tunnel, notice: notice, transport: { try await transport.send(request: $0) })
            XCTAssertEqual(transport.callCount, 0)
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertNil(store.load())
            XCTAssertFalse(notice.isSet)
        }
    }

    @MainActor
    func testAllUnpairWrappersWithInjectedTransport() async throws {
        // 1. unpairAndReturnToOnboarding
        do {
            let store = MemoryPairingStore(pairing: Self.makeFixturePairing())
            let confirmationStore = JournalSendConfirmationStore.memory()
            let credentials = PairingCredentialStore(
                confirmationStore: confirmationStore,
                migrationStore: .memory(),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() }
            )
            let appConfig = AppConfig(
                confirmationStore: confirmationStore,
                store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
            )
            try appConfig.applyPairing(Self.makeFixturePairing())
            let tunnel = TunnelManager(
                transport: MockCFTunnelTransport(),
                endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() },
                store: appConfig.store
            )
            tunnel.forceConnected(port: 9090, via: .lan)
            let onboarding = OnboardingFlow()
            let notice = JournalUnpairNoticeStore(defaults: UserDefaults(suiteName: "W1.\(UUID().uuidString)")!)
            let transport = MockUnpairTransport()
            transport.responseStatus = 200

            await unpairAndReturnToOnboarding(
                appConfig: appConfig,
                onboardingFlow: onboarding,
                tunnelManager: tunnel,
                noticeStore: notice,
                transport: { try await transport.send(request: $0) }
            )
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertEqual(tunnel.state, .disconnected)
            XCTAssertEqual(onboarding.step, .welcome)
            XCTAssertEqual(transport.callCount, 1)
        }

        // 2. unpairForNewPair (does not reset onboarding)
        do {
            let store = MemoryPairingStore(pairing: Self.makeFixturePairing())
            let confirmationStore = JournalSendConfirmationStore.memory()
            let credentials = PairingCredentialStore(
                confirmationStore: confirmationStore,
                migrationStore: .memory(),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() }
            )
            let appConfig = AppConfig(
                confirmationStore: confirmationStore,
                store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
            )
            try appConfig.applyPairing(Self.makeFixturePairing())
            let tunnel = TunnelManager(
                transport: MockCFTunnelTransport(),
                endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() },
                store: appConfig.store
            )
            tunnel.forceConnected(port: 9090, via: .lan)
            let notice = JournalUnpairNoticeStore(defaults: UserDefaults(suiteName: "W2.\(UUID().uuidString)")!)
            let transport = MockUnpairTransport()
            transport.responseStatus = 200

            await unpairForNewPair(
                appConfig: appConfig,
                tunnelManager: tunnel,
                noticeStore: notice,
                transport: { try await transport.send(request: $0) }
            )
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertEqual(tunnel.state, .disconnected)
            XCTAssertEqual(transport.callCount, 1)
        }

        // 3. unpairThisDevice
        do {
            let store = MemoryPairingStore(pairing: Self.makeFixturePairing())
            let confirmationStore = JournalSendConfirmationStore.memory()
            let credentials = PairingCredentialStore(
                confirmationStore: confirmationStore,
                migrationStore: .memory(),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() }
            )
            let appConfig = AppConfig(
                confirmationStore: confirmationStore,
                store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
            )
            try appConfig.applyPairing(Self.makeFixturePairing())
            let tunnel = TunnelManager(
                transport: MockCFTunnelTransport(),
                endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() },
                store: appConfig.store
            )
            tunnel.forceConnected(port: 9090, via: .lan)
            let onboarding = OnboardingFlow()
            let notice = JournalUnpairNoticeStore(defaults: UserDefaults(suiteName: "W3.\(UUID().uuidString)")!)
            let transport = MockUnpairTransport()
            transport.responseStatus = 200

            await unpairThisDevice(
                appConfig: appConfig,
                onboardingFlow: onboarding,
                tunnelManager: tunnel,
                noticeStore: notice,
                transport: { try await transport.send(request: $0) }
            )
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertEqual(tunnel.state, .disconnected)
            XCTAssertEqual(onboarding.step, .welcome)
            XCTAssertEqual(transport.callCount, 1)
        }

        // 4. tearDownMismatchedPairing
        do {
            let store = MemoryPairingStore(pairing: Self.makeFixturePairing())
            let confirmationStore = JournalSendConfirmationStore.memory()
            let credentials = PairingCredentialStore(
                confirmationStore: confirmationStore,
                migrationStore: .memory(),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() }
            )
            let appConfig = AppConfig(
                confirmationStore: confirmationStore,
                store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
            )
            try appConfig.applyPairing(Self.makeFixturePairing())
            let tunnel = TunnelManager(
                transport: MockCFTunnelTransport(),
                endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                loadPairing: { store.load() },
                savePairing: { store.save($0) },
                deletePairing: { store.delete() },
                store: appConfig.store
            )
            tunnel.forceConnected(port: 9090, via: .lan)
            let coordinator = PairFlowCoordinator(
                endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
                pairOperation: { _, _, _, _ in Self.makeFixturePairing() }
            )
            let notice = JournalUnpairNoticeStore(defaults: UserDefaults(suiteName: "W4.\(UUID().uuidString)")!)
            let transport = MockUnpairTransport()
            transport.responseStatus = 200

            await tearDownMismatchedPairing(
                appConfig: appConfig,
                tunnelManager: tunnel,
                coordinator: coordinator,
                notice: notice,
                transport: { try await transport.send(request: $0) }
            )
            XCTAssertFalse(appConfig.isPaired)
            XCTAssertEqual(tunnel.state, .disconnected)
            XCTAssertEqual(coordinator.state, .idle)
            XCTAssertEqual(transport.callCount, 1)
        }
    }

    @MainActor
    func testNoticeFlagSurvivesAppConfigClearAndOnboardingReset() {
        let defaults = UserDefaults(suiteName: "Survive.\(UUID().uuidString)")!
        let notice = JournalUnpairNoticeStore(defaults: defaults)
        notice.markNotTold()
        XCTAssertTrue(notice.isSet)

        let store = MemoryPairingStore(pairing: nil)
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmationStore,
            migrationStore: .memory(),
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentials,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { Self.tempDir() })
        )
        appConfig.clearPairing()
        XCTAssertTrue(notice.isSet)

        let onboarding = OnboardingFlow()
        onboarding.reset()
        XCTAssertTrue(notice.isSet)

        notice.dismiss()
        XCTAssertFalse(notice.isSet)
    }

    private static func makeFixturePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "test-instance",
            homeLabel: "Journal",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:abc",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date()
        )
    }

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func tempFileURL() -> URL {
        tempDir().appendingPathComponent("endpoints.json")
    }
}
