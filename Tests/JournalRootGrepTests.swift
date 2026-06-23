// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class JournalRootGrepTests: XCTestCase {
    func testSourcesDoNotUseRetiredJournalRoutesOrProgressClient() throws {
        let root = Self.worktreeRoot()
        let scanRoots = [
            root.appendingPathComponent("Sources"),
            root.appendingPathComponent("SolstoneShareExtension"),
        ]
        let files = try scanRoots.flatMap { try Self.swiftFiles(under: $0) }

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                for forbidden in Self.forbiddenSubstrings where lineText.contains(forbidden) {
                    XCTFail("retired journal route/progress token \(forbidden) at \(file.path):\(index + 1): \(lineText)")
                }
            }
        }
    }

    private static let forbiddenSubstrings = [
        "progress-today",
        "progressToday",
        "/app/home/",
    ]

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }
}
