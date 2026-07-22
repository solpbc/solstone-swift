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
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            self.assertNoUnexpectedLoggerInstantiation(in: lines, file: file)

            for call in self.journalWebLogCalls(in: lines) {
                inspectedCallCount += 1

                _ = try StringLiteralGrepSupport.stringLiterals(in: call.text)
                for expression in self.interpolationExpressions(in: call.text) {
                    XCTAssertTrue(
                        expression.contains("privacy: .public"),
                        "journalWebLog interpolation lacks privacy: .public at \(file.path):\(call.lineNumber): \(call.text)"
                    )
                    let valueExpression = self.valueExpression(in: expression)
                    for fragment in forbiddenExpressionFragments where self.containsForbiddenFragment(fragment, in: valueExpression) {
                        XCTFail("journalWebLog interpolation contains \(fragment) at \(file.path):\(call.lineNumber): \(call.text)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(inspectedCallCount, 0)
    }

    private func assertNoUnexpectedLoggerInstantiation(in lines: [String], file: URL) {
        for (index, lineText) in lines.enumerated() {
            guard lineText.contains("Logger("),
                  !lineText.contains("journalWebLog = Logger(")
            else {
                continue
            }
            XCTFail("unexpected Logger instantiation at \(file.path):\(index + 1): \(lineText)")
        }
    }

    private func journalWebLogCalls(in lines: [String]) -> [(lineNumber: Int, text: String)] {
        var calls: [(lineNumber: Int, text: String)] = []
        var index = 0

        while index < lines.count {
            let lineText = lines[index]
            guard lineText.contains("journalWebLog.") else {
                index += 1
                continue
            }

            let lineNumber = index + 1
            var callText = lineText
            var balance = self.parenthesisBalance(in: lineText)

            while balance > 0, index + 1 < lines.count {
                index += 1
                let continuation = lines[index]
                callText += "\n" + continuation
                balance += self.parenthesisBalance(in: continuation)
            }

            calls.append((lineNumber: lineNumber, text: callText))
            index += 1
        }

        return calls
    }

    private func parenthesisBalance(in text: String) -> Int {
        text.reduce(into: 0) { balance, character in
            if character == "(" {
                balance += 1
            } else if character == ")" {
                balance -= 1
            }
        }
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
