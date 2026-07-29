// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

// criterion 4: relay-only gate sources do not mutate pairing or endpoint cache.
final class IntegrationGateRelayOnlyGrepTests: XCTestCase {
    func testGateSourcesDoNotMutateKeychainOrEndpointCache() throws {
        let text = try Self.gateSourceText()
        for forbidden in [
            "keychainStore.save",
            "keychainStore.delete",
            "SPLRuntime.keychainStore.save",
            "SPLRuntime.keychainStore.delete",
            "EndpointCache.wipe",
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    private static func gateSourceText() throws -> String {
        let root = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/IntegrationGate", isDirectory: true)
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)
        XCTAssertFalse(files.isEmpty)
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}
