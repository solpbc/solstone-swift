// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UniformTypeIdentifiers

/// Where an imported item came from, when the app knows. It rides the item's note as
/// `origin_app`, shows on this device as `from Photos`, and names the door the journal records.
nonisolated enum ShareImportOrigin {
    /// A photo chosen in the system photo picker or brought in from the photo library.
    static let photos = "Photos"

    /// The journal's `imported_via` for an item: `mobile_photos` for anything from Photos,
    /// `mobile_share` for everything else that comes through import or the share sheet.
    static func importedVia(originApp: String?) -> String {
        originApp == Self.photos ? "mobile_photos" : "mobile_share"
    }

    /// What the journal calls a photo: its own name, with the extension its bytes are sent under.
    /// The journal routes on that extension, reads the name from a quoted multipart header and
    /// keeps it as a file on its own disk, and refuses one over 128 bytes. Everything else that
    /// comes through import keeps the fixed name `standIn`.
    static func requestFilename(originApp: String?, ownName: String?, standIn: String) -> String {
        guard originApp == Self.photos, let ownName else { return standIn }
        let name = ownName as NSString
        // A picked photo's name can have no extension, and `12.34.56` doesn't end in one.
        let hasImageExtension = UTType(filenameExtension: name.pathExtension)?.conforms(to: .image) == true
        let base = hasImageExtension ? name.deletingPathExtension : ownName
        let safe = String(String.UnicodeScalarView(base.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || "\"\\/:*?<>|".unicodeScalars.contains(scalar) ? "_" : scalar
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "." + (standIn as NSString).pathExtension
        var kept = ""
        for character in safe {
            guard kept.utf8.count + character.utf8.count + suffix.utf8.count <= self.maxRequestFilenameBytes else { break }
            kept.append(character)
        }
        return kept.isEmpty ? standIn : kept + suffix
    }

    private static let maxRequestFilenameBytes = 128
}
