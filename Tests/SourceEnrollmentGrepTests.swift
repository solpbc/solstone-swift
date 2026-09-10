// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SourceEnrollmentGrepTests: XCTestCase {
    func testRetiredPersistEnrolledIfActiveDoesNotAppearUnderSources() throws {
        let root = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources", isDirectory: true)
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)

        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("persistEnrolledIfActive") {
                hits.append(file.lastPathComponent)
            }
        }

        XCTAssertEqual(hits, [])
    }

    func testAudioEnrollmentWrittenInStartSessionAndNotUpdateElapsed() throws {
        let text = try Self.sourceText("Sources/Observer/ObserverManager.swift")

        let startSessionBody = try Self.slice(
            in: text,
            from: "func startSession(mode: ObserverMode) async -> ObserverStartOutcome {",
            to: "func stopSession() async -> ObserverStopOutcome {"
        )
        let updateElapsedBody = try Self.slice(
            in: text,
            from: "func updateElapsed() {",
            to: "func handleMeter("
        )

        XCTAssertTrue(startSessionBody.contains("AudioStorageKey.enrolled"))
        XCTAssertFalse(updateElapsedBody.contains("AudioStorageKey.enrolled"))
    }

    func testScreencastActiveStateAssignmentsHavePersistEnrolled() throws {
        let text = try Self.sourceText("Sources/Screencast/ScreencastManager.swift")
        let lines = text.components(separatedBy: .newlines)

        var activeLineIndices: [Int] = []
        for (index, line) in lines.enumerated() {
            if line.contains("self.state = .active") {
                activeLineIndices.append(index)
            }
        }

        XCTAssertEqual(activeLineIndices.count, 4, "Expected exactly 4 active state assignments in ScreencastManager.swift")

        for index in activeLineIndices {
            let precedingWindow = lines[max(0, index - 5)..<index]
            let precedingNonEmpty = precedingWindow.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let hasPersistEnrolled = precedingNonEmpty.contains { $0.contains("self.persistEnrolled()") }
            XCTAssertTrue(
                hasPersistEnrolled,
                "Expected self.persistEnrolled() in lines immediately preceding active assignment at line \(index + 1)"
            )
        }
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func slice(in text: String, from startMarker: String, to endMarker: String) throws -> String {
        guard let startRange = text.range(of: startMarker),
              let endRange = text.range(of: endMarker, range: startRange.upperBound..<text.endIndex)
        else {
            throw SliceError(message: "Could not slice from \(startMarker) to \(endMarker)")
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }
}

private struct SliceError: Error {
    let message: String
}
