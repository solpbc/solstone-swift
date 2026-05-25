// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PushEnablementKeychainTests: XCTestCase {
    private var keychain: PushEnablementKeychain!

    nonisolated override func setUp() {
        super.setUp()
        self.keychain = PushEnablementKeychain(
            serviceOverride: "app.solstone.swift.push.tests.\(UUID().uuidString)"
        )
        try? self.keychain.delete()
    }

    nonisolated override func tearDown() {
        try? self.keychain.delete()
        self.keychain = nil
        super.tearDown()
    }

    func testSaveThenLoadRoundTripsRecord() throws {
        let credential = Self.credential(deviceId: "device-1")
        try self.keychain.save(credential)
        XCTAssertEqual(try self.keychain.load(), credential)
    }

    func testSaveTwiceUpdatesRecord() throws {
        try self.keychain.save(Self.credential(deviceId: "device-1"))
        let latest = Self.credential(deviceId: "device-2")
        try self.keychain.save(latest)
        XCTAssertEqual(try self.keychain.load(), latest)
    }

    func testDeleteRemovesRecord() throws {
        try self.keychain.save(Self.credential(deviceId: "device-1"))
        try self.keychain.delete()
        XCTAssertNil(try self.keychain.load())
    }

    private static func credential(deviceId: String) -> EnabledPushRecord {
        EnabledPushRecord(
            accountId: "account-1",
            deviceId: deviceId,
            dispatchToken: "dispatch-1",
            createdAt: "2026-05-24T00:00:00Z"
        )
    }
}
