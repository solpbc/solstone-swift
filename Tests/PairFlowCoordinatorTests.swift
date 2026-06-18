// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import SPLTunnel
import XCTest
import os

private struct CoordinatorStubNetworkReader: OwnNetworkReading {
    let value: [IPv4Interface]

    func interfaces() -> [IPv4Interface] {
        value
    }
}

private struct CoordinatorDummyError: Error, Sendable {}

private final class CountingThrowingLANPairTransport: LANPairTransport, @unchecked Sendable {
    private let countLock = OSAllocatedUnfairLock(initialState: 0)

    var count: Int {
        countLock.withLock { $0 }
    }

    func send(
        host _: String,
        port _: Int,
        caFingerprintBytes _: [UInt8],
        requestBytes _: Data
    ) async throws -> (status: Int, body: Data) {
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

    func send(
        host: String,
        port: Int,
        caFingerprintBytes: [UInt8],
        requestBytes: Data
    ) async throws -> (status: Int, body: Data) {
        try await handler(host, port, caFingerprintBytes, requestBytes)
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
            pairClient: PairClient(lanTransport: transport),
            networkReader: CoordinatorStubNetworkReader(value: [
                IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")
            ])
        )
        coordinator.hasAutoPaired = true
        let pairURL = try PairURL.parse(Self.canonicalDirectURL())

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
        try SPLKeychain.delete()
        defer { try? SPLKeychain.delete() }

        let endpointCache = EndpointCache(fileURL: Self.tempFileURL())
        let client = PairClient(
            session: Self.relaySession(error: URLError(.cannotConnectToHost)),
            lanTransport: StubLANPairTransport { _, _, _, _ in
                (status: 200, body: try Self.lanSuccessData())
            }
        )
        let coordinator = PairFlowCoordinator(
            pairClient: client,
            endpointCache: endpointCache,
            networkReader: CoordinatorStubNetworkReader(value: [])
        )

        try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))

        XCTAssertEqual(coordinator.state, .success)
        let endpoints = await endpointCache.endpoints()
        XCTAssertEqual(endpoints, [
            .lan(host: "192.0.2.42", port: 7070, scope: ""),
            .lan(host: "10.0.0.2", port: 9443, scope: "wifi")
        ])
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
