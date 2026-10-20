// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// What iOS lets the app read of the photo library.
nonisolated enum PhotoLibraryAccess: Equatable, Sendable {
    case notAsked
    case all
    /// Only the photos the owner picked for the app in iOS.
    case selected
    case off
    /// Restricted on this device, for example by Screen Time.
    case unavailable

    var canRead: Bool {
        self == .all || self == .selected
    }
}

/// The album half of an import's scope.
nonisolated struct PhotoLibraryAlbum: Hashable, Codable, Sendable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable {
        case all
        case favorites
        case screenshots
        case album
    }

    let kind: Kind
    /// The album's PhotoKit identifier; `nil` for the three built-in choices.
    let collectionID: String?
    /// The owner's own name for an album; `nil` for the built-in choices.
    let title: String?

    var id: String {
        self.collectionID ?? self.kind.rawValue
    }

    static let all = PhotoLibraryAlbum(kind: .all, collectionID: nil, title: nil)
    static let favorites = PhotoLibraryAlbum(kind: .favorites, collectionID: nil, title: nil)
    static let screenshots = PhotoLibraryAlbum(kind: .screenshots, collectionID: nil, title: nil)

    static func album(collectionID: String, title: String) -> PhotoLibraryAlbum {
        PhotoLibraryAlbum(kind: .album, collectionID: collectionID, title: title)
    }
}

/// What the owner chose before anything comes in: one album and a range of days, photos only.
nonisolated struct PhotoLibraryScope: Codable, Equatable, Sendable {
    let album: PhotoLibraryAlbum
    /// The first day, from its start.
    let from: Date
    /// The last day, to its end.
    let to: Date

    /// Whole days in `calendar`, so a range always covers the days the owner picked, end to end.
    static func days(album: PhotoLibraryAlbum, from: Date, to: Date, calendar: Calendar = .current) -> PhotoLibraryScope {
        let first = calendar.startOfDay(for: min(from, to))
        let lastStart = calendar.startOfDay(for: max(from, to))
        let last = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: lastStart) ?? lastStart
        return PhotoLibraryScope(album: album, from: first, to: last)
    }
}

nonisolated enum PhotoLibraryBatchState: String, Codable, Sendable {
    case running
    /// The owner paused it.
    case paused
    /// Photo access went away; it carries on when access is back.
    case pausedForAccess
    /// This device ran out of room; it carries on when the owner resumes.
    case pausedForSpace
    case stopped
    case finished

    var isEnded: Bool {
        self == .stopped || self == .finished
    }

    var isPaused: Bool {
        self == .paused || self == .pausedForAccess || self == .pausedForSpace
    }
}

/// One import from the library. The photo list is frozen when the owner starts it, so what
/// comes in is exactly the count they saw, and a photo taken meanwhile is never added.
nonisolated struct PhotoLibraryBatch: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let scope: PhotoLibraryScope
    let assetIDs: [String]
    /// Index of the next photo to bring in.
    var next: Int
    /// Each photo brought in, by asset identifier, to the import item that carries it.
    var itemIDs: [String: String]
    /// Photos the library could not hand over (gone, or no longer shared with the app).
    var unreadable: [String]
    var state: PhotoLibraryBatchState
    let startedAt: Date
    var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case scope
        case assetIDs = "asset_ids"
        case next
        case itemIDs = "item_ids"
        case unreadable
        case state
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    var remaining: Int {
        max(0, self.assetIDs.count - self.next)
    }

    var broughtIn: Int {
        self.itemIDs.count
    }
}

/// How many photos a scope holds right now, before the owner starts.
nonisolated struct PhotoLibraryPreview: Equatable, Sendable {
    /// New to this device's imports.
    let assetIDs: [String]
    /// Already brought in from this device before, so left out.
    let alreadyIn: Int
}
