// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import XCTest
import SPLTunnel
@testable import solstone_swift

private final class StoredHolder: @unchecked Sendable {
    var stored: StoredPairing?
    init(_ stored: StoredPairing? = nil) {
        self.stored = stored
    }
}

private final class LifecycleHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    func set(_ h: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        defer { lock.unlock() }
        handler = h
    }

    func get() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}

final class HomeConnectionLifecycleTests: XCTestCase {
    nonisolated final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        private static let box = LifecycleHandlerBox()
        private static let asyncBox = ValueBox<(@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?>(nil)

        static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
            get { box.get() }
            set { box.set(newValue) }
        }

        static var asyncRequestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))? {
            get { asyncBox.value }
            set { asyncBox.value = newValue }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            if let asyncHandler = MockURLProtocol.asyncRequestHandler {
                Task {
                    do {
                        let (response, data) = try await asyncHandler(request)
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: data)
                        client?.urlProtocolDidFinishLoading(self)
                    } catch {
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }
                return
            }

            guard let handler = MockURLProtocol.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeTestClient() -> AuthenticatedHomeClient {
        AuthenticatedHomeClient(sessionFactory: { _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            config.connectionProxyDictionary = [:]
            return URLSession(
                configuration: config,
                delegate: JournalVersionRedirectDelegate(),
                delegateQueue: nil
            )
        })
    }

    private static func extractBody(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    private func makeSamplePairing(
        instanceID: String = "test-instance",
        relayEnrollment: RelayEnrollment = .unavailable
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "Alice Journal",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "0123456789abcdef",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: relayEnrollment,
            localEndpoints: [LocalEndpoint(host: "192.168.1.100", port: 7071, scope: "local")],
            pairedAt: Date()
        )
    }

    private func makeJWT(claims: [String: Any]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: claims)

        let headerB64 = headerData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        return "\(headerB64).\(payloadB64).sig"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.asyncRequestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testZeroTransferCountPublishesSnapshotAndUpdatesJournalMetadata() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let getResourceJSON = """
        {
            "protocol_version": 1,
            "revision": 1,
            "reported": {
                "name": "Old Phone",
                "platform": "ios",
                "device_type": "phone",
                "app_id": "app.solstone.swift",
                "app_version": "1.0.0"
            },
            "owner_label": null,
            "display_label": "Old Phone",
            "updated_at": null,
            "journal": {
                "name": "Home Server",
                "version": "2.5.0"
            }
        }
        """.data(using: .utf8)!

        let (putSent, putContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                if request.httpMethod == "GET" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, getResourceJSON)
                } else if request.httpMethod == "PUT" {
                    putContinuation.yield(())
                    let putResponseJSON = """
                    {
                        "protocol_version": 1,
                        "revision": 2,
                        "reported": {
                            "name": "New Phone",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.1"
                        },
                        "owner_label": null,
                        "display_label": "New Phone",
                        "updated_at": null,
                        "journal": {
                            "name": "Home Server",
                            "version": "2.5.0"
                        }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, putResponseJSON)
                }
            } else if path == "/app/network/api/relay/access" {
                let notConfigured = """
                {
                    "protocol_version": 2,
                    "status": "not_configured"
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, notConfigured)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "New Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.1"
        )

        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        jobs.connected(localPort: 7071)

        // Wait for PUT to execute
        var iterator = putSent.makeAsyncIterator()
        _ = await iterator.next()

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(journalVersion.name, "Home Server")
        XCTAssertEqual(journalVersion.version, "2.5.0")
        XCTAssertTrue(journalVersion.isCurrent)
        XCTAssertTrue(store.isLiveRelayDisabled)
    }

    @MainActor
    func testConflictRetriesPUTOnceWithNewestSnapshot() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let getCounter = ValueBox<Int>(0)
        let putCounter = ValueBox<Int>(0)

        let (retryDone, retryContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                if request.httpMethod == "GET" {
                    let getCount = getCounter.value + 1
                    getCounter.value = getCount
                    let rev = getCount == 1 ? 1 : 2
                    let json = """
                    {
                        "protocol_version": 1,
                        "revision": \(rev),
                        "reported": {
                            "name": "Old Phone",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "Old Phone",
                        "updated_at": null,
                        "journal": { "name": "Home", "version": "2.0.0" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, json)
                } else if request.httpMethod == "PUT" {
                    let putCount = putCounter.value + 1
                    putCounter.value = putCount
                    if putCount == 1 {
                        // 409 Conflict
                        let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
                        return (response, Data())
                    } else {
                        // 200 OK on retry
                        retryContinuation.yield(())
                        let json = """
                        {
                            "protocol_version": 1,
                            "revision": 3,
                            "reported": {
                                "name": "New Phone",
                                "platform": "ios",
                                "device_type": "phone",
                                "app_id": "app.solstone.swift",
                                "app_version": "1.0.1"
                            },
                            "owner_label": null,
                            "display_label": "New Phone",
                            "updated_at": null,
                            "journal": { "name": "Home", "version": "2.0.0" }
                        }
                        """.data(using: .utf8)!
                        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                        return (response, json)
                    }
                }
            } else if path == "/app/network/api/relay/access" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "New Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.1"
        )

        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        jobs.connected(localPort: 7071)

        var iterator = retryDone.makeAsyncIterator()
        _ = await iterator.next()

        XCTAssertEqual(putCounter.value, 2)
        XCTAssertEqual(getCounter.value, 2)
    }

    @MainActor
    func testConcurrentNameChangesCoalesceIntoAtMostOneWaitingTask() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let putCounter = ValueBox<Int>(0)
        let (firstPutInFlight, firstPutContinuation) = AsyncStream<Void>.makeStream()
        let (releaseFirstPut, releaseContinuation) = AsyncStream<Void>.makeStream()
        let (allPutsDone, allPutsContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                if request.httpMethod == "GET" {
                    let json = """
                    {
                        "protocol_version": 1,
                        "revision": 1,
                        "reported": {
                            "name": "Initial",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "Initial",
                        "updated_at": null,
                        "journal": { "name": "Home", "version": "1.0.0" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, json)
                } else if request.httpMethod == "PUT" {
                    let count = putCounter.value + 1
                    putCounter.value = count
                    if count == 1 {
                        firstPutContinuation.yield(())
                        var iter = releaseFirstPut.makeAsyncIterator()
                        _ = Task { _ = await iter.next() }
                    } else if count == 2 {
                        allPutsContinuation.yield(())
                    }
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    let putResp = """
                    {
                        "protocol_version": 1,
                        "revision": \(count + 1),
                        "reported": {
                            "name": "Updated",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "Updated",
                        "updated_at": null,
                        "journal": { "name": "Home", "version": "1.0.0" }
                    }
                    """.data(using: .utf8)!
                    return (response, putResp)
                }
            } else if path == "/app/network/api/relay/access" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = makeTestClient()
        var currentName = "Name A"
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: {
                DeviceDescriptionSnapshot(
                    name: currentName,
                    platform: "ios",
                    deviceType: "phone",
                    appID: "app.solstone.swift",
                    appVersion: "1.0.0"
                )
            }
        )

        jobs.connected(localPort: 7071)

        // Wait for first PUT to be in flight
        var firstIter = firstPutInFlight.makeAsyncIterator()
        _ = await firstIter.next()

        // Multiple concurrent updates while first PUT is in flight
        currentName = "Name B"
        jobs.connected(localPort: 7071)
        currentName = "Name C"
        jobs.connected(localPort: 7071)
        currentName = "Name Final"
        jobs.connected(localPort: 7071)

        // Release first PUT
        releaseContinuation.yield(())

        // Wait for second PUT to finish
        var allIter = allPutsDone.makeAsyncIterator()
        _ = await allIter.next()

        try await Task.sleep(nanoseconds: 50_000_000)

        // Total PUTs should be exactly 2 (initial + 1 coalesced final update)
        XCTAssertEqual(putCounter.value, 2)
    }

    @MainActor
    func testSlowHomeTimesOutFreedSlotAndNextConnectionSucceeds() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let (metadataUpdated, metadataUpdatedContinuation) = AsyncStream<Void>.makeStream()
        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))
        journalVersion.onChange = {
            metadataUpdatedContinuation.yield(())
        }

        let isHanging = ValueBox<Bool>(true)

        MockURLProtocol.asyncRequestHandler = { request in
            let path = request.url?.path ?? ""
            if isHanging.value {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, Data())
            } else {
                if path == "/app/network/api/clients/self" {
                    let json = """
                    {
                        "protocol_version": 1,
                        "revision": 1,
                        "reported": {
                            "name": "Current",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "Current",
                        "updated_at": null,
                        "journal": { "name": "Recovered Home", "version": "3.0.0" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, json)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
        }

        let client = makeTestClient()
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            deadline: .milliseconds(150)
        )

        // 1. First connection hangs and times out
        jobs.connected(localPort: 7071)
        try await Task.sleep(nanoseconds: 200_000_000)

        // 2. Second connection succeeds immediately
        var iter = metadataUpdated.makeAsyncIterator()
        isHanging.value = false
        jobs.connected(localPort: 7071)

        _ = await iter.next()

        XCTAssertEqual(journalVersion.name, "Recovered Home")
        XCTAssertEqual(journalVersion.version, "3.0.0")
        XCTAssertTrue(journalVersion.isCurrent)
    }

    @MainActor
    func testOlderHome404FallsBackToStatusGET() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let (statusDone, statusContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            } else if path == "/api/system/status" {
                statusContinuation.yield(())
                let json = """
                {
                    "version": {
                        "current": "2.1.0"
                    }
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, json)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeTestClient()
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client
        )

        jobs.connected(localPort: 7071)

        var iter = statusDone.makeAsyncIterator()
        _ = await iter.next()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(journalVersion.version, "2.1.0")
        XCTAssertTrue(journalVersion.isCurrent)
    }

    @MainActor
    func testUnsupported501Or400DoesNotFallBackToStatusGET() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let statusAttempted = ValueBox<Bool>(false)
        let (clientsDone, clientsContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                clientsContinuation.yield(())
                let response = HTTPURLResponse(url: request.url!, statusCode: 501, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            } else if path == "/api/system/status" {
                statusAttempted.value = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = makeTestClient()
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client
        )

        jobs.connected(localPort: 7071)

        var iter = clientsDone.makeAsyncIterator()
        _ = await iter.next()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(statusAttempted.value)
        XCTAssertNil(journalVersion.version)
        XCTAssertFalse(journalVersion.isCurrent)
    }

    @MainActor
    func testUnchangedReportedDescriptionGETOnlyNoPUT() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let putAttempted = ValueBox<Bool>(false)
        let (getDone, getContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                if request.httpMethod == "GET" {
                    let json = """
                    {
                        "protocol_version": 1,
                        "revision": 2,
                        "reported": {
                            "name": "Same Phone",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "Same Phone",
                        "updated_at": null,
                        "journal": { "name": "Home", "version": "2.0.0" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    getContinuation.yield(())
                    return (response, json)
                } else if request.httpMethod == "PUT" {
                    putAttempted.value = true
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, Data())
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "Same Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        jobs.connected(localPort: 7071)

        var iter = getDone.makeAsyncIterator()
        _ = await iter.next()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(putAttempted.value)
        XCTAssertEqual(journalVersion.version, "2.0.0")
        XCTAssertTrue(journalVersion.isCurrent)
    }

    @MainActor
    func testOwnerLabelOverridePreservedOnServer() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let capturedPutData = ValueBox<Data?>(nil)
        let (putDone, putContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                if request.httpMethod == "GET" {
                    let json = """
                    {
                        "protocol_version": 1,
                        "revision": 1,
                        "owner_label": "Mom's Phone",
                        "display_label": "Mom's Phone",
                        "updated_at": null,
                        "reported": {
                            "name": "Old Name",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "journal": { "name": "Home", "version": "1.0.0" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, json)
                } else if request.httpMethod == "PUT" {
                    capturedPutData.value = Self.extractBody(from: request)
                    putContinuation.yield(())
                    let putResp = """
                    {
                        "protocol_version": 1,
                        "revision": 2,
                        "owner_label": "Mom's Phone",
                        "display_label": "Mom's Phone",
                        "updated_at": null,
                        "reported": {
                            "name": "New Local Name",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "journal": { "name": "Home", "version": "1.0.0" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, putResp)
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "New Local Name",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        jobs.connected(localPort: 7071)

        var iter = putDone.makeAsyncIterator()
        _ = await iter.next()

        let putData = try XCTUnwrap(capturedPutData.value)
        let putJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: putData) as? [String: Any])
        XCTAssertNil(putJSON["owner_label"])
        let reported = try XCTUnwrap(putJSON["reported"] as? [String: Any])
        XCTAssertEqual(reported["name"] as? String, "New Local Name")
    }

    @MainActor
    func testProgressionLANReadyThenRemoteNotConfiguredSettles() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let instance = "inst-1"
        let claims: [String: Any] = [
            "iss": "solstone-journal",
            "sub": "instance:\(instance)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instance,
            "iat": 1_700_000_000,
            "exp": 1_893_456_000,
            "jti": "jwt-1"
        ]
        let token = makeJWT(claims: claims)
        let readyJSON = """
        {
            "protocol_version": 2,
            "status": "ready",
            "instance_id": "\(instance)",
            "relay_origin": "https://relay.example.com",
            "device_token": "\(token)",
            "expires_at": "2030-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let notConfiguredJSON = """
        {
            "protocol_version": 2,
            "status": "not_configured"
        }
        """.data(using: .utf8)!

        let currentRelayResponse = ValueBox<Data>(readyJSON)
        let (actionDone, actionContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/relay/access" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                actionContinuation.yield(())
                return (response, currentRelayResponse.value)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeTestClient()
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client
        )

        var iter = actionDone.makeAsyncIterator()

        // 1. LAN connection -> ready access acquired
        jobs.connected(localPort: 7071)
        _ = await iter.next()
        try await Task.sleep(nanoseconds: 50_000_000)

        if case .enrolled(let devToken, _) = try store.load()?.relayEnrollment {
            XCTAssertEqual(devToken, token)
        } else {
            XCTFail("Expected enrolled")
        }
        XCTAssertFalse(store.isLiveRelayDisabled)

        // 2. Remote connection -> not_configured disables relay
        currentRelayResponse.value = notConfiguredJSON
        jobs.connected(localPort: 7071)
        _ = await iter.next()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(store.isLiveRelayDisabled)
        XCTAssertEqual(try store.load()?.relayEnrollment, .unavailable)
    }

    @MainActor
    func testDisconnectCancelsAndFencesLateIO() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let (canProceed, proceedContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                // Block until test triggers disconnection
                var iter = canProceed.makeAsyncIterator()
                _ = Task {
                    _ = await iter.next()
                }
                let json = """
                {
                    "protocol_version": 1,
                    "revision": 1,
                    "reported": {
                        "name": "Old Phone",
                        "platform": "ios",
                        "device_type": "phone",
                        "app_id": "app.solstone.swift",
                        "app_version": "1.0.0"
                    },
                    "owner_label": null,
                    "display_label": "Old Phone",
                    "updated_at": null,
                    "journal": { "name": "Late Journal", "version": "9.9.9" }
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, json)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = makeTestClient()
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client
        )

        jobs.connected(localPort: 7071)
        jobs.disconnected()

        proceedContinuation.yield(())
        try await Task.sleep(nanoseconds: 50_000_000)

        // Metadata was not updated because disconnection fenced it
        XCTAssertNil(journalVersion.version)
        XCTAssertNil(journalVersion.name)
        XCTAssertFalse(journalVersion.isCurrent)
    }

    @MainActor
    func testTunnelManagerForceConnectedTriggersHomeJobsPut() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let (putSent, putContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                if request.httpMethod == "GET" {
                    let json = """
                    {
                        "protocol_version": 1,
                        "revision": 1,
                        "reported": {
                            "name": "Old Phone",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "Old Phone",
                        "updated_at": null,
                        "journal": {
                            "name": "Home Server",
                            "version": "2.5.0"
                        }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, json)
                } else if request.httpMethod == "PUT" {
                    putContinuation.yield(())
                    let putResp = """
                    {
                        "protocol_version": 1,
                        "revision": 2,
                        "reported": {
                            "name": "New Local Name",
                            "platform": "ios",
                            "device_type": "phone",
                            "app_id": "app.solstone.swift",
                            "app_version": "1.0.0"
                        },
                        "owner_label": null,
                        "display_label": "New Local Name",
                        "updated_at": null,
                        "journal": {
                            "name": "Home Server",
                            "version": "2.5.0"
                        }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, putResp)
                }
            } else if path == "/app/network/api/relay/access" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "New Local Name",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        let transport = MockCFTunnelTransport()
        let endpointCache = EndpointCache(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let tunnelManager = TunnelManager(
            transport: transport,
            endpointCache: endpointCache,
            store: store,
            activeLocalTransferCountProvider: { 0 },
            journalVersion: journalVersion,
            homeJobs: jobs
        )

        tunnelManager.forceConnected(port: 7071, via: .lan)

        var iter = putSent.makeAsyncIterator()
        _ = await iter.next()

        XCTAssertEqual(journalVersion.version, "2.5.0")
        XCTAssertEqual(journalVersion.name, "Home Server")
        XCTAssertTrue(journalVersion.isCurrent)
    }

    @MainActor
    func testTimeoutWithCancellationInsensitiveMockDoesNotPublishAndNextConnectedRunsSlot() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let (firstCallStarted, firstCallStartedContinuation) = AsyncStream<Void>.makeStream()
        let (secondCallDone, secondCallDoneContinuation) = AsyncStream<Void>.makeStream()

        let clientsSelfCount = OSAllocatedUnfairLock(initialState: 0)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/app/network/api/relay/access" {
                let json = """
                {
                    "protocol_version": 1,
                    "state": "not_configured"
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, json)
            }

            let count = clientsSelfCount.withLock { count -> Int in
                let current = count
                count += 1
                return current
            }
            if count == 0 {
                firstCallStartedContinuation.yield(())
                Thread.sleep(forTimeInterval: 0.4)
                let json = """
                {
                    "protocol_version": 1,
                    "revision": 1,
                    "reported": {
                        "name": "Phone",
                        "platform": "ios",
                        "device_type": "phone",
                        "app_id": "app.solstone.swift",
                        "app_version": "1.0.0"
                    },
                    "owner_label": null,
                    "display_label": "Phone",
                    "updated_at": null,
                    "journal": { "name": "Late Server", "version": "9.9.9" }
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, json)
            } else {
                let json = """
                {
                    "protocol_version": 1,
                    "revision": 1,
                    "reported": {
                        "name": "Phone",
                        "platform": "ios",
                        "device_type": "phone",
                        "app_id": "app.solstone.swift",
                        "app_version": "1.0.0"
                    },
                    "owner_label": null,
                    "display_label": "Phone",
                    "updated_at": null,
                    "journal": { "name": "Real Server", "version": "1.0.0" }
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                secondCallDoneContinuation.yield(())
                return (response, json)
            }
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            deadline: .milliseconds(200),
            snapshotProvider: { snapshot }
        )

        var firstIter = firstCallStarted.makeAsyncIterator()
        var secondIter = secondCallDone.makeAsyncIterator()

        jobs.connected(localPort: 7071)
        _ = await firstIter.next()

        try await Task.sleep(nanoseconds: 250_000_000)

        jobs.disconnected()
        jobs.connected(localPort: 7071)
        _ = await secondIter.next()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(journalVersion.version, "1.0.0")
        XCTAssertEqual(journalVersion.name, "Real Server")
    }

    @MainActor
    func testGETInFlightVsDisableUnpairSameHomeApplyPairingDoesNotCommit() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let (inFlightReady, inFlightReadyContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            inFlightReadyContinuation.yield(())
            Thread.sleep(forTimeInterval: 0.2)
            let json = """
            {
                "protocol_version": 1,
                "revision": 1,
                "reported": {
                    "name": "Phone",
                    "platform": "ios",
                    "device_type": "phone",
                    "app_id": "app.solstone.swift",
                    "app_version": "1.0.0"
                },
                "owner_label": null,
                "display_label": "Phone",
                "updated_at": null,
                "journal": { "name": "Stale Server", "version": "9.0.0" }
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, json)
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        var iter = inFlightReady.makeAsyncIterator()
        jobs.connected(localPort: 7071)
        _ = await iter.next()

        _ = try? await store.disableRelayAccess(pairingGen: 0, mutationGen: 0)
        _ = try? store.clearPairing()
        _ = try? await store.applyPairing(pairing)

        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(journalVersion.version)
    }

    @MainActor
    func testBothLanesViaTunnelManagerConnectStateDidSetWithZeroTransferCount() async throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))

        let (metaSent, metaContinuation) = AsyncStream<Void>.makeStream()
        let (accessSent, accessContinuation) = AsyncStream<Void>.makeStream()

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/app/network/api/clients/self" {
                metaContinuation.yield(())
                let json = """
                {
                    "protocol_version": 1,
                    "revision": 1,
                    "reported": {
                        "name": "Local Phone",
                        "platform": "ios",
                        "device_type": "phone",
                        "app_id": "app.solstone.swift",
                        "app_version": "1.0.0"
                    },
                    "owner_label": null,
                    "display_label": "Local Phone",
                    "updated_at": null,
                    "journal": {
                        "name": "Live Server",
                        "version": "3.0.0"
                    }
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, json)
            } else if path == "/app/network/api/relay/access" {
                accessContinuation.yield(())
                let notConfigured = """
                {
                    "protocol_version": 2,
                    "status": "not_configured"
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (response, notConfigured)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = makeTestClient()
        let snapshot = DeviceDescriptionSnapshot(
            name: "Local Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let jobs = HomeAuthenticatedJobs(
            store: store,
            journalVersion: journalVersion,
            client: client,
            snapshotProvider: { snapshot }
        )

        let transport = MockCFTunnelTransport()
        let endpointCache = EndpointCache(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let tunnelManager = TunnelManager(
            transport: transport,
            endpointCache: endpointCache,
            store: store,
            activeLocalTransferCountProvider: { 0 },
            journalVersion: journalVersion,
            homeJobs: jobs
        )

        tunnelManager.forceConnected(port: 7071, via: .lan)

        var metaIter = metaSent.makeAsyncIterator()
        var accessIter = accessSent.makeAsyncIterator()

        _ = await metaIter.next()
        _ = await accessIter.next()

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(tunnelManager.state, TunnelState.connected(localPort: 7071, via: .lan))
        XCTAssertEqual(journalVersion.version, "3.0.0")
        XCTAssertEqual(journalVersion.name, "Live Server")
        XCTAssertTrue(store.isLiveRelayDisabled)
    }
    @MainActor
    func testPortChangeRetiresBlockedOldMetadataAndRunsNewLane() async throws {
        try await checkReplacementConnection(samePort: false)
    }

    @MainActor
    func testSamePortNewPairingRetiresBlockedOldMetadataAndRunsNewLane() async throws {
        try await checkReplacementConnection(samePort: true)
    }

    @MainActor
    private func checkReplacementConnection(samePort: Bool) async throws {
        let pairing = makeSamplePairing()
        let holder = OSAllocatedUnfairLock<StoredPairing?>(initialState: pairing)
        let store = PairingCredentialStore(
            loadPairing: { holder.withLock { $0 } },
            savePairing: { value in holder.withLock { $0 = value } },
            deletePairing: { holder.withLock { $0 = nil } }
        )
        let suite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = JournalVersionMetadata(defaults: defaults) { _ in nil }
        metadata.setIdentity(journalVersionMetadataIdentity(for: pairing))
        let oldStarted = expectation(description: "old metadata GET")
        let newStarted = expectation(description: "new metadata GET")
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let count = OSAllocatedUnfairLock(initialState: 0)
        MockURLProtocol.asyncRequestHandler = { request in
            guard request.url?.path == "/app/network/api/clients/self" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            let ordinal = count.withLock { $0 += 1; return $0 }
            if ordinal == 1 {
                oldStarted.fulfill()
                for await _ in release.stream { break }
            } else if ordinal == 2 {
                newStarted.fulfill()
            }
            let name = ordinal == 1 ? "Old" : "New"
            let data = """
            {"protocol_version":1,"revision":0,"reported":{"name":null,"platform":null,"device_type":null,"app_id":null,"app_version":null},"owner_label":null,"display_label":"Phone","updated_at":null,"journal":{"name":"\(name)","version":"1.0"}}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let jobs = HomeAuthenticatedJobs(store: store, journalVersion: metadata, client: makeTestClient(),
            snapshotProvider: { DeviceDescriptionSnapshot(name: nil, platform: nil, deviceType: nil, appID: nil, appVersion: nil) })
        defer { jobs.disconnected() }
        jobs.connected(localPort: 7071)
        await fulfillment(of: [oldStarted], timeout: 2)
        if samePort { try store.applyPairing(pairing) }
        let newPort = samePort ? 7071 : 8082
        jobs.connected(localPort: newPort)
        await fulfillment(of: [newStarted], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        release.continuation.yield(())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(metadata.name, "New")
        jobs.connected(localPort: newPort)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThanOrEqual(count.withLock { $0 }, 3)
        XCTAssertEqual(metadata.name, "New")
    }

    @MainActor
    func testDeadlineRetiresClearRetryQueuedBehindActualKeychainWriter() async throws {
        let keychain = SPLKeychainStore(policy: KeychainPolicy(service: "app.solstone.swift.test.\(UUID().uuidString)",
            account: "pairing", accessGroup: nil, useDataProtectionKeychain: false, accessibility: .afterFirstUnlock))
        defer { try? keychain.delete() }
        let pairing = makeSamplePairing(relayEnrollment: .enrolled(deviceToken: "old", expiresAt: nil))
        try keychain.save(pairing)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let entered = expectation(description: "owned clear retry entered Keychain save")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = PairingCredentialStore(loadPairing: { try keychain.load() }, savePairing: { value in
            let ordinal = count.withLock { $0 += 1; return $0 }
            if ordinal == 1 { throw URLError(.cannotWriteToFile) }
            if ordinal == 2 {
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            try keychain.save(value)
        }, deletePairing: { try keychain.delete() })
        do {
            _ = try await store.disableRelayAccess(pairingGen: 0, mutationGen: 0)
            XCTFail("first save should fail")
        } catch {}
        let retry = Task { try await store.retryDurableClear(pairingGen: 0, mutationGen: 1) }
        await fulfillment(of: [entered], timeout: 2)
        let suite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = JournalVersionMetadata(defaults: defaults) { _ in nil }
        metadata.setIdentity(journalVersionMetadataIdentity(for: pairing))
        let accessRequests = OSAllocatedUnfairLock(initialState: 0)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("relay/access") == true { accessRequests.withLock { $0 += 1 } }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let jobs = HomeAuthenticatedJobs(store: store, journalVersion: metadata, client: makeTestClient(), deadline: .milliseconds(100))
        defer { jobs.disconnected() }
        jobs.connected(localPort: 7071)
        try await Task.sleep(for: .milliseconds(200))
        release.signal()
        let retried = try await retry.value
        XCTAssertTrue(retried)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(count.withLock { $0 }, 2)
        XCTAssertEqual(accessRequests.withLock { $0 }, 0)
        XCTAssertEqual(try keychain.load()?.relayEnrollment, .unavailable)
    }

    @MainActor
    func testMetadataFollowUpSharesOriginalDeadline() async throws {
        let pairing = makeSamplePairing()
        let store = PairingCredentialStore(loadPairing: { pairing }, savePairing: { _ in }, deletePairing: {})
        let suite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = JournalVersionMetadata(defaults: defaults) { _ in nil }
        metadata.setIdentity(journalVersionMetadataIdentity(for: pairing))
        let first = expectation(description: "first metadata request")
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let count = OSAllocatedUnfairLock(initialState: 0)
        MockURLProtocol.asyncRequestHandler = { request in
            guard request.url?.path.hasSuffix("clients/self") == true else {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            let ordinal = count.withLock { $0 += 1; return $0 }
            if ordinal == 1 {
                first.fulfill()
                for await _ in release.stream { break }
            } else if ordinal == 2 {
                try? await Task.sleep(for: .milliseconds(900))
            }
            let data = Data("""
            {"protocol_version":1,"revision":0,"reported":{"name":null,"platform":null,"device_type":null,"app_id":null,"app_version":null},"owner_label":null,"display_label":"Phone","updated_at":null,"journal":{"name":null,"version":"\(ordinal).0.0"}}
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let jobs = HomeAuthenticatedJobs(store: store, journalVersion: metadata, client: makeTestClient(), deadline: .seconds(1),
            snapshotProvider: { DeviceDescriptionSnapshot(name: nil, platform: nil, deviceType: nil, appID: nil, appVersion: nil) })
        defer { jobs.disconnected() }
        jobs.connected(localPort: 7071)
        await fulfillment(of: [first], timeout: 2)
        jobs.connected(localPort: 7071)
        try await Task.sleep(for: .milliseconds(250))
        release.continuation.yield(())
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(count.withLock { $0 }, 2)
        XCTAssertEqual(metadata.version, "1.0.0")
        jobs.connected(localPort: 7071)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(metadata.version, "3.0.0")
    }

}
