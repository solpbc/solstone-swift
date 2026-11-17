// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
import Foundation
import XCTest
@testable import solstone_swift

nonisolated final class PushLocalizationMatchingTests: XCTestCase {
    func testRegionalPreferenceUsesNativeMatchingAndPreservesExactEnglish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "test.push.localization", "CFBundleDevelopmentRegion": "en-US", "CFBundleLocalizations": ["en-US", "es-419"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        let key = CatalogSelect.resolveKey(messageId: "push.proof.new", enumArg: nil)
        for (locale, value) in [("en-US", "English fixture"), ("es-419", "Latin American fixture")] {
            let folder = root.appendingPathComponent(locale + ".lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [key: value], format: .binary, options: 0).write(to: folder.appendingPathComponent("PushMessages.strings"))
        }
        let bundle = try XCTUnwrap(Bundle(url: root))
        let entry: [String: Any] = ["v": 1, "catalog_epoch": 1, "code": "push.proof.new", "args": [String: String](), "fallback_en": "Fallback fixture"]
        XCTAssertEqual(PushPresentation.render(entry: entry, legacy: "legacy", locale: Locale(identifier: "es_MX"), bundle: bundle), "Latin American fixture")
        XCTAssertEqual(PushPresentation.render(entry: entry, legacy: "legacy", locale: Locale(identifier: "en_US"), bundle: bundle), "English fixture")
        let exactRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: root, to: exactRoot)
        defer { try? FileManager.default.removeItem(at: exactRoot) }
        let exact = exactRoot.appendingPathComponent("es-MX.lproj")
        try FileManager.default.createDirectory(at: exact, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [key: "Exact Mexican fixture"], format: .binary, options: 0).write(to: exact.appendingPathComponent("PushMessages.strings"))
        XCTAssertEqual(PushPresentation.render(entry: entry, legacy: "legacy", locale: Locale(identifier: "es-MX"), bundle: try XCTUnwrap(Bundle(url: exactRoot))), "Exact Mexican fixture")
    }
}
