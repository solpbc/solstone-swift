// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchTargetMembershipTests: XCTestCase {
    private static let expectedExcludedFiles = [
        "WatchSegmentDrain.swift",
        "WatchRelayReceiver.swift",
        "WatchSegmentLedger.swift",
        "WatchPhoneSessionHistoryStore.swift",
        "WatchPipelineReducer.swift",
        "PhoneWatchSourceStateMapping.swift",
        "WatchSourceFacts.swift",
        "WatchSteadyVerdictReducer.swift",
        "WatchSourceDetailPresentation.swift",
    ]

    func testWatchTargetsExcludePhoneOnlySources() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)
        let watchAppBlock = try XCTUnwrap(Self.targetBlock(named: "SolstoneWatch", in: projectYML))
        let watchExcludes = try Self.watchCaptureExcludes(in: watchAppBlock)

        for file in Self.expectedExcludedFiles {
            XCTAssertTrue(
                watchExcludes.contains(file),
                "SolstoneWatch Sources/WatchCapture excludes must contain \(file)"
            )
        }

        if let watchTestsBlock = Self.targetBlock(named: "SolstoneWatchTests", in: projectYML),
           let watchTestsExcludes = try? Self.watchCaptureExcludes(in: watchTestsBlock) {
            for file in Self.expectedExcludedFiles {
                XCTAssertTrue(
                    watchTestsExcludes.contains(file),
                    "SolstoneWatchTests Sources/WatchCapture excludes must contain \(file)"
                )
            }
        }
    }

    private static func projectYMLURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
    }

    private static func targetBlock(named name: String, in projectYML: String) -> String? {
        guard let targetsRange = projectYML.range(of: "\ntargets:\n") else { return nil }
        let targetsSection = projectYML[targetsRange.upperBound...]
        guard let start = targetsSection.range(of: "  \(name):") else { return nil }
        let remainder = targetsSection[start.upperBound...]
        if let nextTargetMatch = remainder.range(of: #"\n  [A-Za-z0-9_-]+:"#, options: .regularExpression) {
            return String(targetsSection[start.lowerBound..<remainder.index(before: nextTargetMatch.lowerBound)])
        }
        return String(targetsSection[start.lowerBound...])
    }

    private static func watchCaptureExcludes(in targetBlock: String) throws -> [String] {
        guard let capturePathRange = targetBlock.range(of: "path: Sources/WatchCapture") else {
            return []
        }
        let afterCapture = targetBlock[capturePathRange.upperBound...]
        guard let excludesRange = afterCapture.range(of: "excludes:") else {
            return []
        }
        let afterExcludes = afterCapture[excludesRange.upperBound...]
        let lines = afterExcludes.components(separatedBy: .newlines)
        var excludes: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let filename = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                excludes.append(filename)
            } else if !trimmed.isEmpty {
                break
            }
        }
        return excludes
    }
}
