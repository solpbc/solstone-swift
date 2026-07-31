// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

// integration-gate HTTP streaming must not use URLSession's byte reader.
final class IntegrationGateStreamingGrepTests: XCTestCase {
    func testGateSourceListIsNonEmpty() throws {
        XCTAssertFalse(try Self.gateSourceFiles().isEmpty)
    }

    func testGateSourcesDoNotUseURLSessionByteReader() throws {
        let hits = try Self.sourceHits(under: "Sources/IntegrationGate")

        XCTAssertTrue(hits.isEmpty, Self.describe(hits))
    }

    func testStreamingScannerDiscriminatesOffendingAndBenignFixtures() {
        let fixtures: [(String, String, [String])] = [
            (
                "session bytes call",
                """
                let stream = session.bytes(request)
                """,
                ["session.bytes("]
            ),
            (
                "member bytes call",
                """
                let stream = try await client.bytes(for: request)
                """,
                [".bytes(for:"]
            ),
            (
                "byte loop",
                """
                for try await byte in bytes {
                    sink(byte)
                }
                """,
                ["for try await byte in"]
            ),
            (
                "chunk stream",
                """
                for try await chunk in stream {
                    sink(chunk)
                }
                """,
                []
            ),
            (
                "data task",
                """
                let payload = try await session.data(for: request)
                """,
                []
            ),
            (
                "line comment",
                """
                // let stream = try await session.bytes(for: request)
                """,
                []
            ),
        ]

        for (name, source, expectedTokens) in fixtures {
            let hits = Self.sourceHits(in: source, relativePath: "\(name).swift")
            XCTAssertEqual(hits.map(\.token), expectedTokens, name)
        }
    }

    private static let forbiddenTokens = [
        "session.bytes(",
        ".bytes(for:",
        "for try await byte in",
    ]

    private static func gateSourceFiles() throws -> [URL] {
        let root = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/IntegrationGate", isDirectory: true)
        return try StringLiteralGrepSupport.swiftFiles(under: root)
    }

    private static func sourceHits(under relativePath: String) throws -> [SourceHit] {
        let worktree = StringLiteralGrepSupport.worktreeRoot()
        let root = worktree.appendingPathComponent(relativePath, isDirectory: true)
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)
        XCTAssertFalse(files.isEmpty)
        return try files.flatMap { file -> [SourceHit] in
            let text = try String(contentsOf: file, encoding: .utf8)
            return self.sourceHits(
                in: text,
                relativePath: self.relativePath(for: file, under: worktree)
            )
        }
    }

    private static func sourceHits(in text: String, relativePath: String) -> [SourceHit] {
        var hits: [SourceHit] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated() {
            let code = Self.codeBeforeLineComment(in: line)
            for token in Self.forbiddenTokens where code.contains(token) {
                hits.append(SourceHit(relativePath: relativePath, lineNumber: offset + 1, token: token))
            }
        }
        return hits
    }

    private static func codeBeforeLineComment(in line: String) -> Substring {
        guard let comment = line.range(of: "//") else { return line[...] }
        return line[..<comment.lowerBound]
    }

    private static func relativePath(for file: URL, under worktree: URL) -> String {
        let root = worktree.path
        let path = file.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private static func describe(_ hits: [SourceHit]) -> String {
        hits.map { "\($0.relativePath):\($0.lineNumber): \($0.token)" }.joined(separator: ", ")
    }

    private struct SourceHit {
        let relativePath: String
        let lineNumber: Int
        let token: String
    }
}
