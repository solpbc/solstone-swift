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
            "host",
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
                    XCTAssertTrue(
                        expression.contains("privacy: .public"),
                        "journalWebLog interpolation lacks privacy: .public at \(file.path):\(index + 1): \(lineText)"
                    )
                    let valueExpression = self.valueExpression(in: expression)
                    for fragment in forbiddenExpressionFragments where self.containsForbiddenFragment(fragment, in: valueExpression) {
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
            var cursor = interpolationStart
            var depth = 1
            var interpolationEnd: String.Index?

            while cursor < line.endIndex {
                let character = line[cursor]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        interpolationEnd = cursor
                        break
                    }
                }
                cursor = line.index(after: cursor)
            }

            guard let interpolationEnd else {
                break
            }
            expressions.append(String(line[interpolationStart..<interpolationEnd]))
            searchStart = line.index(after: interpolationEnd)
        }

        return expressions
    }

    private func valueExpression(in interpolation: String) -> String {
        let expression = interpolation.lowercased()
        guard let privacyRange = expression.range(of: ", privacy:") else {
            return expression
        }
        return String(expression[..<privacyRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsForbiddenFragment(_ fragment: String, in expression: String) -> Bool {
        if fragment == "host", expression == "hostportmatch" {
            return false
        }
        return expression.contains(fragment)
    }
}
