// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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
    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data())
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
                        "reported": { "name": "Old Phone" },
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
                            "reported": { "name": "New Phone" }
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
                        "reported": { "name": "Initial" }
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
                    return (response, Data())
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
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
        journalVersion.setIdentity("inst-1-id")
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
                        "reported": { "name": "Current" },
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
    func testUnchangedReportedDescriptionGETOnlyNoPUT() async throws {
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
                        "reported": { "name": "Old Name" }
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, json)
                } else if request.httpMethod == "PUT" {
                    capturedPutData.value = Self.extractBody(from: request)
                    putContinuation.yield(())
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data())
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

        let instance = "inst-1"
        let claims: [String: Any] = [
            "iss": "solstone-journal",
            "sub": "instance:\(instance)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instance,
            "iat": 1_800_000_000,
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
                    "reported": { "name": "Old Phone" },
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
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let defaultsSuite = "LifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("inst-1-id")

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
                            "name": "Old Phone"
                        },
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
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data())
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
}
