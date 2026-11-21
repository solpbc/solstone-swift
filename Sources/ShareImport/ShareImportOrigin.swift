// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UniformTypeIdentifiers

/// Where an imported item came from, when the app knows. It rides the item's note as
/// `origin_app`, shows on this device as `from Photos`, and names the door the journal records.
nonisolated enum ShareImportOrigin {
    /// A photo chosen in the system photo picker or brought in from the photo library.
    static let photos = "Photos"

    /// The journal's `imported_via` for every item this app sends, so the journal's import
    /// history names the app it came from. A journal that predates the name shows no origin.
    static let importedVia = "ios"

    /// What the journal calls an item: its own name, as the owner sees it in history. The journal
    /// routes on the extension, reads the name from a quoted multipart header and keeps it as a
    /// file on its own disk, and refuses one over 128 bytes. A photo takes the extension its bytes
    /// are sent under; any other file keeps its own, because the journal decides what a file is.
    /// An item with no name, or a file whose name has no extension, takes the fixed `standIn`.
    static func requestFilename(originApp: String?, ownName: String?, standIn: String) -> String {
        guard let ownName else { return standIn }
        let ownExtension = (ownName as NSString).pathExtension
        if originApp != Self.photos {
            guard !ownExtension.isEmpty else { return standIn }
            return self.fitted(base: (ownName as NSString).deletingPathExtension, suffix: "." + ownExtension, standIn: standIn)
        }
        let name = ownName as NSString
        // A picked photo's name can have no extension, and `12.34.56` doesn't end in one.
        let hasImageExtension = UTType(filenameExtension: name.pathExtension)?.conforms(to: .image) == true
        let base = hasImageExtension ? name.deletingPathExtension : ownName
        return self.fitted(base: base, suffix: "." + (standIn as NSString).pathExtension, standIn: standIn)
    }

    private static func fitted(base: String, suffix: String, standIn: String) -> String {
        let safe = String(String.UnicodeScalarView(base.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || "\"\\/:*?<>|".unicodeScalars.contains(scalar) ? "_" : scalar
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(String.UnicodeScalarView(suffix.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || "\"\\/:*?<>|".unicodeScalars.contains(scalar) ? "_" : scalar
        }))
        var kept = ""
        for character in safe {
            guard kept.utf8.count + character.utf8.count + suffix.utf8.count <= self.maxRequestFilenameBytes else { break }
            kept.append(character)
        }
        return kept.isEmpty ? standIn : kept + suffix
    }

    private static let maxRequestFilenameBytes = 128
}
