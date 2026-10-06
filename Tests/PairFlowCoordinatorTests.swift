// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
// Reaches SPLTunnel package internals; relies on Xcode compiling SPM products with testability in Debug.
@testable import SPLTunnel
import XCTest
import os

private struct CoordinatorStubNetworkReader: OwnNetworkReading {
    let value: [IPv4Interface]

    func interfaces() -> [IPv4Interface] {
        value
    }
}

private struct CoordinatorDummyError: Error, Sendable {}

// Counts dials and fails before any request bytes are committed, so the count
// tracks one transport dial per pairing attempt.
private final class CountingThrowingLANPairTransport: LANPairTransport, @unchecked Sendable {
    private let countLock = OSAllocatedUnfairLock(initialState: 0)

    var count: Int {
        countLock.withLock { $0 }
    }

    func prepare(
        host _: String,
        port _: Int,
        caFingerprintBytes _: [UInt8]
    ) async throws -> any LANPairAttempt {
        countLock.withLock { $0 += 1 }
        throw CoordinatorDummyError()
    }
}

private final class StubLANPairTransport: LANPairTransport, @unchecked Sendable {
    typealias Handler = @Sendable (
        _ host: String,
        _ port: Int,
        _ caFingerprintBytes: [UInt8],
        _ requestBytes: Data
    ) async throws -> (status: Int, body: Data)

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func prepare(
        host: String,
        port: Int,
        caFingerprintBytes: [UInt8]
    ) async throws -> any LANPairAttempt {
        StubLANPairAttempt(
            host: host,
            port: port,
            caFingerprintBytes: caFingerprintBytes,
            handler: handler
        )
    }
}

// The dial-time inputs are captured at prepare and replayed to the handler at
// send, so the existing four-argument handler contract is unchanged.
private final class StubLANPairAttempt: LANPairAttempt, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let caFingerprintBytes: [UInt8]
    private let handler: StubLANPairTransport.Handler
    private let closedLock = OSAllocatedUnfairLock(initialState: false)

    var isClosed: Bool {
        closedLock.withLock { $0 }
    }

    init(
        host: String,
        port: Int,
        caFingerprintBytes: [UInt8],
        handler: @escaping StubLANPairTransport.Handler
    ) {
        self.host = host
        self.port = port
        self.caFingerprintBytes = caFingerprintBytes
        self.handler = handler
    }

    func send(requestBytes: Data) async throws -> (status: Int, body: Data) {
        try await handler(host, port, caFingerprintBytes, requestBytes)
    }

    func close() async {
        closedLock.withLock { $0 = true }
    }
}

private final class CoordinatorRelayURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var responseData = Data()
        var statusCode = 200
        var error: URLError?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(responseData: Data = Data(), statusCode: Int = 200, error: URLError? = nil) {
        state.withLock {
            $0.responseData = responseData
            $0.statusCode = statusCode
            $0.error = error
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let current = Self.state.withLock { $0 }
        if let error = current.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: current.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

nonisolated final class PairFlowCoordinatorTests: XCTestCase {
    @MainActor
    func testLatePairResponseCannotReplaceNewerFlow() async throws {
        let store = Self.makeStore()
        let oldPairing = Self.pairing(
            instanceID: "same-journal",
            homeLabel: "old",
            fingerprint: "sha256:\(String(repeating: "1", count: 64))"
        )
        let newPairing = Self.pairing(
            instanceID: "same-journal",
            homeLabel: "new",
            fingerprint: "sha256:\(String(repeating: "2", count: 64))"
        )
        let gate = PairFlowPairingResponseGate()
        let oldCoordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in await gate.waitForPairing() }
        )
        let pairURL = try PairURL.parse(Self.canonicalDirectURL())
        let oldTask = Task { try await oldCoordinator.handlePairURL(pairURL) }
        await gate.waitUntilStarted()

        let newCoordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in newPairing }
        )
        let newCommitted = try await newCoordinator.handlePairURL(pairURL)
        XCTAssertTrue(newCommitted)
        await gate.resume(with: oldPairing)

        let oldCommitted = try await oldTask.value
        XCTAssertFalse(oldCommitted)
        XCTAssertEqual(try store.load(), newPairing)
    }

    @MainActor
    func testCancelledPairFlowDoesNotApplyReturnedCredential() async throws {
        let store = Self.makeStore()
        let pairing = Self.pairing(instanceID: "cancelled-flow", homeLabel: "cancelled")
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in pairing }
        )

        let committed = try await coordinator.handlePairURL(
            try PairURL.parse(Self.canonicalDirectURL()),
            shouldCommit: { false }
        )

        XCTAssertFalse(committed)
        XCTAssertNil(try store.load())
        XCTAssertNil(store.snapshot().deviceOwnerID)
    }

    @MainActor
    func testCoordinatorFailureResetsAutoPairLatchAndAllowsRetry() async throws {
        let store = Self.makeStore()
        let transport = CountingThrowingLANPairTransport()
        let coordinator = PairFlowCoordinator(
            store: store,
            pairClient: PairClient(session: .shared, lanTransport: transport, clientInfo: SPLRuntime.clientInfo),
            networkReader: CoordinatorStubNetworkReader(value: [
                IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")
            ])
        )
        coordinator.hasAutoPaired = true
        let pairURL = try PairURL.parse(Self.localDirectURL())

        do {
            try await coordinator.handlePairURL(pairURL)
            XCTFail("expected pairing to fail")
        } catch {}

        XCTAssertEqual(transport.count, 1)
        XCTAssertFalse(coordinator.hasAutoPaired)
        XCTAssertTrue(coordinator.canStartPairingInput)
        guard case .failed = coordinator.state else {
            return XCTFail("expected failed state")
        }

        do {
            try await coordinator.handlePairURL(pairURL)
            XCTFail("expected retry pairing to fail")
        } catch {}

        XCTAssertEqual(transport.count, 2)
    }

    @MainActor
    func testCoordinatorCompletesAndBootstrapsEndpointWhenRelayEnrollmentUnavailable() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }

        let endpointCache = EndpointCache(fileURL: Self.tempFileURL())
        let client = PairClient(
            session: Self.relaySession(error: URLError(.cannotConnectToHost)),
            lanTransport: StubLANPairTransport { _, _, _, _ in
                (status: 200, body: try Self.lanSuccessData())
            },
            clientInfo: SPLRuntime.clientInfo
        )
        let coordinator = PairFlowCoordinator(
            store: store,
            pairClient: client,
            endpointCache: endpointCache,
            networkReader: CoordinatorStubNetworkReader(value: [])
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.localDirectURL()))

        XCTAssertEqual(coordinator.state, .connected)
        let endpoints = await endpointCache.endpoints()
        XCTAssertEqual(endpoints, [
            .lan(host: "192.168.1.42", port: 7070, scope: ""),
            .lan(host: "10.0.0.2", port: 9443, scope: "wifi")
        ])
    }

    @MainActor
    func testRelayAlreadyConnectedRunsPairingAndPreservesSameFingerprintPairing() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        let prior = Self.pairing(instanceID: "12345678-1234-5678-1234-567812345678", homeLabel: "prior")
        try store.applyPairing(prior)
        let returned = Self.pairing(instanceID: "12345678-1234-5678-1234-567812345678", homeLabel: "returned")
        let pairCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in
                pairCalls.withLock { $0 += 1 }
                return returned
            }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalRelayURL()))

        XCTAssertEqual(coordinator.state, .alreadyConnected)
        XCTAssertEqual(pairCalls.withLock { $0 }, 1)
        XCTAssertEqual(try store.load(), prior)
    }

    @MainActor
    func testDirectSameInstanceNewFingerprintSavesAndReconnects() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        let oldFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let newFingerprint = "sha256:\(String(repeating: "2", count: 64))"
        let prior = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "prior",
            fingerprint: oldFingerprint
        )
        try store.applyPairing(prior)
        let returned = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "returned",
            fingerprint: newFingerprint
        )
        let pairCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in
                pairCalls.withLock { $0 += 1 }
                return returned
            }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try store.load(), returned)
        XCTAssertEqual(pairCalls.withLock { $0 }, 1)
    }

    @MainActor
    func testRelaySameInstanceNewFingerprintSavesAndReconnects() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        let instanceID = "12345678-1234-5678-1234-567812345678"
        let oldFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let newFingerprint = "sha256:\(String(repeating: "2", count: 64))"
        let prior = Self.pairing(
            instanceID: instanceID,
            homeLabel: "prior",
            fingerprint: oldFingerprint
        )
        try store.applyPairing(prior)
        let returned = Self.pairing(
            instanceID: instanceID,
            homeLabel: "returned",
            fingerprint: newFingerprint
        )
        let pairCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in
                pairCalls.withLock { $0 += 1 }
                return returned
            }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalRelayURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try store.load(), returned)
        XCTAssertEqual(pairCalls.withLock { $0 }, 1)
    }

    @MainActor
    func testRePairBootstrapRemovesStaleEndpoints() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        let oldFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let newFingerprint = "sha256:\(String(repeating: "2", count: 64))"
        let staleEndpoint = LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")
        let freshEndpoint = LocalEndpoint(host: "10.0.0.9", port: 9444, scope: "wifi")
        let prior = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "prior",
            fingerprint: oldFingerprint,
            localEndpoints: [staleEndpoint]
        )
        try store.applyPairing(prior)
        let endpointCache = EndpointCache(fileURL: Self.tempFileURL())
        await endpointCache.bootstrap(from: prior)
        let returned = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "returned",
            fingerprint: newFingerprint,
            localEndpoints: [freshEndpoint]
        )
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: endpointCache,
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in returned }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        let endpoints = await endpointCache.endpoints()
        XCTAssertTrue(endpoints.contains(.lan(host: freshEndpoint.host, port: freshEndpoint.port, scope: freshEndpoint.scope)))
        XCTAssertFalse(endpoints.contains(.lan(host: staleEndpoint.host, port: staleEndpoint.port, scope: staleEndpoint.scope)))
    }

    @MainActor
    func testRelayReconnectSavesAndPublishesReconnected() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        try store.applyPairing(Self.pairing(instanceID: "old-instance", homeLabel: "old"))
        let replacement = Self.pairing(instanceID: "12345678-1234-5678-1234-567812345678", homeLabel: "new")
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in replacement }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalRelayURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try store.load(), replacement)
    }

    @MainActor
    func testDirectReconnectSavesDifferentReturnedInstance() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        try store.applyPairing(Self.pairing(instanceID: "old-instance", homeLabel: "old"))
        let replacement = Self.pairing(instanceID: "new-instance", homeLabel: "new")
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in replacement }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try store.load(), replacement)
    }

    @MainActor
    func testDirectAlreadyConnectedDoesNotOverwriteExistingPairing() async throws {
        let store = Self.makeStore()
        try store.clearPairing()
        defer { try? store.clearPairing() }
        let prior = Self.pairing(instanceID: "instance-123", homeLabel: "prior")
        try store.applyPairing(prior)
        let returned = Self.pairing(instanceID: "instance-123", homeLabel: "returned")
        let coordinator = PairFlowCoordinator(
            store: store,
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in returned }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .alreadyConnected)
        XCTAssertEqual(try store.load(), prior)
    }

    private static func makeStore() -> PairingCredentialStore {
        let state = OSAllocatedUnfairLock<StoredPairing?>(initialState: nil)
        return PairingCredentialStore(
            loadPairing: { state.withLock { $0 } },
            savePairing: { pairing in state.withLock { $0 = pairing } },
            deletePairing: { state.withLock { $0 = nil } }
        )
    }

    private static func relaySession(
        responseData: Data = Data(),
        statusCode: Int = 200,
        error: URLError? = nil
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoordinatorRelayURLProtocol.self]
        CoordinatorRelayURLProtocol.configure(responseData: responseData, statusCode: statusCode, error: error)
        return URLSession(configuration: configuration)
    }

    private static func canonicalDirectURL() -> URL {
        URL(string: "https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!
    }

    private static func localDirectURL() -> URL {
        URL(string: "https://go.solstone.app/p#0G0W1A0158DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!
    }

    @MainActor
    func testApplyPairingClearsJournalSendConfirmedWithoutAppConfigDirectCallAndEnablesRetrySettle() async throws {
        let p1 = StoredPairing(
            instanceID: "inst-1",
            homeLabel: "sol-1",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")],
            pairedAt: Date()
        )
        let p2 = StoredPairing(
            instanceID: "inst-2",
            homeLabel: "sol-2",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "b", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")],
            pairedAt: Date()
        )

        let pairingHolder = OSAllocatedUnfairLock<StoredPairing?>(initialState: p1)
        let loadCounter = OSAllocatedUnfairLock(initialState: 0)
        let confirmationStore = JournalSendConfirmationStore.memory()
        try confirmationStore.writeRecord(for: p1)

        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: {
                loadCounter.withLock { $0 += 1 }
                return pairingHolder.withLock { $0 }
            },
            savePairing: { pairing in pairingHolder.withLock { $0 = pairing } },
            deletePairing: { pairingHolder.withLock { $0 = nil } }
        )

        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let endpointCacheFile = Self.tempFileURL()
        let endpointCache = EndpointCache(fileURL: endpointCacheFile)

        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore,
            endpointCache: endpointCache,
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )

        // Starts confirmed from p1
        XCTAssertTrue(appConfig.journalSendConfirmed)

        // 1. store.applyPairing directly (without AppConfig.applyPairing) clears journalSendConfirmed
        try credentialStore.applyPairing(p2)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let countBeforeRetry = loadCounter.withLock { $0 }
        _ = appConfig.retrySettleIfNeeded()
        let countAfterRetry = loadCounter.withLock { $0 }
        XCTAssertGreaterThan(countAfterRetry, countBeforeRetry)

        // 2. PairFlowCoordinator.handlePairURL clears journalSendConfirmed
        // Re-confirm p2 for the coordinator test
        try confirmationStore.writeRecord(for: p2)
        _ = appConfig.retrySettleIfNeeded()
        XCTAssertTrue(appConfig.journalSendConfirmed)

        let coordinator = PairFlowCoordinator(
            store: credentialStore,
            endpointCache: endpointCache,
            pairOperation: { _, _, _, _ in p1 }
        )

        let pairURL = try PairURL.parse(Self.canonicalDirectURL())
        try await coordinator.handlePairURL(pairURL)

        XCTAssertFalse(appConfig.journalSendConfirmed)

        let countBeforeRetry2 = loadCounter.withLock { $0 }
        _ = appConfig.retrySettleIfNeeded()
        let countAfterRetry2 = loadCounter.withLock { $0 }
        XCTAssertGreaterThan(countAfterRetry2, countBeforeRetry2)
    }

    private static func canonicalRelayURL() -> URL {
        URL(string: "https://go.solstone.app/p#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00")!
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("endpoints.json")
    }

    private static func lanSuccessData() throws -> Data {
        try JSONEncoder().encode(LANResponsePayload(
            instanceID: "instance-123",
            homeLabel: "sol",
            clientCert: CertlessTrustFixtures.leafPEM,
            caChain: [CertlessTrustFixtures.caPEM],
            homeAttestation: "attestation",
            localEndpoints: [LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")]
        ))
    }

    private static func pairing(
        instanceID: String,
        homeLabel: String = "sol",
        fingerprint: String = "sha256:\(String(repeating: "a", count: 64))",
        localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")]
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: homeLabel,
            relayEndpoint: "wss://relay.example.com",
            fingerprint: fingerprint,
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .enrolled(deviceToken: "device-token", expiresAt: nil),
            localEndpoints: localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}

private actor PairFlowPairingResponseGate {
    private var pairingContinuation: CheckedContinuation<StoredPairing, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func waitForPairing() async -> StoredPairing {
        await withCheckedContinuation { continuation in
            self.pairingContinuation = continuation
            self.started = true
            self.startedContinuation?.resume()
            self.startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if self.started { return }
        await withCheckedContinuation { continuation in
            self.startedContinuation = continuation
        }
    }

    func resume(with pairing: StoredPairing) {
        self.pairingContinuation?.resume(returning: pairing)
        self.pairingContinuation = nil
    }
}

private struct LANResponsePayload: Encodable {
    let instanceID: String
    let homeLabel: String
    let clientCert: String
    let caChain: [String]
    let homeAttestation: String
    let localEndpoints: [LocalEndpoint]

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case homeLabel = "home_label"
        case clientCert = "client_cert"
        case caChain = "ca_chain"
        case homeAttestation = "home_attestation"
        case localEndpoints = "local_endpoints"
    }
}
