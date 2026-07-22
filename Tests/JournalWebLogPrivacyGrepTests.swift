// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class JournalWebLogPrivacyGrepTests: XCTestCase {
    func testJournalWebLogsDoNotInterpolateURLPartsOrJournalText() throws {
        let root = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources/Portal")
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)
        let forbiddenExpressionFragments = [
            "url",
            "request",
            "path",
            "query",
            "fragment",
            "absolutestring",
        ]
        var inspectedCallCount = 0

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                guard lineText.contains("journalWebLog.") else { continue }
                inspectedCallCount += 1

                _ = try StringLiteralGrepSupport.stringLiterals(in: lineText)
                for expression in self.interpolationExpressions(in: lineText) {
                    let normalized = expression.lowercased()
                    for fragment in forbiddenExpressionFragments where normalized.contains(fragment) {
                        XCTFail("journalWebLog interpolation contains \(fragment) at \(file.path):\(index + 1): \(lineText)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(inspectedCallCount, 0)
    }

    private func interpolationExpressions(in line: String) -> [String] {
        var expressions: [String] = []
        var searchStart = line.startIndex

        while let interpolationStart = line[searchStart...].range(of: #"\("#)?.upperBound {
            guard let privacyStart = line[interpolationStart...].range(of: ", privacy:")?.lowerBound else {
                break
            }
            expressions.append(String(line[interpolationStart..<privacyStart]))
            searchStart = privacyStart
        }

        return expressions
    }
}
