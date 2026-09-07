// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
import SPLTunnel
@testable import solstone_swift

final class JournalVersionMetadataTests: XCTestCase {
    @MainActor
    func testRefreshRecoveryFailureAndOfflineRestore() async throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = JournalVersionMetadata(defaults: defaults) { port in
            switch port {
            case 1: return "2.0.0"
            case 2: return "2.0.1"
            default: return nil
            }
        }
        owner.setIdentity("journal-a")
        await owner.connected(localPort: 1)?.value
        XCTAssertEqual(owner.version, "2.0.0")
        XCTAssertTrue(owner.isCurrent)
        owner.disconnected()
        XCTAssertFalse(owner.isCurrent)
        await owner.connected(localPort: 2)?.value
        XCTAssertEqual(owner.version, "2.0.1")
        XCTAssertTrue(owner.isCurrent)
        owner.disconnected()
        await owner.connected(localPort: 3)?.value
        XCTAssertEqual(owner.version, "2.0.1")
        XCTAssertFalse(owner.isCurrent)
        let restored = JournalVersionMetadata(defaults: defaults)
        restored.setIdentity("journal-a")
        XCTAssertEqual(restored.version, "2.0.1")
        XCTAssertFalse(restored.isCurrent)
        restored.setIdentity("journal-b")
        XCTAssertNil(restored.version)
        XCTAssertNil(sanitizedJournalVersion("2.0\n"))
        XCTAssertNil(sanitizedJournalVersion("  "))
    }

    @MainActor
    func testObsoleteCompletionCannotOverwriteReconnectOrSameIdentityPairing() async throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (results, continuation) = AsyncStream<String>.makeStream()
        let owner = JournalVersionMetadata(defaults: defaults) { port in
            if port == 2 { return "2.0.2" }
            for await result in results { return result }
            return nil
        }
        owner.setIdentity("journal-a")
        let old = owner.connected(localPort: 1)
        owner.disconnected()
        await owner.connected(localPort: 2)?.value
        continuation.yield("2.0.0")
        continuation.finish()
        await old?.value
        XCTAssertEqual(owner.version, "2.0.2")
        XCTAssertTrue(owner.isCurrent)
        owner.clear()
        owner.setIdentity("journal-a")
        XCTAssertNil(owner.version)
        XCTAssertFalse(owner.isCurrent)
        await owner.connected(localPort: 2)?.value
        XCTAssertEqual(owner.version, "2.0.2")
        XCTAssertTrue(owner.isCurrent)
    }

    @MainActor
    func testSamePortConnectedResamples() async throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        final class AtomicCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var _val = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                _val += 1
                return _val
            }
            var val: Int {
                lock.lock()
                defer { lock.unlock() }
                return _val
            }
        }
        let counter = AtomicCounter()
        let owner = JournalVersionMetadata(defaults: defaults) { _ in
            let c = counter.next()
            return "2.0.\(c)"
        }
        owner.setIdentity("journal-a")

        await owner.connected(localPort: 7071)?.value
        XCTAssertEqual(counter.val, 1)
        XCTAssertEqual(owner.version, "2.0.1")

        await owner.connected(localPort: 7071)?.value
        XCTAssertEqual(counter.val, 2)
        XCTAssertEqual(owner.version, "2.0.2")
    }

    func testIdentityV2FingerprintDifference() {
        let pairingA = StoredPairing(
            instanceID: "inst-1",
            homeLabel: "Home",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "ca-fingerprint-1",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY_A",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date()
        )
        let pairingB = StoredPairing(
            instanceID: "inst-1",
            homeLabel: "Home",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "ca-fingerprint-1",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY_A",
            caChainPEM: CertlessTrustFixtures.wrongCAPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date()
        )
        let pairingC = StoredPairing(
            instanceID: "inst-1",
            homeLabel: "Home",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "ca-fingerprint-1",
            clientCertPEM: CertlessTrustFixtures.caPEM, // different cert as client cert
            clientKeyPEM: "KEY_A",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date()
        )

        let idA = journalVersionMetadataIdentity(for: pairingA)
        let idB = journalVersionMetadataIdentity(for: pairingB)
        let idC = journalVersionMetadataIdentity(for: pairingC)

        XCTAssertNotNil(idA)
        XCTAssertNotNil(idB)
        XCTAssertNotNil(idC)
        XCTAssertNotEqual(idA, idB)
        XCTAssertNotEqual(idA, idC)
        XCTAssertNotEqual(idB, idC)
    }

    @MainActor
    func testLateApplyValidatedAfterDisconnectedDoesNotMarkCurrent() throws {
        let suiteName = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let owner = JournalVersionMetadata(defaults: defaults) { _ in nil }
        owner.setIdentity("identity-1")

        _ = owner.connected(localPort: 7071)
        owner.disconnected()

        owner.applyValidated(name: "Late Journal", version: "2.5.0")
        XCTAssertFalse(owner.isCurrent)
    }

    @MainActor
    func testApplyValidatedNameAndVersionPersistence() throws {
        let suiteName = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let owner = JournalVersionMetadata(defaults: defaults) { _ in nil }
        owner.setIdentity("identity-1")
        _ = owner.connected(localPort: 7071)

        owner.applyValidated(name: "My Journal", version: "1.5.0")
        XCTAssertEqual(owner.name, "My Journal")
        XCTAssertEqual(owner.version, "1.5.0")
        XCTAssertTrue(owner.isCurrent)

        // Restore in fresh instance
        let restored = JournalVersionMetadata(defaults: defaults) { _ in nil }
        restored.setIdentity("identity-1")
        XCTAssertEqual(restored.name, "My Journal")
        XCTAssertEqual(restored.version, "1.5.0")
        XCTAssertFalse(restored.isCurrent)
    }

    func testSanitizedJournalName() {
        XCTAssertEqual(sanitizedJournalName("  Home Journal  "), "Home Journal")
        XCTAssertNil(sanitizedJournalName("   "))
        XCTAssertNil(sanitizedJournalName(nil))
        XCTAssertNil(sanitizedJournalName("Bad\nName"))
        XCTAssertNil(sanitizedJournalName("Bad\u{0000}Name"))

        let exact80 = String(repeating: "a", count: 80)
        XCTAssertEqual(sanitizedJournalName(exact80), exact80)

        let over80 = String(repeating: "a", count: 81)
        XCTAssertNil(sanitizedJournalName(over80))
    }
}

@MainActor
final class WatchJournalVersionTests: XCTestCase {
    func testReplayOrderingAndFreshnessAcrossReachabilityAndRestart() throws {
        let name = "WatchJournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = WatchJournalVersionState(defaults: defaults)
        let nonce = state.beginReachableSession()
        func data(_ revision: Int, _ version: String?, _ responseNonce: String?, identity: String? = "a") throws -> Data {
            try JSONEncoder().encode(WatchJournalVersionPayload(revision: revision, identity: identity,
                                      version: version, current: true, nonce: responseNonce))
        }
        let current = try data(2, "2.0.1", nonce)
        state.receive(current, live: false)
        XCTAssertEqual(state.version, "2.0.1")
        XCTAssertFalse(state.isCurrent)
        state.receive(current, live: true)
        XCTAssertTrue(state.isCurrent)
        state.disconnected()
        state.receive(current, live: true)
        XCTAssertFalse(state.isCurrent)
        let restarted = WatchJournalVersionState(defaults: defaults)
        XCTAssertEqual(restarted.version, "2.0.1")
        XCTAssertFalse(restarted.isCurrent)
        restarted.receive(try data(1, "2.0.0", nil), live: false)
        XCTAssertEqual(restarted.version, "2.0.1")
        restarted.receive(try data(3, nil, nil, identity: nil), live: false)
        XCTAssertNil(restarted.version)
        restarted.receive(current, live: true)
        XCTAssertNil(restarted.version)
    }
}
