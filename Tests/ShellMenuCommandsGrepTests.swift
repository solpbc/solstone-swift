// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class ShellMenuCommandsGrepTests: XCTestCase {
    func testSidebarCommandsDoesNotAppearInSources() throws {
        for file in try self.sourceFiles() {
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(contents.contains("SidebarCommands"), file.path)
        }
    }

    func testKeyboardShortcutsCarryCommandAndNeverControl() throws {
        let calls = try self.sourceFiles().flatMap { file in
            try Self.keyboardShortcutCalls(in: String(contentsOf: file, encoding: .utf8))
        }
        XCTAssertFalse(calls.isEmpty)

        for call in calls {
            XCTAssertTrue(Self.keyboardShortcutUsesOnlyCommand(call), call)
        }
    }

    func testKeyboardShortcutModifierClassifierRejectsNonCommandModifiers() throws {
        let samples: [(source: String, expected: Bool)] = [
            (".keyboardShortcut(\"1\")", true),
            (".keyboardShortcut(\"1\", modifiers: .command)", true),
            (".keyboardShortcut(\"1\", modifiers: [.command, .option])", false),
            (".keyboardShortcut(\"1\", modifiers: .control)", false),
            (".keyboardShortcut(\"1\", modifiers: [.command, .control])", false),
            (
                """
                .keyboardShortcut(
                    "1",
                    modifiers: [
                        .command,
                        .option,
                    ]
                )
                """,
                false
            ),
        ]

        for sample in samples {
            let calls = try Self.keyboardShortcutCalls(in: sample.source)
            XCTAssertEqual(calls.count, 1, sample.source)
            XCTAssertEqual(
                Self.keyboardShortcutUsesOnlyCommand(calls[0]),
                sample.expected,
                sample.source
            )
        }
    }

    func testShellNavModelIsConstructedExactlyOnceInSources() throws {
        let pattern = try NSRegularExpression(pattern: #"\bShellNavModel\s*\("#)
        let count = try self.sourceFiles().reduce(0) { partialResult, file in
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)
            return partialResult + pattern.numberOfMatches(in: contents, range: range)
        }
        XCTAssertEqual(count, 1)
    }

    private func sourceFiles() throws -> [URL] {
        try StringLiteralGrepSupport.swiftFiles(
            under: StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources")
        )
    }

    private static func keyboardShortcutCalls(in source: String) throws -> [String] {
        let marker = ".keyboardShortcut("
        var calls: [String] = []
        var searchStart = source.startIndex

        while let range = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1
            var index = range.upperBound
            let argumentsStart = index

            while index < source.endIndex, depth > 0 {
                let character = source[index]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                index = source.index(after: index)
            }

            guard depth == 0 else {
                throw NSError(
                    domain: "ShellMenuCommandsGrepTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "unbalanced keyboardShortcut call"]
                )
            }

            calls.append(String(source[argumentsStart..<source.index(before: index)]))
            searchStart = index
        }

        return calls
    }

    private static func hasTopLevelComma(in arguments: String) -> Bool {
        var depth = 0
        for character in arguments {
            switch character {
            case "(":
                depth += 1
            case ")":
                depth -= 1
            case "," where depth == 0:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func keyboardShortcutUsesOnlyCommand(_ arguments: String) -> Bool {
        let collapsed = arguments.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        guard Self.hasTopLevelComma(in: collapsed) else {
            return true
        }
        guard let modifiersRange = collapsed.range(of: "modifiers:") else {
            return false
        }

        let modifiers = collapsed[modifiersRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return modifiers == ".command" || modifiers == "[.command]"
    }
}
