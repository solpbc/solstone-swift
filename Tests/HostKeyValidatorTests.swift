// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import NIOCore
import NIOSSH
import NIOTransportServices
import XCTest
@testable import solstone_swift

final class HostKeyValidatorTests: XCTestCase {
    private var group: NIOTSEventLoopGroup!
    private var eventLoop: (any EventLoop)!
    private var mock: MockKeyManager!

    override func setUp() {
        self.group = NIOTSEventLoopGroup(loopCount: 1)
        self.eventLoop = self.group.next()
        self.mock = MockKeyManager()
    }

    override func tearDown() {
        try! self.group.syncShutdownGracefully()
    }

    func testFirstConnection_SavesAndAccepts() throws {
        self.mock.hostKey = nil
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let validator = HostKeyValidator(keyManager: self.mock, onMismatch: { _ in })
        let promise = self.eventLoop.makePromise(of: Void.self)

        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)

        try promise.futureResult.wait()
        XCTAssertTrue(self.mock.saveHostKeyCalled)
        XCTAssertEqual(self.mock.hostKey, key)
    }

    func testKnownHost_MatchingKey_Accepts() throws {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        self.mock.hostKey = key
        let validator = HostKeyValidator(keyManager: self.mock, onMismatch: { _ in })
        let promise = self.eventLoop.makePromise(of: Void.self)

        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)

        try promise.futureResult.wait()
        XCTAssertFalse(self.mock.saveHostKeyCalled)
    }

    func testKnownHost_MismatchedKey_Rejects() {
        let storedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let presentedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        self.mock.hostKey = storedKey
        var mismatchKey: NIOSSHPublicKey?
        let validator = HostKeyValidator(keyManager: self.mock) { key in
            mismatchKey = key
        }
        let promise = self.eventLoop.makePromise(of: Void.self)

        validator.validateHostKey(hostKey: presentedKey, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertTrue(error is HostKeyError)
        }
        XCTAssertEqual(mismatchKey, presentedKey)
    }

    func testKeychainError_Propagates() {
        self.mock.shouldThrow = true
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let validator = HostKeyValidator(keyManager: self.mock, onMismatch: { _ in })
        let promise = self.eventLoop.makePromise(of: Void.self)

        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            if case KeychainError.unexpectedStatus(let status) = error {
                XCTAssertEqual(status, -1)
            } else {
                XCTFail("Expected KeychainError.unexpectedStatus, got \(error)")
            }
        }
    }
}
