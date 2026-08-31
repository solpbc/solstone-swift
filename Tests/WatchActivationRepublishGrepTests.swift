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
        XCTAssertTrue(activation.contains("if didActivate {"))
        XCTAssertTrue(activation.contains("await self.relaySender?.requestDrain(trigger: .connectivityActivation)"))
        XCTAssertTrue(activation.contains("self.onReachableRepublish?()"))
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
        XCTAssertTrue(reachability.contains("await self.relaySender?.requestDrain(trigger: .connectivityReachability)"))
        XCTAssertTrue(reachability.contains("self.onReachableRepublish?()"))
    }

    func testWatchPipelineInputAssemblerThreadsReachabilityIntoDiagnosticsInput() throws {
        let (assemblerText, assemblerPath) = try Self.contents("Sources/WatchCapture/WatchPipelineInputAssembler.swift")
        let pipelineInput = try Self.section(
            from: "let input = WatchPipelineInput(",
            to: "        )",
            in: assemblerText,
            path: assemblerPath.path
        )

        // WatchSourceDetailView no longer builds row presentation, so there is no
        // detail-view reachability assertion here; the reducer-side presence line
        // is allowed to read reachability under the pipeline-input isolation guard.
        XCTAssertTrue(pipelineInput.contains("isReachable: self.watchLink.isReachable"))
    }

    func testSourcesViewWatchSourceDoesNotThreadReachabilityIntoPresentation() throws {
        let (text, path) = try Self.contents("Sources/Home/SourceModelBuilder.swift")
        let watchSource = try Self.section(
            from: "nonisolated func watchSourceModel(",
            to: "// watchSourceModel-end",
            in: text,
            path: path.path
        )
        let presentationCall = try Self.section(
            from: "let presentation = phoneWatchSourcePresentation(lane: lane)",
            to: "    return Source(",
            in: watchSource,
            path: path.path
        )

        XCTAssertFalse(presentationCall.contains("isReachable"))
        XCTAssertFalse(presentationCall.contains("isJournalPaired"))
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
