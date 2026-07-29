// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

// criterion 9: integration-gate secret and emission hygiene.
nonisolated final class IntegrationGateHygieneGrepTests: XCTestCase {
    func testGateSourceListIsNonEmpty() throws {
        XCTAssertFalse(try Self.gateSourceFiles().isEmpty)
    }

    func testGateEmittedStringLiteralsDoNotExposeSecretsBodiesOrRawURLs() throws {
        let forbiddenLiteralSubstrings = [
            "SYNTHETIC_GATE_NONCE_V1",
            "SYNTHETIC_GATE_INSTANCE_ID_V1",
            "SYNTHETIC_GATE_PAIRING_FINGERPRINT_SHA256_V1",
            "SYNTHETIC_GATE_CONTENT_SHA256_V1",
            "BEGIN ",
            "PRIVATE KEY",
            "CERTIFICATE",
            "device token",
            "response body",
            "raw body",
            "http://127.0.0.1",
        ]
        for file in try Self.gateSourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let sanitized = try StringLiteralGrepSupport.removingStructuralLiterals(from: line)
                for literal in try StringLiteralGrepSupport.stringLiterals(in: sanitized) {
                    for forbidden in forbiddenLiteralSubstrings {
                        XCTAssertFalse(literal.contains(forbidden), "\(file.lastPathComponent): \(literal)")
                    }
                }
            }
        }
    }

    func testResultAndLogPathsNeverNamePEMDeviceTokenOrResponseBodySymbols() throws {
        let inspectedFiles = [
            "Sources/IntegrationGate/IntegrationGateResult.swift",
            "Sources/IntegrationGate/IntegrationGateDriver.swift",
            "Sources/IntegrationGate/IntegrationGateFileStore.swift",
            "Sources/IntegrationGate/IntegrationGateHTTPClient.swift",
            "Sources/IntegrationGate/IntegrationGateActions.swift",
            "Sources/IntegrationGate/IntegrationGateSampler.swift",
        ]
        for relativePath in inspectedFiles {
            let text = try Self.sourceText(relativePath)
            XCTAssertFalse(text.contains("clientCertPEM"), relativePath)
            XCTAssertFalse(text.contains("clientKeyPEM"), relativePath)
            XCTAssertFalse(text.contains("caChainPEM"), relativePath)
            XCTAssertFalse(text.contains("deviceToken"), relativePath)
            XCTAssertFalse(text.contains("responseBody"), relativePath)
            XCTAssertFalse(text.contains("rawBody"), relativePath)
        }
    }

    private static func gateSourceFiles() throws -> [URL] {
        let root = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/IntegrationGate", isDirectory: true)
        return try StringLiteralGrepSupport.swiftFiles(under: root)
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
