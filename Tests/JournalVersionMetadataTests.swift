// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
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
