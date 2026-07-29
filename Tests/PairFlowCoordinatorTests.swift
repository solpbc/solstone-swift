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
    func testCoordinatorFailureResetsAutoPairLatchAndAllowsRetry() async throws {
        let transport = CountingThrowingLANPairTransport()
        let coordinator = PairFlowCoordinator(
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
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }

        let endpointCache = EndpointCache(fileURL: Self.tempFileURL())
        let client = PairClient(
            session: Self.relaySession(error: URLError(.cannotConnectToHost)),
            lanTransport: StubLANPairTransport { _, _, _, _ in
                (status: 200, body: try Self.lanSuccessData())
            },
            clientInfo: SPLRuntime.clientInfo
        )
        let coordinator = PairFlowCoordinator(
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
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
        let prior = Self.pairing(instanceID: "12345678-1234-5678-1234-567812345678", homeLabel: "prior")
        try SPLRuntime.keychainStore.save(prior)
        let returned = Self.pairing(instanceID: "12345678-1234-5678-1234-567812345678", homeLabel: "returned")
        let pairCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = PairFlowCoordinator(
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
        XCTAssertEqual(try SPLRuntime.keychainStore.load(), prior)
    }

    @MainActor
    func testDirectSameInstanceNewFingerprintSavesAndReconnects() async throws {
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
        let oldFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let newFingerprint = "sha256:\(String(repeating: "2", count: 64))"
        let prior = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "prior",
            fingerprint: oldFingerprint
        )
        try SPLRuntime.keychainStore.save(prior)
        let returned = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "returned",
            fingerprint: newFingerprint
        )
        let pairCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in
                pairCalls.withLock { $0 += 1 }
                return returned
            }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try SPLRuntime.keychainStore.load(), returned)
        XCTAssertEqual(pairCalls.withLock { $0 }, 1)
    }

    @MainActor
    func testRelaySameInstanceNewFingerprintSavesAndReconnects() async throws {
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
        let instanceID = "12345678-1234-5678-1234-567812345678"
        let oldFingerprint = "sha256:\(String(repeating: "1", count: 64))"
        let newFingerprint = "sha256:\(String(repeating: "2", count: 64))"
        let prior = Self.pairing(
            instanceID: instanceID,
            homeLabel: "prior",
            fingerprint: oldFingerprint
        )
        try SPLRuntime.keychainStore.save(prior)
        let returned = Self.pairing(
            instanceID: instanceID,
            homeLabel: "returned",
            fingerprint: newFingerprint
        )
        let pairCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in
                pairCalls.withLock { $0 += 1 }
                return returned
            }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalRelayURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try SPLRuntime.keychainStore.load(), returned)
        XCTAssertEqual(pairCalls.withLock { $0 }, 1)
    }

    @MainActor
    func testRePairBootstrapRemovesStaleEndpoints() async throws {
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
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
        try SPLRuntime.keychainStore.save(prior)
        let endpointCache = EndpointCache(fileURL: Self.tempFileURL())
        await endpointCache.bootstrap(from: prior)
        let returned = Self.pairing(
            instanceID: "instance-123",
            homeLabel: "returned",
            fingerprint: newFingerprint,
            localEndpoints: [freshEndpoint]
        )
        let coordinator = PairFlowCoordinator(
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
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
        try SPLRuntime.keychainStore.save(Self.pairing(instanceID: "old-instance", homeLabel: "old"))
        let replacement = Self.pairing(instanceID: "12345678-1234-5678-1234-567812345678", homeLabel: "new")
        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in replacement }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalRelayURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try SPLRuntime.keychainStore.load(), replacement)
    }

    @MainActor
    func testDirectReconnectSavesDifferentReturnedInstance() async throws {
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
        try SPLRuntime.keychainStore.save(Self.pairing(instanceID: "old-instance", homeLabel: "old"))
        let replacement = Self.pairing(instanceID: "new-instance", homeLabel: "new")
        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in replacement }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .reconnected)
        XCTAssertEqual(try SPLRuntime.keychainStore.load(), replacement)
    }

    @MainActor
    func testDirectAlreadyConnectedDoesNotOverwriteExistingPairing() async throws {
        try SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }
        let prior = Self.pairing(instanceID: "instance-123", homeLabel: "prior")
        try SPLRuntime.keychainStore.save(prior)
        let returned = Self.pairing(instanceID: "instance-123", homeLabel: "returned")
        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            networkReader: CoordinatorStubNetworkReader(value: []),
            pairOperation: { _, _, _, _ in returned }
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .alreadyConnected)
        XCTAssertEqual(try SPLRuntime.keychainStore.load(), prior)
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
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: "device-token", expiresAt: nil),
            localEndpoints: localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
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
