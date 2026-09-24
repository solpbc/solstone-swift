// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ClearPairingSourceScanGrepTests: XCTestCase {
    struct ClearCall: Equatable {
        let file: String
        let line: Int
        let enclosingFunction: String
    }

    private static let allowedEntries: Set<String> = [
        "Sources/Push/OwnerUnpair.swift:ownerUnpair",
        "Sources/Services/PairingCredentialStore.swift:clearPairing",
        "Sources/Services/PairingCredentialStore.swift:revokeIfCurrentGeneration",
        "Sources/Services/PairingCredentialStore.swift:publishClearedPairing",
        "Sources/Services/AppConfig.swift:init",
        "Sources/Services/AppConfig.swift:clearPairing",
        "Sources/Pairing/PairFlowCoordinator.swift:unpair",
        "Sources/ContentView.swift:body",
        "Sources/SolstoneSwiftApp.swift:resetOnboardingIntegrationState",
    ]

    static func findClearPairingCalls(in contents: String, relativePath: String) -> [ClearCall] {
        var calls: [ClearCall] = []
        let lines = contents.components(separatedBy: .newlines)
        var braceDepth = 0
        var parenDepth = 0
        var pendingFunction: String? = nil
        var functionStack: [(name: String, depth: Int)] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }

            if let funcRange = trimmed.range(of: "func ") {
                let after = trimmed[funcRange.upperBound...]
                let funcName = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !funcName.isEmpty {
                    pendingFunction = String(funcName)
                }
            } else if trimmed.contains("init(") || trimmed.hasPrefix("init ") || trimmed.hasPrefix("convenience init") {
                pendingFunction = "init"
            } else if trimmed.contains("var body:") || trimmed.contains("var body :") {
                pendingFunction = "body"
            }

            if trimmed.contains(".clearPairing()") {
                let currentFunction = functionStack.last?.name ?? pendingFunction ?? "<top-level>"
                calls.append(ClearCall(file: relativePath, line: index + 1, enclosingFunction: currentFunction))
            }

            for char in line {
                if char == "(" {
                    parenDepth += 1
                } else if char == ")" {
                    parenDepth = max(0, parenDepth - 1)
                } else if char == "{" {
                    braceDepth += 1
                    if parenDepth == 0, let fn = pendingFunction {
                        functionStack.append((name: fn, depth: braceDepth))
                        pendingFunction = nil
                    }
                } else if char == "}" {
                    if let last = functionStack.last, braceDepth == last.depth {
                        functionStack.removeLast()
                    }
                    braceDepth -= 1
                }
            }
        }
        return calls
    }

    func testOwnerUnpairIsSingleEntryForUserInitiatedUnpair() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let sourcesURL = root.appendingPathComponent("Sources", isDirectory: true)
        let files = try StringLiteralGrepSupport.swiftFiles(under: sourcesURL)

        var violations: [String] = []

        for file in files {
            let relativePath = String(file.path.dropFirst(root.path.count + 1))
            let contents = try String(contentsOf: file, encoding: .utf8)
            let calls = Self.findClearPairingCalls(in: contents, relativePath: relativePath)

            for call in calls {
                let key = "\(call.file):\(call.enclosingFunction)"
                if !Self.allowedEntries.contains(key) {
                    violations.append("\(call.file):\(call.line) in \(call.enclosingFunction)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Disallowed .clearPairing() calls: \(violations.joined(separator: "\n"))"
        )
    }

    func testFailingFixtureTriggersViolation() {
        let failingFixture = """
        func unauthorizedClear() {
            config.clearPairing()
        }
        """

        let calls = Self.findClearPairingCalls(in: failingFixture, relativePath: "Sources/Home/Unauthorized.swift")
        XCTAssertEqual(calls.count, 1)
        let call = calls[0]
        XCTAssertEqual(call.enclosingFunction, "unauthorizedClear")
        let key = "\(call.file):\(call.enclosingFunction)"
        XCTAssertFalse(Self.allowedEntries.contains(key), "Expected unauthorized fixture to be flagged as violation")
    }
}
