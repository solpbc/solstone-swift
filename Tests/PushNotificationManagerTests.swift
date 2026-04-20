// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class PushNotificationManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var session: URLSession!

    nonisolated override func setUp() {
        super.setUp()
        self.suiteName = "PushNotificationManagerTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushManagerURLProtocol.self]
        self.session = URLSession(configuration: configuration)

        PushManagerURLProtocol.handler = nil
        PushManagerURLProtocol.callCount = 0
    }

    nonisolated override func tearDown() async throws {
        self.session.invalidateAndCancel()
        self.session = nil
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        PushManagerURLProtocol.handler = nil
        PushManagerURLProtocol.callCount = 0
        try await super.tearDown()
    }

    func testHexEncodeOfFourByteTokenRegistersHexValue() async {
        PushManagerURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let manager = self.makeManager()
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))

        XCTAssertEqual(manager.deviceToken, "deadbeef")
        XCTAssertEqual(manager.registrationState, .registered(token: "deadbeef"))
    }

    func testRegisterBodyMatchesContract() async throws {
        PushManagerURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/push/register")
            let body = try XCTUnwrap(requestBody(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["device_token"], "deadbeef")
            XCTAssertEqual(json["bundle_id"], "org.solpbc.solstone-swift")
            XCTAssertEqual(json["environment"], "development")
            XCTAssertEqual(json["platform"], "ios")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let manager = self.makeManager()
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testRetryBackoffTriggersThreeAttemptsOnServerFailure() async {
        let sleepRecorder = DelayRecorder()
        PushManagerURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let manager = self.makeManager(
            retryDelays: [2, 4, 8],
            sleep: { delay in await sleepRecorder.append(delay) }
        )
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))

        XCTAssertEqual(PushManagerURLProtocol.callCount, 3)
        let recordedSleeps = await sleepRecorder.values()
        XCTAssertEqual(recordedSleeps, [2, 4])
        XCTAssertEqual(manager.registrationState, .failed(reason: "HTTP 503"))
    }

    func testPendingTokenPersistedOnFailure() async {
        PushManagerURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let manager = self.makeManager()
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xaa, 0xbb, 0xcc, 0xdd]))

        XCTAssertEqual(self.defaults.string(forKey: "push.pendingRegistrationToken"), "aabbccdd")
    }

    func testSameTokenSkipsNetworkRegistration() async {
        self.defaults.set("deadbeef", forKey: "push.lastRegisteredToken")
        self.defaults.set("development", forKey: "push.lastRegisteredEnvironment")
        PushManagerURLProtocol.handler = { request in
            XCTFail("expected skip without network request")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let manager = self.makeManager()
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))

        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)
        XCTAssertEqual(manager.registrationState, .registered(token: "deadbeef"))
    }

    private func makeManager(
        retryDelays: [UInt64] = [1, 2, 3],
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) -> PushNotificationManager {
        PushNotificationManager(
            defaults: self.defaults,
            session: self.session,
            retryDelays: retryDelays,
            sleep: sleep,
            bundleIdentifierOverride: "org.solpbc.solstone-swift",
            environmentOverride: "development"
        )
    }
}

private final class PushManagerURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    static var callCount = 0

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        Self.callCount += 1
        guard let handler = Self.handler else {
            XCTFail("PushManagerURLProtocol handler not set")
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

    nonisolated override func stopLoading() {}
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

private actor DelayRecorder {
    private var valuesStore: [UInt64] = []

    func append(_ value: UInt64) {
        self.valuesStore.append(value)
    }

    func values() -> [UInt64] {
        self.valuesStore
    }
}
