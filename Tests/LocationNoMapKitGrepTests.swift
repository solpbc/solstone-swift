// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class LocationNoMapKitGrepTests: XCTestCase {
    func testSourcesDoNotImportMapKit() throws {
        let root = Self.worktreeRoot().appendingPathComponent("Sources")
        let files = try Self.swiftFiles(under: root)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                if lineText.range(of: #"^\s*import\s+MapKit\b"#, options: .regularExpression) != nil {
                    XCTFail("MapKit import at \(file.path):\(index + 1): \(lineText)")
                }
            }
        }
    }

    func testSourcesDoNotUseNativeMapOrLiveDotTokens() throws {
        let root = Self.worktreeRoot().appendingPathComponent("Sources")
        let files = try Self.swiftFiles(under: root)
        let bannedTokens = [
            "_MapKit_SwiftUI",
            "Map(",
            "MKMapView",
            "Marker(",
            "UserAnnotation",
            "MapUserLocationButton",
        ]

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                for token in bannedTokens where lineText.contains(token) {
                    XCTFail("native map/live-dot token \(token) at \(file.path):\(index + 1): \(lineText)")
                }
            }
        }
    }

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
