// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
import Foundation
@testable import solstone_swift

/// Existing copy assertions inspect the source with native no-argument catalog calls resolved.
nonisolated enum StringCatalogTestSource {
    static func read(_ url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"AppStrings\.(\w+)\(\)"#)
        let ns = source as NSString
        let result = NSMutableString(string: source)
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "_", with: ".")
            let key = "m" + id.utf8.map { String(format: "%02x", $0) }.joined()
            let value = AppStrings.bundle.localizedString(forKey: key, value: key, table: "Localizable")
            guard value != key else { continue }
            let encoded = try JSONEncoder().encode(value)
            result.replaceCharacters(in: match.range, with: String(decoding: encoded, as: UTF8.self))
        }
        return result as String
    }
}
