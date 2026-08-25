// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchHomeLuminanceSourceTests: XCTestCase {
    func testReducedLuminanceUsesRootModifiersWithoutChangingWatchHomeStructure() throws {
        let source = try Self.watchHomeSource()
        let body = try XCTUnwrap(source.slice(
            from: "    var body: some View {",
            to: "\n}\n\nprivate extension WatchHomeView"
        ))
        let scrollViewRange = try XCTUnwrap(body.bracedBlock(after: "ScrollView {"))
        let scrollView = String(body[scrollViewRange])
        let rootModifierChain = String(body[scrollViewRange.upperBound...])

        XCTAssertTrue(source.contains("@Environment(\\.isLuminanceReduced) private var isLuminanceReduced"))
        XCTAssertTrue(scrollView.contains("self.statusHeader(face)"))
        XCTAssertTrue(scrollView.contains("ForEach(face.detailRows, id: \\.label)"))
        XCTAssertFalse(scrollView.contains("isLuminanceReduced"))
        XCTAssertTrue(rootModifierChain.hasPrefix("""

        .background(Color.black)
        .opacity(self.isLuminanceReduced ? 0.82 : 1)
        .saturation(self.isLuminanceReduced ? 0.45 : 1)
"""))

        XCTAssertEqual(
            source.structuralBranches,
            [
                "if let trustLine = face.trustLine {",
                "if self.captureModel.isRunning {",
                "if face.showsElapsed, let start = self.captureModel.presentation.sessionStartedAt {",
                "if let handoff = face.compactHandoff {",
                "if let subtext = handoff.subtext {",
                "if markVariant == .activeDimmed {",
                "switch markVariant {",
                "switch role {",
                "if face.showsElapsed, let start = self.captureModel.presentation.sessionStartedAt {",
                "if let handoff = face.compactHandoff {",
                "if let subtext = handoff.subtext {",
            ]
        )
    }

    func testReducedLuminanceRetainsExistingActiveAndDimmedMarkDistinction() throws {
        let source = try Self.watchHomeSource()

        XCTAssertTrue(source.contains("self.markView(face.markVariant)"))
        XCTAssertTrue(source.contains("if markVariant == .activeDimmed"))
        XCTAssertTrue(source.contains("image\n                .opacity(0.32)\n                .grayscale(0.55)"))
    }

    private static func watchHomeSource() throws -> String {
        try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent("Watch/Sources/WatchHomeView.swift"),
            encoding: .utf8
        )
    }

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = self.range(of: start), let endRange = self.range(of: end, range: startRange.upperBound..<self.endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }

    func bracedBlock(after marker: String) -> Range<String.Index>? {
        guard let markerRange = self.range(of: marker),
              let openingBrace = self[markerRange].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = openingBrace
        while index < self.endIndex {
            switch self[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return markerRange.lowerBound..<self.index(after: index)
                }
            default:
                break
            }
            index = self.index(after: index)
        }
        return nil
    }

    var structuralBranches: [String] {
        self
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.hasPrefix("if ") || line.hasPrefix("switch ")
            }
    }
}
