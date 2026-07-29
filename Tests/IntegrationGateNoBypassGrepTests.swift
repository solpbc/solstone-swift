// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

// criterion 2: no parallel bypass path in gate sources.
final class IntegrationGateNoBypassGrepTests: XCTestCase {
    func testGateSourcesDoNotUseBypassAPIs() throws {
        let text = try Self.gateSourceText()
        for forbidden in [
            "forceConnected",
            "forceDisconnectedForUITest",
            "forceNetworkStatus",
            "--integration-test",
            "--integration-test-live",
            "--ui-test",
            "openStream",
            "MuxStreamOpening",
            "keychainStore.save",
            ".delete",
            "EndpointCache.wipe",
            "LoopbackProxy(",
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
