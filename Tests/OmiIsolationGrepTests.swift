// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OmiIsolationGrepTests: XCTestCase {
    func testOmiSourcesDoNotUseNetworkAnalyticsOrAudioSessionSymbols() throws {
        let root = Self.worktreeRoot().appendingPathComponent("Sources/Omi")
        let files = try Self.swiftFiles(under: root)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in Self.forbiddenSymbols where text.contains(forbidden) {
                XCTFail("forbidden omi symbol \(forbidden) in \(file.path)")
            }
        }
    }

    private static let forbiddenSymbols = [
        "URLSession",
        "AVAudioSession",
        ".setActive",
        "Analytics",
        "Telemetry",
        "Crashlytics",
        "FirebaseCrashlytics",
        "Sentry",
        "Datadog"
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
