// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class AppGroupMirrorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "AppGroupMirrorTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    func testDefaultsAreUnpaired() {
        let mirror = AppGroupMirror(defaults: self.defaults)

        XCTAssertEqual(mirror.pairingSnapshot(), AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false))
    }

    func testPairingWriteReadAndClear() {
        let mirror = AppGroupMirror(defaults: self.defaults)

        mirror.writePairing(journalName: "sol")
        XCTAssertEqual(mirror.pairingSnapshot(), AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true))

        mirror.clearPairing()
        XCTAssertEqual(mirror.pairingSnapshot(), AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false))
    }

    func testNilDefaultsNoOpReads() {
        let mirror = AppGroupMirror(defaults: nil)

        mirror.writePairing(journalName: "sol")

        XCTAssertEqual(mirror.pairingSnapshot(), AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false))
    }
}
