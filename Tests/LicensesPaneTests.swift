// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class LicensesPaneTests: XCTestCase {
    // Falsified by dropping the file from the app's resources: nothing else would notice, and an
    // owner would open an empty pane.
    func testTheAppCarriesTheNoticesFileOnce() throws {
        let copies = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        XCTAssertEqual(copies.map(\.lastPathComponent).filter { $0 == "THIRD_PARTY_NOTICES.md" }.count, 1)
        XCTAssertFalse(LicensesText.load().isEmpty)
    }

    // Falsified by a section with no text behind it, or by swift-crypto's NOTICE.txt going missing.
    func testTheFileNamesEverySectionAndCarriesTheUpstreamNotice() {
        let text = LicensesText.load()
        for section in ["## swift-crypto", "## Comfortaa", "## Argon2", "## Lucide", "## EFF"] {
            XCTAssertTrue(text.contains(section), section)
        }
        XCTAssertTrue(text.contains("The SwiftCrypto Project"))
    }

    func testHeadingMarkersAndDividersBecomeStructure() {
        XCTAssertEqual(
            LicensesText.blocks(of: "# one\n\nbody a\nbody b\n\n---\n\n### three\n#not a heading\n----\n"),
            [
                .heading(level: 1, "one"),
                .text("body a\nbody b"),
                .divider,
                .heading(level: 3, "three"),
                .text("#not a heading\n----"),
            ]
        )
    }

    // Falsified by reading CRLF lines as one long line: the upstream font licence ends its lines
    // that way, so its blank lines would stop separating anything and a --- would go unseen.
    func testCRLFLinesAreLinesToo() {
        XCTAssertEqual(
            LicensesText.blocks(of: "a\r\nb\r\n\r\n---\r\nc\r\n"),
            [.text("a\nb"), .divider, .text("c")]
        )
    }

    // Falsified by the pane dropping or reflowing a line: every line that isn't a marker or blank
    // comes through, in order and unchanged.
    func testThePaneShowsTheWholeFile() {
        let text = LicensesText.load()
        var fileLines: [String] = []
        text.enumerateLines { line, _ in
            if !line.allSatisfy(\.isWhitespace), line != "---" { fileLines.append(line) }
        }
        let shown: [String] = LicensesText.blocks(of: text).flatMap { block -> [String] in
            switch block {
            case .heading(let level, let heading): [String(repeating: "#", count: level) + " " + heading]
            case .divider: []
            case .text(let run): run.components(separatedBy: "\n")
            }
        }
        XCTAssertEqual(shown, fileLines)
        XCTAssertGreaterThan(fileLines.count, 500)
    }
}
