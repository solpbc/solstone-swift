// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Photos
import UIKit

/// Testable PhotoKit boundary for the Photos Library source, implemented directly
/// on `ScreenshotsPhotoKit` so Screenshots and Photos share one `PHPhotoLibrary`
/// access check, change observer, and off-main execution model.
nonisolated protocol PhotosLibraryMediaAccess: Sendable {
    func photosAccess() -> ScreenshotsAccess
    func requestPhotosAccess() async -> ScreenshotsAccess
    func fetchSmartAlbumCatalog() async throws -> [PhotosSmartAlbumEntry]
    func scanAllVisibleMetadata(
        batchSize: Int,
        onBatch: @escaping @Sendable (Int, [PhotosScanAssetRow], Int) async throws -> Void
    ) async throws -> PhotosFullScanSummary
    func fetchMetadataChanges(since token: Data?) async -> PhotosMetadataChanges
    func currentPhotosChangeToken() async -> Data?
    func exportPhotoCopy(localIdentifier: String, maxEdge: Int, allowNetwork: Bool) async -> PhotosCopyExportResult
    func setPhotosLibraryObserving(_ on: Bool)
    func addPhotosLibraryOnChange(_ listener: @escaping @Sendable () -> Void)
}

nonisolated enum PhotosLibraryPhotoKitError: Error {
    case fullAccessRequired
}

extension ScreenshotsPhotoKit: PhotosLibraryMediaAccess {
    func photosAccess() -> ScreenshotsAccess {
        self.access()
    }

    func requestPhotosAccess() async -> ScreenshotsAccess {
        await self.requestAccess()
    }

    func currentPhotosChangeToken() async -> Data? {
        await self.currentTokenAsync()
    }

    /// Fetch options that strictly exclude hidden assets and include burst/cloud-shared
    /// metadata without reading any pixel bytes.
    static func photosMetadataFetchOptions(extended: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.wantsIncrementalChangeDetails = false
        #if compiler(>=6.2)
        if #available(iOS 27, *) {
            options.prefetchAssetExtendedMetadata = extended
        }
        #endif
        return options
    }

    func fetchSmartAlbumCatalog() async throws -> [PhotosSmartAlbumEntry] {
        try await Self.runOffMainThrowing {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw PhotosLibraryPhotoKitError.fullAccessRequired
            }
            return Self.collectSmartAlbumCatalog()
        }
    }

    /// Metadata-only scan of all visible library assets. Never touches pixels and
    /// never reads hidden assets or the Hidden smart album.
    func scanAllVisibleMetadata(
        batchSize: Int,
        onBatch: @escaping @Sendable (Int, [PhotosScanAssetRow], Int) async throws -> Void
    ) async throws -> PhotosFullScanSummary {
        let (rows, earliest, token): ([PhotosScanAssetRow], String?, Data?) = try await Self.runOffMainThrowing {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw PhotosLibraryPhotoKitError.fullAccessRequired
            }
            let tokenBefore = Self.archivePhotosToken(self.library.currentChangeToken)
            let fetched = PHAsset.fetchAssets(with: Self.photosMetadataFetchOptions(extended: true))
            var visibleAssets: [PHAsset] = []
            visibleAssets.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in
                if !asset.isHidden {
                    visibleAssets.append(asset)
                }
            }
            visibleAssets.sort { $0.localIdentifier < $1.localIdentifier }
            let visibleIDs = Set(visibleAssets.map(\.localIdentifier))
            let memberships = Self.collectAlbumMemberships(visibleIDs: visibleIDs)
            let cloudIDs = self.resolveCloudIdentifiers(for: visibleAssets.map(\.localIdentifier))

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var rows: [PhotosScanAssetRow] = []
            rows.reserveCapacity(visibleAssets.count)
            var earliest: String?
            for asset in visibleAssets {
                guard !asset.isHidden else { continue }
                let id = asset.localIdentifier
                let row = Self.makeMetadataRow(
                    asset,
                    cloudID: cloudIDs[id],
                    albums: memberships[id] ?? [],
                    formatter: formatter
                )
                if let cap = row.capturedAt, earliest == nil || cap < earliest! {
                    earliest = cap
                }
                rows.append(row)
            }
            return (rows, earliest, tokenBefore)
        }

        let effectiveBatch = max(1, batchSize)
        var batchIndex = 0
        var offset = 0
        while offset < rows.count {
            let end = min(offset + effectiveBatch, rows.count)
            let slice = Array(rows[offset..<end])
            try await onBatch(batchIndex, slice, end)
            batchIndex += 1
            offset = end
        }
        return PhotosFullScanSummary(
            totalItems: rows.count,
            earliestItemAt: earliest,
            changeToken: token
        )
    }

    func fetchMetadataChanges(since token: Data?) async -> PhotosMetadataChanges {
        let delta = await self.changes(since: token)
        switch delta {
        case .expired:
            return .expired
        case .delta(let inserted, let updated, let deleted, let nextToken):
            let changedIDs = Array(Set(inserted + updated)).sorted()
            if changedIDs.isEmpty {
                return .delta(addedOrUpdated: [], removedIDs: deleted, token: nextToken)
            }
            let (rows, extraDeleted): ([PhotosScanAssetRow], [String]) = await Self.runOffMain {
                let fetched = PHAsset.fetchAssets(
                    withLocalIdentifiers: changedIDs,
                    options: Self.photosMetadataFetchOptions(extended: true)
                )
                var visibleAssets: [PHAsset] = []
                var hiddenOrGone = Set(changedIDs)
                fetched.enumerateObjects { asset, _, _ in
                    if !asset.isHidden {
                        visibleAssets.append(asset)
                        hiddenOrGone.remove(asset.localIdentifier)
                    }
                }
                let visibleIDs = Set(visibleAssets.map(\.localIdentifier))
                let memberships = Self.collectAlbumMemberships(visibleIDs: visibleIDs)
                let cloudIDs = self.resolveCloudIdentifiers(for: visibleAssets.map(\.localIdentifier))
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                let rows = visibleAssets.map { asset in
                    Self.makeMetadataRow(
                        asset,
                        cloudID: cloudIDs[asset.localIdentifier],
                        albums: memberships[asset.localIdentifier] ?? [],
                        formatter: formatter
                    )
                }
                return (rows, Array(hiddenOrGone))
            }
            let allDeleted = Array(Set(deleted + extraDeleted)).sorted()
            return .delta(addedOrUpdated: rows, removedIDs: allDeleted, token: nextToken)
        }
    }

    /// Export one upright reduced JPEG copy (default 512 px max edge) for a wanted
    /// visible photo. Never reads hidden assets. Reports `.gone` if removed or hidden,
    /// and `.icloudWaiting` when `allowNetwork == false` and pixels live in iCloud.
    func exportPhotoCopy(
        localIdentifier: String,
        maxEdge: Int,
        allowNetwork: Bool
    ) async -> PhotosCopyExportResult {
        await Task.detached(priority: .utility) {
            guard Self.isVisibleNonScreenshotPhoto(localIdentifier) else {
                return .gone
            }
            let fetched = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier],
                options: Self.photosMetadataFetchOptions()
            )
            guard let asset = fetched.firstObject,
                  !asset.isHidden,
                  asset.mediaType == .image,
                  !asset.mediaSubtypes.contains(.photoScreenshot) else {
                return .gone
            }
            let edge = max(64, min(maxEdge, 1024))
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = allowNetwork
            options.version = .current

            let targetSize = CGSize(width: edge, height: edge)
            let (image, inCloud): (UIImage?, Bool) = await withCheckedContinuation { continuation in
                let gate = CopyContinuationGate()
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { @Sendable image, info in
                    if info?[PHImageResultIsDegradedKey] as? Bool == true {
                        return
                    }
                    let cloud = info?[PHImageResultIsInCloudKey] as? Bool == true
                    gate.finish(with: (image, cloud), continuation: continuation)
                }
            }
            // Re-check visibility after image export in case the asset was hidden or deleted
            // while iCloud or PhotoKit was preparing the copy.
            guard Self.isVisibleNonScreenshotPhoto(localIdentifier) else {
                return .gone
            }
            if let image {
                if let jpeg = Self.encodeUprightJPEG(
                    image,
                    maxEdge: edge,
                    quality: PhotosLibraryWire.copyJpegQuality
                ) {
                    return .jpeg(jpeg)
                }
                return .failed
            }
            return inCloud ? .icloudWaiting : .failed
        }.value
    }

    private static func isVisibleNonScreenshotPhoto(_ localIdentifier: String) -> Bool {
        let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: Self.photosMetadataFetchOptions()
        )
        guard let asset = fetched.firstObject else { return false }
        return !asset.isHidden
            && asset.mediaType == .image
            && !asset.mediaSubtypes.contains(.photoScreenshot)
    }

    private static func collectSmartAlbumCatalog() -> [PhotosSmartAlbumEntry] {
        let fetchOptions = Self.photosMetadataFetchOptions()
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        var catalog: [PhotosSmartAlbumEntry] = []
        catalog.reserveCapacity(collections.count)
        for index in 0..<collections.count {
            let collection = collections.object(at: index)
            if collection.assetCollectionSubtype == .smartAlbumAllHidden { continue }
            let members = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            catalog.append(
                PhotosSmartAlbumEntry(
                    id: collection.localIdentifier,
                    subtype: collection.assetCollectionSubtype.rawValue,
                    title: collection.localizedTitle,
                    count: members.count
                )
            )
        }
        return catalog
    }

    private static func collectAlbumMemberships(visibleIDs: Set<String>) -> [String: [PhotosAlbumRef]] {
        guard !visibleIDs.isEmpty else { return [:] }
        var memberships: [String: [PhotosAlbumRef]] = [:]
        let albumOptions = Self.photosMetadataFetchOptions()
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            for index in 0..<collections.count {
                let collection = collections.object(at: index)
                if collection.assetCollectionSubtype == .smartAlbumAllHidden { continue }
                let ref = PhotosAlbumRef(
                    id: collection.localIdentifier,
                    kind: type == .album ? "user" : "smart",
                    subtype: collection.assetCollectionSubtype.rawValue,
                    title: collection.localizedTitle
                )
                let members = PHAsset.fetchAssets(in: collection, options: albumOptions)
                for mIndex in 0..<members.count {
                    let member = members.object(at: mIndex)
                    if !member.isHidden && visibleIDs.contains(member.localIdentifier) {
                        memberships[member.localIdentifier, default: []].append(ref)
                    }
                }
            }
        }
        for key in memberships.keys {
            memberships[key]?.sort { $0.id < $1.id }
        }
        return memberships
    }

    private func resolveCloudIdentifiers(for localIdentifiers: [String]) -> [String: String] {
        guard !localIdentifiers.isEmpty else { return [:] }
        var out: [String: String] = [:]
        var offset = 0
        while offset < localIdentifiers.count {
            let end = min(offset + Self.batchFetchChunkSize, localIdentifiers.count)
            let chunk = Array(localIdentifiers[offset..<end])
            let mappings = self.library.cloudIdentifierMappings(forLocalIdentifiers: chunk)
            for (localID, result) in mappings {
                if case .success(let cloudID) = result {
                    out[localID] = cloudID.stringValue
                }
            }
            offset = end
        }
        return out
    }

    private static func makeMetadataRow(
        _ asset: PHAsset,
        cloudID: String?,
        albums: [PhotosAlbumRef],
        formatter: ISO8601DateFormatter
    ) -> PhotosScanAssetRow {
        let mediaType: String = switch asset.mediaType {
        case .image: "photo"
        case .video: "video"
        case .audio: "audio"
        default: "unknown"
        }
        let location = asset.location.map { loc in
            PhotosAssetLocation(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                horizontalAccuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil
            )
        }
        let edited = asset.hasAdjustments

        var caption: String?
        var keywords: [String] = []
        var rating: Double?
        #if compiler(>=6.2)
        if #available(iOS 27, *) {
            let extMeta = asset.extendedMetadata
            if let cap = extMeta.caption, !cap.isEmpty {
                caption = cap
            }
            keywords = extMeta.keywords
            if asset.rating.rawValue > 0 {
                rating = Double(asset.rating.rawValue)
            }
        }
        #endif

        let hasExtended = caption != nil || !keywords.isEmpty || rating != nil
        let extended = hasExtended
            ? PhotosAssetExtended(
                caption: caption,
                keywords: keywords,
                rating: rating,
                uti: nil,
                originalFilename: nil
            )
            : nil

        return PhotosScanAssetRow(
            id: asset.localIdentifier,
            cloudId: cloudID,
            capturedAt: asset.creationDate.map(formatter.string(from:)),
            modifiedAt: asset.modificationDate.map(formatter.string(from:)),
            mediaType: mediaType,
            width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            duration: asset.duration > 0 ? asset.duration : nil,
            favorite: asset.isFavorite,
            hidden: false,
            edited: edited,
            screenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            livePhoto: asset.mediaSubtypes.contains(.photoLive),
            panorama: asset.mediaSubtypes.contains(.photoPanorama),
            hdr: asset.mediaSubtypes.contains(.photoHDR),
            depth: asset.mediaSubtypes.contains(.photoDepthEffect),
            burstIdentifier: asset.burstIdentifier,
            representsBurst: asset.representsBurst,
            burstSelection: asset.burstSelectionTypes.rawValue,
            location: location,
            albums: albums,
            extended: extended
        )
    }

    private static func archivePhotosToken(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func encodeUprightJPEG(_ image: UIImage, maxEdge: Int, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxEdge) / max(size.width, size.height))
        let target = CGSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format)
            .jpegData(withCompressionQuality: quality) { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
    }
}

private nonisolated final class CopyContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func finish(
        with value: (UIImage?, Bool),
        continuation: CheckedContinuation<(UIImage?, Bool), Never>
    ) {
        self.lock.lock()
        let shouldResume = !self.resumed
        if shouldResume {
            self.resumed = true
        }
        self.lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
    }
}
