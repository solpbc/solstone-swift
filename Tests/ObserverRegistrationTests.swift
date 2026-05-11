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

    override func setUp() {
        super.setUp()
        self.suiteName = "ObserverRegistrationTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverRegistrationURLProtocol.self]
        self.session = URLSession(configuration: configuration)

        self.storedKeyBox.withLock { $0 = nil }
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
        ObserverRegistrationURLProtocol.handler = nil
        ObserverRegistrationURLProtocol.callCount = 0
        try await super.tearDown()
    }

    @MainActor
    func testEnsureRegisteredSuccessPersistsKey() async throws {
        ObserverRegistrationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/app/observer/api/create")
            let body = try XCTUnwrap(requestBody(from: request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["name"], "solstone-swift")
            XCTAssertEqual(payload["platform"], "ios")
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
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 1)
    }

    @MainActor
    func testEnsureRegisteredSkipsNetworkWhenKeyExists() async throws {
        self.storedKeyBox.withLock { $0 = "existing-key" }
        let registration = self.makeRegistration()

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "existing-key")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 0)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
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
        let registration = self.makeRegistration()

        await MainActor.run {
            registration.reset()
        }

        XCTAssertNil(self.storedKeyBox.withLock { $0 })
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .idle)
    }

    @MainActor private func makeRegistration(
        retryDelays: [UInt64] = [1, 2, 3],
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) -> ObserverRegistration {
        ObserverRegistration(
            session: self.session,
            retryDelays: retryDelays,
            sleep: sleep,
            loadKey: { [storedKeyBox] in storedKeyBox.withLock { $0 } },
            saveKey: { [storedKeyBox] key in storedKeyBox.withLock { $0 = key } },
            deleteKey: { [storedKeyBox] in storedKeyBox.withLock { $0 = nil } }
        )
    }
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
