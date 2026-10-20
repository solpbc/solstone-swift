// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

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
}
