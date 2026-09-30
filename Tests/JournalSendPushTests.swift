// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class JournalSendPushTests: XCTestCase {
    private var defaults: UserDefaults!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let suite = "JournalSendPushTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushManagerURLProtocol.self]
        self.session = URLSession(configuration: config)
        PushManagerURLProtocol.callCount = 0
        PushManagerURLProtocol.handler = { (request: URLRequest) -> (HTTPURLResponse, Data) in
            let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8474/push")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
    }

    override func tearDown() {
        self.defaults = nil
        self.session = nil
        super.tearDown()
    }

    @MainActor
    func testPushRegistrationBlockedWhenUnconfirmed() async {
        self.defaults.set(true, forKey: "push.ownerEnabled")
        let isAllowed = OSAllocatedUnfairLock(initialState: false)
        let manager = PushNotificationManager(
            journalSendAllowed: { isAllowed.withLock { $0 } },
            defaults: self.defaults,
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

        await manager.submitToken(Data([0x12, 0x34]))

        await manager.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)

        // Now allow and kick
        isAllowed.withLock { $0 = true }
        await manager.kickAfterConfirmation()
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)
    }

    @MainActor
    func testPushUnregistrationBlockedWhenUnconfirmed() async {
        let recordedMethods = OSAllocatedUnfairLock<[String]>(initialState: [])
        PushManagerURLProtocol.handler = { (request: URLRequest) -> (HTTPURLResponse, Data) in
            if let method = request.httpMethod {
                recordedMethods.withLock { $0.append(method) }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let isAllowed = OSAllocatedUnfairLock(initialState: false)
        let manager = PushNotificationManager(
            journalSendAllowed: { isAllowed.withLock { $0 } },
            defaults: self.defaults,
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

        self.defaults.set(false, forKey: "push.ownerEnabled")
        self.defaults.set("deadbeef", forKey: "push.lastRegisteredToken")

        await manager.handleTunnelConnected(localPort: 8474)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)
        XCTAssertEqual(recordedMethods.withLock { $0 }, [])

        // Now confirm and kick
        isAllowed.withLock { $0 = true }
        await manager.kickAfterConfirmation()
        XCTAssertEqual(PushManagerURLProtocol.callCount, 1)
        XCTAssertEqual(recordedMethods.withLock { $0 }, ["DELETE"])
    }

    @MainActor
    func testSendTestNotificationBlockedWhenUnconfirmed() async throws {
        let isAllowed = OSAllocatedUnfairLock(initialState: false)
        let manager = PushNotificationManager(
            journalSendAllowed: { isAllowed.withLock { $0 } },
            defaults: self.defaults,
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

        self.defaults.set(true, forKey: "push.ownerEnabled")
        manager.activeLocalPort = 8474

        let sent = try await manager.sendTestNotification()
        XCTAssertFalse(sent)
        XCTAssertEqual(PushManagerURLProtocol.callCount, 0)
    }
}
