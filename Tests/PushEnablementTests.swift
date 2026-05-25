// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class PushEnablementTests: XCTestCase {
    private var pollSession: URLSession!
    private var keychain: PushEnablementKeychain!
    private var webAuth: MockWebAuthSession!
    private var pushManager: PushNotificationManager!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushEnablementURLProtocol.self]
        self.pollSession = URLSession(configuration: configuration)
        self.keychain = PushEnablementKeychain(
            serviceOverride: "app.solstone.swift.push.tests.\(UUID().uuidString)"
        )
        try? self.keychain.delete()
        self.webAuth = MockWebAuthSession()
        self.defaultsSuiteName = "PushEnablementTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.defaultsSuiteName)
        self.defaults.removePersistentDomain(forName: self.defaultsSuiteName)
        self.pushManager = PushNotificationManager(defaults: self.defaults, session: self.pollSession)
        await self.pushManager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        PushEnablementURLProtocol.handler = nil
        PushEnablementURLProtocol.callCount = 0
    }

    override func tearDown() async throws {
        self.pollSession.invalidateAndCancel()
        self.pollSession = nil
        try? self.keychain.delete()
        self.keychain = nil
        self.webAuth = nil
        self.pushManager = nil
        self.defaults.removePersistentDomain(forName: self.defaultsSuiteName)
        self.defaults = nil
        self.defaultsSuiteName = nil
        PushEnablementURLProtocol.handler = nil
        PushEnablementURLProtocol.callCount = 0
        try await super.tearDown()
    }

    func testPoll200PersistsRecord() async throws {
        PushEnablementURLProtocol.handler = { request in
            Self.response(status: 200, url: request.url!, data: Self.recordData(deviceId: "device-1"))
        }
        let enablement = self.makeEnablement()

        try await enablement.enablePush()

        XCTAssertEqual(try self.keychain.load()?.deviceId, "device-1")
        XCTAssertEqual(enablement.state, .enabled)
    }

    func testPoll204Then200PersistsSecondResponse() async throws {
        PushEnablementURLProtocol.handler = { request in
            if PushEnablementURLProtocol.callCount == 1 {
                return Self.response(status: 204, url: request.url!, data: Data())
            }
            return Self.response(status: 200, url: request.url!, data: Self.recordData(deviceId: "device-2"))
        }
        let enablement = self.makeEnablement()

        try await enablement.enablePush()

        XCTAssertEqual(PushEnablementURLProtocol.callCount, 2)
        XCTAssertEqual(try self.keychain.load()?.deviceId, "device-2")
    }

    func testPoll410FailsWithConsentExpiredMessage() async {
        PushEnablementURLProtocol.handler = { request in
            Self.response(status: 410, url: request.url!, data: Data())
        }
        let enablement = self.makeEnablement()

        await self.assertEnablement(enablement, throws: .consentLinkExpired)
        XCTAssertEqual(enablement.state, .failed(message: "consent link expired"))
    }

    func testPoll400FailsWithPortalRejectedMessage() async {
        PushEnablementURLProtocol.handler = { request in
            Self.response(status: 400, url: request.url!, data: Data())
        }
        let enablement = self.makeEnablement()

        await self.assertEnablement(enablement, throws: .portalRejected)
        XCTAssertEqual(enablement.state, .failed(message: "the portal rejected the request"))
    }

    func testPoll5xxThen200Succeeds() async throws {
        PushEnablementURLProtocol.handler = { request in
            if PushEnablementURLProtocol.callCount == 1 {
                return Self.response(status: 503, url: request.url!, data: Data())
            }
            return Self.response(status: 200, url: request.url!, data: Self.recordData(deviceId: "device-3"))
        }
        let enablement = self.makeEnablement()

        try await enablement.enablePush()

        XCTAssertEqual(try self.keychain.load()?.deviceId, "device-3")
    }

    func testNetworkErrorThen200Succeeds() async throws {
        PushEnablementURLProtocol.handler = { request in
            if PushEnablementURLProtocol.callCount == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return Self.response(status: 200, url: request.url!, data: Self.recordData(deviceId: "device-4"))
        }
        let enablement = self.makeEnablement()

        try await enablement.enablePush()

        XCTAssertEqual(try self.keychain.load()?.deviceId, "device-4")
    }

    func testWallTimeoutFailsWithPortalTimeoutMessage() async {
        let enablement = self.makeEnablement(pollBudget: -1)

        await self.assertEnablement(enablement, throws: .portalTimeout)
        XCTAssertEqual(enablement.state, .failed(message: "didn't hear back from the portal"))
    }

    func testDeviceTokenHexEncodingIsUsedInEnableURL() async throws {
        PushEnablementURLProtocol.handler = { request in
            Self.response(status: 200, url: request.url!, data: Self.recordData(deviceId: "device-5"))
        }
        let enablement = self.makeEnablement()

        try await enablement.enablePush()

        let url = try XCTUnwrap(self.webAuth.startedURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(Self.queryValue("device_token", in: components), "deadbeef")
    }

    func testUserCancelThrowsCancellationError() async {
        PushEnablementURLProtocol.handler = { request in
            Self.response(status: 503, url: request.url!, data: Data())
        }
        let enablement = PushEnablement(
            pushManager: self.pushManager,
            keychain: self.keychain,
            webAuth: self.webAuth,
            pollSession: self.pollSession,
            sleep: { delay in try? await Task.sleep(nanoseconds: delay) },
            pollBudget: 15 * 60,
            retryDelayNanoseconds: 1_000_000_000
        )

        let task = Task {
            try await enablement.enablePush()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testWebAuthDismissDoesNotStopPolling() async throws {
        self.webAuth.completionResult = .failure(WebAuthSessionError.failedToStart)
        PushEnablementURLProtocol.handler = { request in
            Self.response(status: 200, url: request.url!, data: Self.recordData(deviceId: "device-6"))
        }
        let enablement = self.makeEnablement()

        try await enablement.enablePush()

        XCTAssertEqual(try self.keychain.load()?.deviceId, "device-6")
        XCTAssertEqual(enablement.state, .enabled)
    }

    private func makeEnablement(pollBudget: TimeInterval = 15 * 60) -> PushEnablement {
        PushEnablement(
            pushManager: self.pushManager,
            keychain: self.keychain,
            webAuth: self.webAuth,
            pollSession: self.pollSession,
            sleep: { _ in },
            pollBudget: pollBudget,
            retryDelayNanoseconds: 1
        )
    }

    private func assertEnablement(
        _ enablement: PushEnablement,
        throws expectedError: PushEnablementError
    ) async {
        do {
            try await enablement.enablePush()
            XCTFail("expected \(expectedError)")
        } catch let error as PushEnablementError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("expected \(expectedError), got \(error)")
        }
    }

    nonisolated private static func response(status: Int, url: URL, data: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
            data
        )
    }

    nonisolated private static func recordData(deviceId: String) -> Data {
        Data(
            #"{"account_id":"account-1","device_id":"\#(deviceId)","dispatch_token":"dispatch-1","created_at":"2026-05-24T00:00:00Z"}"#.utf8
        )
    }

    nonisolated private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }
}

@MainActor
private final class MockWebAuthSession: WebAuthSessionStarting {
    var startedURL: URL?
    var completionResult: Result<Void, Error>?

    func start(
        url: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) throws {
        self.startedURL = url
        if let completionResult {
            completion(completionResult)
        } else {
            completion(.success(()))
        }
    }
}

private final class PushEnablementURLProtocol: URLProtocol, @unchecked Sendable {
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

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "services.solstone.app"
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        guard let handler = Self.handler else {
            XCTFail("PushEnablementURLProtocol handler not set")
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
