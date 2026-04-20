// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class ObserverRegistrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var session: URLSession!
    private var storedKey: String?

    override func setUp() {
        super.setUp()
        self.suiteName = "ObserverRegistrationTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverRegistrationURLProtocol.self]
        self.session = URLSession(configuration: configuration)

        self.storedKey = nil
        ObserverRegistrationURLProtocol.handler = nil
        ObserverRegistrationURLProtocol.callCount = 0
    }

    override func tearDown() async throws {
        self.session.invalidateAndCancel()
        self.session = nil
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        self.storedKey = nil
        ObserverRegistrationURLProtocol.handler = nil
        ObserverRegistrationURLProtocol.callCount = 0
        try await super.tearDown()
    }

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
        XCTAssertEqual(self.storedKey, "observer-key-123")
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 1)
    }

    func testEnsureRegisteredSkipsNetworkWhenKeyExists() async throws {
        self.storedKey = "existing-key"
        let registration = self.makeRegistration()

        let key = try await registration.ensureRegistered()

        XCTAssertEqual(key, "existing-key")
        XCTAssertEqual(ObserverRegistrationURLProtocol.callCount, 0)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .registered)
    }

    func testEnsureRegisteredRetriesAndSucceeds() async throws {
        let sleepRecorder = SleepRecorder()
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
            sleep: { delay in await sleepRecorder.record(delay) }
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

    func testResetClearsKeyAndState() async throws {
        self.storedKey = "existing-key"
        let registration = self.makeRegistration()

        await MainActor.run {
            registration.reset()
        }

        XCTAssertNil(self.storedKey)
        let state = await MainActor.run { registration.state }
        XCTAssertEqual(state, .idle)
    }

    private func makeRegistration(
        retryDelays: [UInt64] = [1, 2, 3],
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) -> ObserverRegistration {
        ObserverRegistration(
            session: self.session,
            retryDelays: retryDelays,
            sleep: sleep,
            loadKey: { [weak self] in self?.storedKey },
            saveKey: { [weak self] key in self?.storedKey = key },
            deleteKey: { [weak self] in self?.storedKey = nil }
        )
    }
}

private final class ObserverRegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    static var callCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCount += 1
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

private actor SleepRecorder {
    private var recordedValues: [UInt64] = []

    func record(_ value: UInt64) {
        self.recordedValues.append(value)
    }

    func values() -> [UInt64] {
        self.recordedValues
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
