// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ObserverRegistrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var session: URLSession!
    private let storedKeyBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let storedPrefixBox = OSAllocatedUnfairLock<String?>(initialState: nil)

    override func setUp() {
        super.setUp()
        self.suiteName = "ObserverRegistrationTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverRegistrationURLProtocol.self]
        self.session = URLSession(configuration: configuration)

        self.storedKeyBox.withLock { $0 = nil }
        self.storedPrefixBox.withLock { $0 = nil }
        ObserverRegistrationURLProtocol.handler = nil
        ObserverRegistrationURLProtocol.callCount = 0
    }

    override func tearDown() async throws {
        self.session.invalidateAndCancel()
        self.session = nil
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        self.storedKeyBox.withLock { $0 = nil }
        self.storedPrefixBox.withLock { $0 = nil }
        ObserverRegistrationURLProtocol.handler = nil
        ObserverRegistrationURLProtocol.callCount = 0
        try await super.tearDown()
    }

    @MainActor
    func testEnsureRegisteredSuccessPersistsKey() async throws {
        ObserverRegistrationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/app/observer/register")
            let body = try XCTUnwrap(requestBody(from: request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["platform"], "ios")
            XCTAssertEqual(payload["hostname"], "test-device")
            XCTAssertEqual(payload["stream_type"], "mobile")
            XCTAssertEqual(payload["version"], "1.2.3")
            XCTAssertNil(payload["label"])
            XCTAssertNil(payload["name"])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"name":"solstone-swift","key":"observer-key-123","prefix":"obs_"}"#.utf8)
            )
        }

        let registration = self.makeRegistration()
        await MainActor.run {
            registration.activeLocalPort = 7071
        }

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "observer-key-123")
        XCTAssertEqual(self.storedKeyBox.withLock { $0 }, "observer-key-123")
        XCTAssertEqual(self.storedPrefixBox.withLock { $0 }, "obs_")
        XCTAssertEqual(registration.registrationPrefix, "obs_")
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 1)
    }

    @MainActor
    func testEnsureRegisteredSkipsNetworkWhenKeyExists() async throws {
        self.storedKeyBox.withLock { $0 = "existing-key" }
        self.storedPrefixBox.withLock { $0 = "obs_existing_" }
        let registration = self.makeRegistration()

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "existing-key")
        XCTAssertEqual(registration.registrationPrefix, "obs_existing_")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 0)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
    }

    @MainActor
    func testEnsureRegisteredSkipsNetworkWhenKeyExistsAndPrefixMissing() async throws {
        self.storedKeyBox.withLock { $0 = "existing-key" }
        self.storedPrefixBox.withLock { $0 = nil }
        let registration = self.makeRegistration()

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "existing-key")
        XCTAssertEqual(registration.registrationPrefix, "existing")
        XCTAssertEqual(self.storedPrefixBox.withLock { $0 }, "existing")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 0)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
    }

    @MainActor
    func testMissingPersistedPrefixBackfillsFromCachedKeyAndPersists() async throws {
        let key = "ABCDEFGH1234567890"
        let keyBox = OSAllocatedUnfairLock<String?>(initialState: key)
        let prefixBox = OSAllocatedUnfairLock<String?>(initialState: nil)

        let registration = self.makeRegistration(
            keyBox: keyBox,
            prefixBox: prefixBox
        )

        XCTAssertEqual(registration.registrationPrefix, "ABCDEFGH")
        XCTAssertEqual(prefixBox.withLock { $0 }, "ABCDEFGH")
        let restoredKey = try await registration.ensureRegistered()
        XCTAssertEqual(restoredKey, key)
        XCTAssertEqual(registration.registrationPrefix, "ABCDEFGH")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 0)

        let restored = self.makeRegistration(
            keyBox: keyBox,
            prefixBox: prefixBox
        )

        XCTAssertEqual(restored.registrationPrefix, "ABCDEFGH")
    }

    @MainActor
    func testRestoredDeviceReregistersAndReplacesStalePrefix() async throws {
        self.storedKeyBox.withLock { $0 = nil }
        self.storedPrefixBox.withLock { $0 = "obs_stale_" }
        ObserverRegistrationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/app/observer/register")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"name":"solstone-swift","key":"observer-key-fresh","prefix":"obs_fresh_"}"#.utf8)
            )
        }

        let registration = self.makeRegistration()
        await MainActor.run {
            registration.activeLocalPort = 7071
        }

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "observer-key-fresh")
        XCTAssertEqual(self.storedKeyBox.withLock { $0 }, "observer-key-fresh")
        XCTAssertEqual(self.storedPrefixBox.withLock { $0 }, "obs_fresh_")
        XCTAssertEqual(registration.registrationPrefix, "obs_fresh_")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 1)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
    }

    @MainActor
    func testFreshRegistrationLeavesNoStalePrefixWhenSavePrefixThrows() async throws {
        self.storedKeyBox.withLock { $0 = nil }
        self.storedPrefixBox.withLock { $0 = "obs_stale_" }
        ObserverRegistrationURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"name":"solstone-swift","key":"observer-key-fresh","prefix":"obs_fresh_"}"#.utf8)
            )
        }

        let registration = self.makeRegistration(
            retryDelays: [1],
            savePrefix: { _ in throw ObserverRegistrationTestError.injectedSavePrefixFailure }
        )
        await MainActor.run {
            registration.activeLocalPort = 7071
        }

        do {
            _ = try await registration.ensureRegistered()
            XCTFail("expected registration failure")
        } catch {}

        XCTAssertNil(self.storedKeyBox.withLock { $0 })
        XCTAssertNil(self.storedPrefixBox.withLock { $0 })
    }

    @MainActor
    func testRestoredDeviceReregistersAcrossAllStreams() async throws {
        let streams = [
            (
                streamType: "mobile",
                keyBox: OSAllocatedUnfairLock<String?>(initialState: nil),
                prefixBox: OSAllocatedUnfairLock<String?>(initialState: "stale_mobile_")
            ),
            (
                streamType: "omi",
                keyBox: OSAllocatedUnfairLock<String?>(initialState: nil),
                prefixBox: OSAllocatedUnfairLock<String?>(initialState: "stale_omi_")
            ),
            (
                streamType: "watch",
                keyBox: OSAllocatedUnfairLock<String?>(initialState: nil),
                prefixBox: OSAllocatedUnfairLock<String?>(initialState: "stale_watch_")
            ),
        ]

        for stream in streams {
            let streamType = stream.streamType
            let expectedKey = "observer-key-\(streamType)"
            let expectedPrefix = "obs_\(streamType)_"
            ObserverRegistrationURLProtocol.handler = { request in
                let body = try XCTUnwrap(requestBody(from: request))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(payload["stream_type"], streamType)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"name":"solstone-swift","key":"\#(expectedKey)","prefix":"\#(expectedPrefix)"}"#.utf8)
                )
            }

            let registration = self.makeRegistration(
                streamType: streamType,
                keyBox: stream.keyBox,
                prefixBox: stream.prefixBox
            )
            await MainActor.run {
                registration.activeLocalPort = 7071
            }

            let key = try await registration.ensureRegistered()

            XCTAssertEqual(key, expectedKey)
            XCTAssertEqual(registration.registrationPrefix, expectedPrefix)
        }

        for stream in streams {
            XCTAssertEqual(stream.keyBox.withLock { $0 }, "observer-key-\(stream.streamType)")
            XCTAssertEqual(stream.prefixBox.withLock { $0 }, "obs_\(stream.streamType)_")
        }
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, streams.count)
    }

    @MainActor
    func testEnsureRegisteredRetriesAndSucceeds() async throws {
        let sleepRecorder = DelayRecorder()
        ObserverRegistrationURLProtocol.handler = { request in
            if ObserverRegistrationURLProtocol.callCount < 2 {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"name":"solstone-swift","key":"observer-key-123","prefix":"obs_"}"#.utf8)
            )
        }

        let registration = self.makeRegistration(
            retryDelays: [2, 4, 8],
            sleep: { delay in await sleepRecorder.append(delay) }
        )
        await MainActor.run {
            registration.activeLocalPort = 7071
        }

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "observer-key-123")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 2)
        let recordedSleeps = await sleepRecorder.values()
        XCTAssertEqual(recordedSleeps, [2])
    }

    @MainActor
    func testEnsureRegisteredHardFailureSetsFailedState() async {
        ObserverRegistrationURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let registration = self.makeRegistration(retryDelays: [2])
        await MainActor.run {
            registration.activeLocalPort = 7071
        }

        do {
            _ = try await registration.ensureRegistered()
            XCTFail("expected registration failure")
        } catch {}

        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .failed(reason: "HTTP 503"))
    }

    @MainActor
    func testResetClearsKeyAndState() async throws {
        self.storedKeyBox.withLock { $0 = "existing-key" }
        self.storedPrefixBox.withLock { $0 = "obs_existing_" }
        let registration = self.makeRegistration()

        await MainActor.run {
            registration.reset()
        }

        XCTAssertNil(self.storedKeyBox.withLock { $0 })
        XCTAssertNil(self.storedPrefixBox.withLock { $0 })
        XCTAssertNil(registration.registrationPrefix)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .idle)
    }

    @MainActor private func makeRegistration(
        streamType: String = "mobile",
        keyBox: OSAllocatedUnfairLock<String?>? = nil,
        prefixBox: OSAllocatedUnfairLock<String?>? = nil,
        retryDelays: [UInt64] = [1, 2, 3],
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        savePrefix: (@Sendable (String) throws -> Void)? = nil
    ) -> ObserverRegistration {
        let keyBox = keyBox ?? self.storedKeyBox
        let prefixBox = prefixBox ?? self.storedPrefixBox
        let savePrefix = savePrefix ?? { [prefixBox] prefix in prefixBox.withLock { $0 = prefix } }
        return ObserverRegistration(
            hostname: "test-device",
            version: "1.2.3",
            streamType: streamType,
            session: self.session,
            retryDelays: retryDelays,
            sleep: sleep,
            loadKey: { [keyBox] in keyBox.withLock { $0 } },
            saveKey: { [keyBox] key in keyBox.withLock { $0 = key } },
            deleteKey: { [keyBox] in keyBox.withLock { $0 = nil } },
            loadPrefix: { [prefixBox] in prefixBox.withLock { $0 } },
            savePrefix: savePrefix,
            deletePrefix: { [prefixBox] in prefixBox.withLock { $0 = nil } }
        )
    }
}

private enum ObserverRegistrationTestError: Error {
    case injectedSavePrefixFailure
}

private final class ObserverRegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }
    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        guard let handler = Self.handler else {
            XCTFail("ObserverRegistrationURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor DelayRecorder {
    private var valuesStore: [UInt64] = []

    func append(_ value: UInt64) {
        self.valuesStore.append(value)
    }

    func values() -> [UInt64] {
        self.valuesStore
    }
}

nonisolated private func requestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }

    return data
}
