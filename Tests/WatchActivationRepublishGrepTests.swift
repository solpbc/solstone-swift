// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchActivationRepublishGrepTests: XCTestCase {
    func testActivationSuccessRefiresReachableRepublish() throws {
        let (text, path) = try Self.contents("Watch/Sources/WatchSessionModel.swift")
        let activation = try Self.section(
            from: "func handleActivationChanged(_ didActivate: Bool) {",
            to: "    func handleReachabilityChanged(_ isReachable: Bool) {",
            in: text,
            path: path.path
        )
        let didActivateBranch = try Self.section(
            from: "if didActivate {",
            to: "        }\n",
            in: activation,
            path: path.path
        )

        XCTAssertTrue(didActivateBranch.contains("self.relaySender?.drain()"))
        XCTAssertTrue(didActivateBranch.contains("self.onReachableRepublish?()"))
    }

    func testReachabilityChangeStillRefiresReachableRepublish() throws {
        let (text, path) = try Self.contents("Watch/Sources/WatchSessionModel.swift")
        let reachability = try Self.section(
            from: "func handleReachabilityChanged(_ isReachable: Bool) {",
            to: "\n    }\n}",
            in: text,
            path: path.path
        )

        XCTAssertTrue(reachability.contains("if isReachable {"))
        XCTAssertTrue(reachability.contains("self.relaySender?.drain()"))
        XCTAssertTrue(reachability.contains("self.onReachableRepublish?()"))
    }

    func testWatchSourceDetailThreadsReachability() throws {
        let (text, path) = try Self.contents("Sources/WatchCapture/WatchSourceDetailView.swift")
        let pipelineInput = try Self.section(
            from: "var pipelineInput: WatchPipelineInput {",
            to: "    // KILL-LIST-EXEMPT:END",
            in: text,
            path: path.path
        )
        let presentation = try Self.section(
            from: "var watchPresentation: PhoneWatchSourcePresentation {",
            to: "    var summary: WatchPipelineSummary {",
            in: text,
            path: path.path
        )

        XCTAssertTrue(pipelineInput.contains("isReachable: self.watchLink.isReachable"))
        XCTAssertTrue(presentation.contains("isReachable: input.isReachable"))
    }

    func testSourcesViewWatchSourceThreadsReachability() throws {
        let (text, path) = try Self.contents("Sources/SourcesView.swift")
        let watchSource = try Self.section(
            from: "var watchSource: Source {",
            to: "    func refreshNowPeriodically() async {",
            in: text,
            path: path.path
        )
        let presentationCall = try Self.section(
            from: "let presentation = phoneWatchSourcePresentation(",
            to: "        )",
            in: watchSource,
            path: path.path
        )

        XCTAssertTrue(presentationCall.contains("isReachable: self.watchLink.isReachable"))
        XCTAssertTrue(presentationCall.contains("isJournalPaired: self.appConfig.isPaired"))
    }

    private static func contents(_ relativePath: String) throws -> (String, URL) {
        let path = self.worktreeRoot().appendingPathComponent(relativePath)
        return (try String(contentsOf: path, encoding: .utf8), path)
    }

    private static func section(from start: String, to end: String, in text: String, path: String) throws -> String {
        guard let startRange = text.range(of: start) else {
            throw GrepFailure.missing(start, path)
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            throw GrepFailure.missing(end, path)
        }
        return String(text[startRange.lowerBound..<endRange.upperBound])
    }

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum GrepFailure: Error, CustomStringConvertible {
    case missing(String, String)

    var description: String {
        switch self {
        case let .missing(needle, path):
            return "missing \(needle) in \(path)"
        }
    }
}
