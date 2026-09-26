// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest
import os

private final class EndpointURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var responseData = Data()
        var statusCode = 200
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(responseData: Data, statusCode: Int = 200) {
        state.withLock {
            $0.responseData = responseData
            $0.statusCode = statusCode
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let current = Self.state.withLock { $0 }
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

/// Answers only after a delay, so a test can change the pairing while a refresh is awaiting.
private final class SlowEndpointURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(#"{"local_endpoints":[{"ip":"3.19.73.183","port":7657,"scope":"public"}]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [self] in
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Self.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

nonisolated final class EndpointCacheTests: XCTestCase {
    /// Forgetting a journal must reach the copy the tunnel dials from: every owner of the cache
    /// defaults to the one shared instance, never a fresh one over the same file.
    func testEveryDefaultOwnerUsesTheSharedCache() throws {
        for relativePath in [
            "Sources/Services/AppConfig.swift",
            "Sources/Tunnel/TunnelManager.swift",
            "Sources/Pairing/PairFlowCoordinator.swift",
        ] {
            let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("endpointCache: EndpointCache = .shared"), relativePath)
            XCTAssertFalse(text.contains("EndpointCache()"), relativePath)
        }
    }

    func testBootstrapWritesJSONAndReturnsEndpoints() async throws {
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)

        await cache.bootstrap(from: Self.pairing(endpoints: [
            LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")
        ]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let endpoints = await cache.endpoints()
        XCTAssertEqual(endpoints, [.lan(host: "10.0.0.2", port: 9443, scope: "wifi")])
        let data = try Data(contentsOf: fileURL)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"host\":\"10.0.0.2\"") == true)
    }

    func testTTLEndpointsArePrunedOnRead() async throws {
        let fileURL = Self.tempFileURL()
        try Self.writeEntries(fileURL: fileURL, lastSeen: Date(timeIntervalSince1970: 0))
        let cache = EndpointCache(fileURL: fileURL, ttl: 1)

        let endpoints = await cache.endpoints()

        XCTAssertEqual(endpoints, [])
    }

    func testRefreshMergesByEndpointKey() async throws {
        let fileURL = Self.tempFileURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EndpointURLProtocol.self]
        EndpointURLProtocol.configure(responseData: """
        {"local_endpoints":[{"ip":"10.0.0.2","port":9443,"scope":"wifi"},{"ip":"fd00::1","port":9443,"scope":"ula"}]}
        """.data(using: .utf8)!)
        let cache = EndpointCache(fileURL: fileURL, session: URLSession(configuration: config))
        await cache.bootstrap(from: Self.pairing(endpoints: [
            LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")
        ]))

        try await cache.refresh(viaLoopbackPort: 54321)
        let endpoints = await cache.endpoints()

        XCTAssertTrue(endpoints.contains(.lan(host: "10.0.0.2", port: 9443, scope: "wifi")))
        XCTAssertTrue(endpoints.contains(.lan(host: "fd00::1", port: 9443, scope: "ula")))
        XCTAssertEqual(endpoints.count, 2)
    }

    /// Forgetting a journal while a refresh of its addresses is still out must not let that
    /// refresh write the old journal's addresses back.
    func testARefreshThatStartedBeforeAWipeDoesNotWriteBack() async throws {
        let fileURL = Self.tempFileURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowEndpointURLProtocol.self]
        let cache = EndpointCache(fileURL: fileURL, session: URLSession(configuration: config))
        await cache.bootstrap(from: Self.pairing(endpoints: []))

        let refresh = Task { try await cache.refresh(viaLoopbackPort: 54321) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await cache.wipe()
        try await refresh.value

        let endpoints = await cache.endpoints()
        XCTAssertEqual(endpoints, [])
        let reopened = EndpointCache(fileURL: fileURL)
        let persisted = await reopened.endpoints()
        XCTAssertEqual(persisted, [])
    }

    func testEvictRemovesMatchingEntryAndPersists() async {
        let fileURL = Self.tempFileURL()
        let target = LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")
        let survivor = LocalEndpoint(host: "10.0.0.3", port: 9443, scope: "wifi")
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.pairing(endpoints: [target, survivor]))

        await cache.evict(host: target.host, port: target.port, scope: target.scope)

        let endpoints = await cache.endpoints()
        XCTAssertFalse(endpoints.contains(.lan(host: target.host, port: target.port, scope: target.scope)))
        XCTAssertTrue(endpoints.contains(.lan(host: survivor.host, port: survivor.port, scope: survivor.scope)))

        let reloadedCache = EndpointCache(fileURL: fileURL)
        let reloadedEndpoints = await reloadedCache.endpoints()
        XCTAssertFalse(reloadedEndpoints.contains(.lan(host: target.host, port: target.port, scope: target.scope)))
        XCTAssertTrue(reloadedEndpoints.contains(.lan(host: survivor.host, port: survivor.port, scope: survivor.scope)))
    }

    func testEvictNonMatchingIdentityIsNoOp() async {
        let fileURL = Self.tempFileURL()
        let endpoint = LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.pairing(endpoints: [endpoint]))

        await cache.evict(host: "10.0.0.99", port: 9443, scope: "wifi")

        let endpoints = await cache.endpoints()
        XCTAssertEqual(endpoints, [.lan(host: endpoint.host, port: endpoint.port, scope: endpoint.scope)])
    }

    func testWipeDeletesFile() async {
        let fileURL = Self.tempFileURL()
        let cache = EndpointCache(fileURL: fileURL)
        await cache.bootstrap(from: Self.pairing(endpoints: [
            LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "")
        ]))

        await cache.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMalformedJSONReturnsEmptyEndpoints() async throws {
        let fileURL = Self.tempFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        let cache = EndpointCache(fileURL: fileURL)

        let endpoints = await cache.endpoints()

        XCTAssertEqual(endpoints, [])
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("endpoints.json")
    }

    private static func pairing(endpoints: [LocalEndpoint]) -> StoredPairing {
        StoredPairing(
            instanceID: "instance",
            homeLabel: "home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: String(repeating: "a", count: 64),
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: "token", expiresAt: nil),
            localEndpoints: endpoints,
            pairedAt: Date()
        )
    }

    private static func writeEntries(fileURL: URL, lastSeen: Date) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encodedDate = ISO8601DateFormatter().string(from: lastSeen)
        let json = """
        [{"host":"10.0.0.2","port":9443,"scope":"","lastSeen":"\(encodedDate)"}]
        """
        try Data(json.utf8).write(to: fileURL)
    }
}
