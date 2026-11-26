// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Wire-compatible album membership entry sent during metadata-only scan.
nonisolated struct PhotosAlbumRef: Codable, Equatable, Sendable {
    let id: String
    /// `"user"` or `"smart"`.
    let kind: String
    let subtype: Int
    let title: String?
}

/// Wire-compatible smart-album catalog entry sent at scan start.
nonisolated struct PhotosSmartAlbumEntry: Codable, Equatable, Sendable {
    let id: String
    let subtype: Int
    let title: String?
    let count: Int
}

/// Camera GPS coordinates from PhotoKit metadata (never pixel bytes).
nonisolated struct PhotosAssetLocation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double?
    let altitude: Double?
}

/// Extended optional asset metadata (never pixel bytes).
nonisolated struct PhotosAssetExtended: Codable, Equatable, Sendable {
    let caption: String?
    let keywords: [String]
    let rating: Double?
    let uti: String?
    let originalFilename: String?
}

/// One metadata-only scanned library asset row. Never carries pixel bytes.
/// Hidden assets are excluded before row construction.
nonisolated struct PhotosScanAssetRow: Codable, Equatable, Sendable {
    let id: String
    let cloudId: String?
    let capturedAt: String?
    let modifiedAt: String?
    let mediaType: String
    let width: Int?
    let height: Int?
    let duration: Double?
    let favorite: Bool
    let hidden: Bool
    let edited: Bool
    let screenshot: Bool
    let livePhoto: Bool
    let panorama: Bool
    let hdr: Bool
    let depth: Bool
    let burstIdentifier: String?
    let representsBurst: Bool
    let burstSelection: UInt
    let location: PhotosAssetLocation?
    let albums: [PhotosAlbumRef]
    let extended: PhotosAssetExtended?
}

/// Summary returned after completing a full metadata-only scan.
nonisolated struct PhotosFullScanSummary: Equatable, Sendable {
    let totalItems: Int
    let earliestItemAt: String?
    let changeToken: Data?
}

/// Result of querying incremental `PHPersistentChangeToken` metadata deltas.
nonisolated enum PhotosMetadataChanges: Equatable, Sendable {
    case delta(addedOrUpdated: [PhotosScanAssetRow], removedIDs: [String], token: Data?)
    case expired
}

/// Result of exporting a reduced 512 px JPEG copy for one wanted asset.
nonisolated enum PhotosCopyExportResult: Equatable, Sendable {
    case jpeg(Data)
    case gone
    case icloudWaiting
    case failed
}

/// One wanted photo item leased from `/app/devices/photos-library/wanted`.
nonisolated struct PhotosWantedItem: Codable, Equatable, Sendable {
    let assetID: String
    let cloudID: String?
    let maxEdge: Int
    let capturedAt: String?
    let reasonKind: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case cloudID = "cloud_id"
        case maxEdge = "max_edge"
        case capturedAt = "captured_at"
        case reasonKind = "reason_kind"
    }
}

/// Response from `GET /app/devices/photos-library/wanted`.
nonisolated struct PhotosWantedResponse: Codable, Equatable, Sendable {
    let paused: Bool
    let range: String?
    let wanted: [PhotosWantedItem]
    let remaining: Int
}

/// Request body for `POST /app/devices/photos-library/scan/start`.
nonisolated struct PhotosScanStartPayload: Encodable, Sendable {
    let deviceName: String
    let deviceKind: String
    let accessState: String
    let totalItems: Int
    let smartAlbums: [PhotosSmartAlbumEntry]

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case deviceKind = "device_kind"
        case accessState = "access_state"
        case totalItems = "total_items"
        case smartAlbums = "smart_albums"
    }
}

/// Request body for `POST /app/devices/photos-library/scan/batch`.
nonisolated struct PhotosScanBatchPayload: Encodable, Sendable {
    let batchIndex: Int
    let rows: [PhotosScanAssetRow]
    let itemsChecked: Int

    enum CodingKeys: String, CodingKey {
        case batchIndex = "batch_index"
        case rows
        case itemsChecked = "items_checked"
    }
}

/// Request body for `POST /app/devices/photos-library/scan/finish`.
nonisolated struct PhotosScanFinishPayload: Encodable, Sendable {
    let itemsChecked: Int
    let earliestItemAt: String?
    let accessState: String
    let icloudWaitingCount: Int

    enum CodingKeys: String, CodingKey {
        case itemsChecked = "items_checked"
        case earliestItemAt = "earliest_item_at"
        case accessState = "access_state"
        case icloudWaitingCount = "icloud_waiting_count"
    }
}

/// Request body for `POST /app/devices/photos-library/scan/changes`.
nonisolated struct PhotosScanChangesPayload: Encodable, Sendable {
    let addedOrUpdated: [PhotosScanAssetRow]
    let removedIDs: [String]
    let smartAlbums: [PhotosSmartAlbumEntry]?
    let accessState: String
    let icloudWaitingCount: Int

    enum CodingKeys: String, CodingKey {
        case addedOrUpdated = "added_or_updated"
        case removedIDs = "removed_ids"
        case smartAlbums = "smart_albums"
        case accessState = "access_state"
        case icloudWaitingCount = "icloud_waiting_count"
    }
}

/// Request body for `POST /app/devices/photos-library/status`.
nonisolated struct PhotosDeviceStatusPayload: Encodable, Sendable {
    let deviceName: String
    let deviceKind: String
    let accessState: String
    let icloudWaitingCount: Int
    let scanPaused: Bool

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case deviceKind = "device_kind"
        case accessState = "access_state"
        case icloudWaitingCount = "icloud_waiting_count"
        case scanPaused = "scan_paused"
    }
}

/// Request body for `POST /app/devices/photos-library/copy`.
nonisolated struct PhotosCopyUploadPayload: Encodable, Sendable {
    let assetID: String
    let cloudID: String?
    /// `"ok"`, `"gone"`, or `"icloud_waiting"`.
    let status: String
    let jpegBase64: String?

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case cloudID = "cloud_id"
        case status
        case jpegBase64 = "jpeg_base64"
    }
}

/// Capability and source wire constants for the Photos Library source.
nonisolated enum PhotosLibraryWire {
    static let sourceKey = "photos"
    static let capability = "photos_library"
    static let scanBatchSize = 250
    static let wantedBatchLimit = 20
    static let copyMaxEdge = 512
    static let copyJpegQuality: CGFloat = 0.85

    static func accessString(_ access: ScreenshotsAccess) -> String {
        switch access {
        case .full: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        }
    }
}
