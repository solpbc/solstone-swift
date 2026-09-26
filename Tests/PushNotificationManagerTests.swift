// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class PushNotificationManagerTests: XCTestCase {
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

    @MainActor
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

    @MainActor
    func testRegisterBodyMatchesContract() async throws {
        let recordedBodies = OSAllocatedUnfairLock<[[String: String]]>(initialState: [])
        PushManagerURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/push/register")
            let body = try XCTUnwrap(requestBody(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            recordedBodies.withLock { $0.append(json) }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let keyStore = PushKeyStore.memory()
        let manager = self.makeManager(keyStore: keyStore)
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        let bodies1 = recordedBodies.withLock { $0 }
        XCTAssertEqual(bodies1.count, 1)
        let firstBody = bodies1[0]
        let expectedKeys = Set(["bundle_id", "device_token", "environment", "platform", "push_key"])
        XCTAssertEqual(Set(firstBody.keys), expectedKeys)
        XCTAssertEqual(firstBody["device_token"], "deadbeef")
        XCTAssertEqual(firstBody["bundle_id"], "app.solstone.swift")
        XCTAssertEqual(firstBody["environment"], "development")
        XCTAssertEqual(firstBody["platform"], "ios")
        let firstPushKey = try XCTUnwrap(firstBody["push_key"])

        // Second registration yields same push_key
        await manager.handleTunnelConnected(localPort: 8474)
        let bodies2 = recordedBodies.withLock { $0 }
        XCTAssertEqual(bodies2.count, 2)
        XCTAssertEqual(bodies2[1]["push_key"], firstPushKey)

        // After delete, next body has different push_key
        try keyStore.delete()
        await manager.handleTunnelConnected(localPort: 8474)
        let bodies3 = recordedBodies.withLock { $0 }
        XCTAssertEqual(bodies3.count, 3)
        XCTAssertNotEqual(bodies3[2]["push_key"], firstPushKey)
    }

    @MainActor
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

    @MainActor
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

    @MainActor
    func testTunnelConnectedReregisters() async {
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
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)

        await manager.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 2)
        XCTAssertEqual(manager.registrationState, .registered(token: "deadbeef"))
    }

    @MainActor
    func testHandleTunnelConnectedTokenSources() async {
        PushManagerURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        // 1. No pending token and known deviceToken -> sends 1
        PushManagerURLProtocol.callCount = 0
        let manager1 = self.makeManager()
        await manager1.submitToken(Data([0x11, 0x22, 0x33, 0x44]))
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0) // not connected yet
        XCTAssertEqual(self.defaults.string(forKey: "push.pendingRegistrationToken"), "11223344")
        self.defaults.removeObject(forKey: "push.pendingRegistrationToken")
        XCTAssertEqual(manager1.deviceToken, "11223344")
        await manager1.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)

        // 2. Only push.lastRegisteredToken (env mismatch so restore does not copy it to deviceToken) -> sends 1
        PushManagerURLProtocol.callCount = 0
        let manager2Defaults = UserDefaults(suiteName: "T2.\(UUID().uuidString)")!
        manager2Defaults.set(true, forKey: "push.ownerEnabled")
        manager2Defaults.set("55667788", forKey: "push.lastRegisteredToken")
        manager2Defaults.set("production", forKey: "push.registeredEnvironment") // mismatch with override "development"
        let manager2 = PushNotificationManager(
            defaults: manager2Defaults,
            session: self.session,
            keyStore: .memory(),
            retryDelays: [1],
            sleep: { _ in },
            bundleIdentifierOverride: "app.solstone.swift",
            environmentOverride: "development",
            register: {},
            isSimulator: false,
            profileBytes: { nil }
        )
        XCTAssertNil(manager2.deviceToken)
        await manager2.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)

        // 3. None of the three -> sends none
        PushManagerURLProtocol.callCount = 0
        let manager3Defaults = UserDefaults(suiteName: "T3.\(UUID().uuidString)")!
        manager3Defaults.set(true, forKey: "push.ownerEnabled")
        let manager3 = PushNotificationManager(
            defaults: manager3Defaults,
            session: self.session,
            keyStore: .memory(),
            retryDelays: [1],
            sleep: { _ in },
            bundleIdentifierOverride: "app.solstone.swift",
            environmentOverride: "development",
            register: {},
            isSimulator: false,
            profileBytes: { nil }
        )
        XCTAssertNil(manager3.deviceToken)
        await manager3.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)
    }

    @MainActor
    func testBadPrefixFailsWithNoKeyReason() async {
        let badStore = PushKeyStore.memory(prefix: "INVALID")
        let manager = self.makeManager(keyStore: badStore)
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(manager.registrationState, .failed(reason: "no_key"))
    }

    @MainActor
    func testKeychainLockedFailsWithKeyUnavailableReason() async {
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in (errSecInteractionNotAllowed, nil) },
            add: { _ in errSecInteractionNotAllowed },
            delete: { _ in errSecInteractionNotAllowed }
        )
        let lockedStore = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        let manager = self.makeManager(keyStore: lockedStore)
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(manager.registrationState, .failed(reason: "key_unavailable"))
    }

    @MainActor
    func testReregisterIfAuthorizedUsesInjectedRegisterClosureOnlyForAuthorizedStates() {
        let cases: [(PushNotificationManager.PermissionState, Int)] = [
            (.authorized, 1),
            (.provisional, 1),
            (.denied, 0),
            (.notDetermined, 0),
        ]

        for (permissionState, expectedCount) in cases {
            let registerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
            let manager = self.makeManager(
                register: {
                    registerCount.withLock { $0 += 1 }
                }
            )

            manager.setPermissionStateForTesting(permissionState)
            manager.reregisterIfAuthorized()

            XCTAssertEqual(registerCount.withLock { $0 }, expectedCount)
        }
    }

    func testApsEnvironmentExtractsWrappedProfilePlist() {
        XCTAssertEqual(
            PushNotificationManager.apsEnvironment(fromProfile: Self.profileBytes(environment: "development")),
            "development"
        )
    }

    @MainActor
    func testEnvironmentUsesSimulatorDevelopmentBeforeProfile() async throws {
        try await self.assertRegisteredEnvironment(
            expected: "development",
            isSimulator: true,
            profileBytes: { Self.profileBytes(environment: "production") }
        )
    }

    @MainActor
    func testEnvironmentUsesProfileApsEnvironmentWhenNotSimulator() async throws {
        try await self.assertRegisteredEnvironment(
            expected: "development",
            isSimulator: false,
            profileBytes: { Self.profileBytes(environment: "development") }
        )
    }

    @MainActor
    func testEnvironmentFallsBackToProductionWithoutSimulatorOrProfile() async throws {
        try await self.assertRegisteredEnvironment(
            expected: "production",
            isSimulator: false,
            profileBytes: { nil }
        )
    }

    @MainActor
    func testDefaultOffNeverRegisters() async {
        PushManagerURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let manager = self.makeManager(ownerEnabled: nil)
        manager.setPermissionStateForTesting(.authorized)
        manager.activeLocalPort = 8474

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        await manager.handleTunnelConnected(localPort: 8474)
        manager.reregisterIfAuthorized()

        XCTAssertFalse(manager.ownerEnabled)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)
        XCTAssertEqual(manager.registrationState, .idle)
    }

    func testTestNotificationCountsAsSentOnlyWhenThisDeviceWasSentTo() {
        let token = "deadbeefcafe1234"
        func body(_ items: String) -> Data { Data(#"{"items":[\#(items)],"total":1,"cursor":null}"#.utf8) }

        XCTAssertTrue(PushNotificationManager.testWasSentToThisDevice(
            body(#"{"platform":"ios","target":"...1234","outcome":"sent"}"#), token: token
        ))
        XCTAssertFalse(PushNotificationManager.testWasSentToThisDevice(
            body(#"{"platform":"ios","target":"...1234","outcome":"failed"}"#), token: token
        ))
        XCTAssertFalse(PushNotificationManager.testWasSentToThisDevice(
            body(#"{"platform":"ios","target":"...9999","outcome":"sent"}"#), token: token
        ), "another device's delivery is not this one's")
        XCTAssertFalse(PushNotificationManager.testWasSentToThisDevice(
            body(#"{"platform":"ios","target":"...1234","outcome":"revoked"}"#), token: token
        ))
        XCTAssertFalse(PushNotificationManager.testWasSentToThisDevice(Data(#"{"queued":true}"#.utf8), token: token))
        XCTAssertFalse(PushNotificationManager.testWasSentToThisDevice(
            body(#"{"platform":"ios","target":"...1234","outcome":"sent"}"#), token: nil
        ))
    }

    @MainActor
    func testForgettingTheJournalEndsTheTurnOnSoTheNextJournalIsNotRegistered() async {
        PushManagerURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let manager = self.makeManager(ownerEnabled: true)
        manager.setPermissionStateForTesting(.authorized)
        manager.activeLocalPort = 8474
        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)

        manager.forgetJournal()
        manager.activeLocalPort = nil

        XCTAssertFalse(manager.ownerEnabled)
        XCTAssertEqual(manager.registrationState, .idle)
        XCTAssertFalse(self.defaults.bool(forKey: "push.ownerEnabled"))
        XCTAssertNil(self.defaults.string(forKey: "push.lastRegisteredToken"))
        XCTAssertNil(self.defaults.string(forKey: "push.pendingRegistrationToken"))

        await manager.handleTunnelConnected(localPort: 9001)
        manager.reregisterIfAuthorized()
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1, "the next journal must not be registered until the owner turns it on")

        let relaunched = self.makeManager(ownerEnabled: nil)
        XCTAssertFalse(relaunched.ownerEnabled)
    }

    @MainActor
    func testTurnOffSendsOneDeleteAndStopsRegistering() async throws {
        let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        let deleteBodies = OSAllocatedUnfairLock<[[String: String]]>(initialState: [])
        PushManagerURLProtocol.handler = { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "DELETE" {
                let body = try XCTUnwrap(requestBody(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                deleteBodies.withLock { $0.append(json) }
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let manager = self.makeManager()
        manager.activeLocalPort = 8474
        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(manager.registrationState, .registered(token: "deadbeef"))

        await manager.turnOff()
        await manager.handleTunnelConnected(localPort: 8474)

        XCTAssertEqual(methods.withLock { $0 }, ["POST", "DELETE"])
        XCTAssertEqual(deleteBodies.withLock { $0 }, [["platform": "ios", "device_token": "deadbeef"]])
        XCTAssertNil(self.defaults.string(forKey: "push.lastRegisteredToken"))
        XCTAssertNil(self.defaults.string(forKey: "push.pendingUnregisterToken"))
        XCTAssertEqual(self.defaults.object(forKey: "push.ownerEnabled") as? Bool, false)
    }

    @MainActor
    func testExistingRegistrationIsRemovedOnceAfterUpdate() async {
        let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        PushManagerURLProtocol.handler = { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        self.defaults.set("deadbeef", forKey: "push.lastRegisteredToken")
        self.defaults.set("development", forKey: "push.registeredEnvironment")
        let manager = self.makeManager(ownerEnabled: nil)

        await manager.handleTunnelConnected(localPort: 8474)
        await manager.handleTunnelConnected(localPort: 8474)

        XCTAssertEqual(methods.withLock { $0 }, ["DELETE"])
        XCTAssertNil(self.defaults.string(forKey: "push.lastRegisteredToken"))
    }

    @MainActor
    func testTurnOffDuringRetryLeavesNoRegistration() async {
        let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        PushManagerURLProtocol.handler = { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            let status = request.httpMethod == "DELETE" ? 204 : 500
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
        let box = ManagerBox()
        let manager = self.makeManager(sleep: { _ in
            await MainActor.run { box.manager?.setOwnerEnabledForTesting(false) }
        })
        box.manager = manager
        manager.activeLocalPort = 8474

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))

        XCTAssertEqual(methods.withLock { $0 }, ["POST"])
        XCTAssertNil(self.defaults.string(forKey: "push.lastRegisteredToken"))
        XCTAssertNil(self.defaults.string(forKey: "push.pendingRegistrationToken"))
        XCTAssertEqual(manager.registrationState, .idle)
    }

    @MainActor
    func testTurnOffWhileRegisterIsInFlightEndsWithADelete() async {
        let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        let box = ManagerBox()
        PushManagerURLProtocol.handler = { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            if request.httpMethod == "POST" {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { box.manager?.setOwnerEnabledForTesting(false) }
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let manager = self.makeManager()
        box.manager = manager
        manager.activeLocalPort = 8474

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))

        XCTAssertEqual(methods.withLock { $0 }, ["POST", "DELETE"])
        XCTAssertNil(self.defaults.string(forKey: "push.lastRegisteredToken"))
        XCTAssertNil(self.defaults.string(forKey: "push.pendingUnregisterToken"))
        XCTAssertNil(self.defaults.string(forKey: "push.pendingRegistrationToken"))
    }

    @MainActor
    func testReregisterDoesNothingWhileOff() {
        let registerCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let manager = self.makeManager(register: { registerCount.withLock { $0 += 1 } }, ownerEnabled: nil)
        manager.setPermissionStateForTesting(.authorized)
        manager.reregisterIfAuthorized()
        XCTAssertEqual(registerCount.withLock { $0 }, 0)
    }

    @MainActor
    func testFailedDeleteIsRetriedOnTheNextConnection() async {
        let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        let failFirst = OSAllocatedUnfairLock<Int>(initialState: 3)
        PushManagerURLProtocol.handler = { request in
            methods.withLock { $0.append(request.httpMethod ?? "") }
            let fail = failFirst.withLock { remaining -> Bool in
                if remaining > 0 { remaining -= 1; return true }
                return false
            }
            return (HTTPURLResponse(url: request.url!, statusCode: fail ? 500 : 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        self.defaults.set("deadbeef", forKey: "push.lastRegisteredToken")
        let manager = self.makeManager(ownerEnabled: nil)

        await manager.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(self.defaults.string(forKey: "push.pendingUnregisterToken"), "deadbeef")
        await manager.handleTunnelConnected(localPort: 8474)

        XCTAssertEqual(methods.withLock { $0 }, ["DELETE", "DELETE", "DELETE", "DELETE"])
        XCTAssertNil(self.defaults.string(forKey: "push.pendingUnregisterToken"))
    }

    @MainActor
    func testTurnOnWithAuthorizedPermissionAsksForAToken() async {
        let registerCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let manager = self.makeManager(register: { registerCalls.withLock { $0 += 1 } }, ownerEnabled: nil)
        manager.setPermissionStateForTesting(.authorized)

        await manager.turnOn()

        XCTAssertTrue(manager.ownerEnabled)
        XCTAssertEqual(registerCalls.withLock { $0 }, 1)
        XCTAssertEqual(self.defaults.object(forKey: "push.ownerEnabled") as? Bool, true)
    }

    @MainActor private func makeManager(
        keyStore: PushKeyStore = .memory(),
        retryDelays: [UInt64] = [1, 2, 3],
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        environmentOverride: String? = "development",
        register: @escaping @MainActor @Sendable () -> Void = {},
        isSimulator: Bool = false,
        profileBytes: @escaping @Sendable () -> Data? = { nil },
        ownerEnabled: Bool? = true
    ) -> PushNotificationManager {
        if let ownerEnabled {
            self.defaults.set(ownerEnabled, forKey: "push.ownerEnabled")
        }
        return PushNotificationManager(
            defaults: self.defaults,
            session: self.session,
            keyStore: keyStore,
            retryDelays: retryDelays,
            sleep: sleep,
            bundleIdentifierOverride: "app.solstone.swift",
            environmentOverride: environmentOverride,
            register: register,
            isSimulator: isSimulator,
            profileBytes: profileBytes
        )
    }

    @MainActor private func assertRegisteredEnvironment(
        expected: String,
        isSimulator: Bool,
        profileBytes: @escaping @Sendable () -> Data?
    ) async throws {
        PushManagerURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(requestBody(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["environment"], expected)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let manager = self.makeManager(
            environmentOverride: nil,
            isSimulator: isSimulator,
            profileBytes: profileBytes
        )
        await MainActor.run {
            manager.activeLocalPort = 8474
        }

        await manager.submitToken(Data([0xde, 0xad, 0xbe, 0xef]))
    }

    nonisolated private static func profileBytes(environment: String) -> Data {
        Data(
            """
            prefix<plist version="1.0"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>\(environment)</string></dict></dict></plist>suffix
            """.utf8
        )
    }
}

@MainActor
private final class ManagerBox {
    var manager: PushNotificationManager?
}

private final class PushManagerURLProtocol: URLProtocol, @unchecked Sendable {
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
        request.url?.host == "127.0.0.1"
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
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
