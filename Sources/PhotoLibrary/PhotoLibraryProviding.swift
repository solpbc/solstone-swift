// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// One photo handed over by the library as a file the import route can take.
nonisolated struct PhotoLibraryExport: Sendable {
    let fileURL: URL
    let filename: String
}

nonisolated enum PhotoLibraryExportError: Error, Equatable, Sendable {
    /// The photo is gone, or no longer shared with the app.
    case unavailable
    /// The library could not hand the photo over.
    case unreadable
}

/// The seam over PhotoKit, so the importer can be tested without a photo library.
@MainActor
protocol PhotoLibraryProviding: AnyObject {
    func access() -> PhotoLibraryAccess
    func requestAccess() async -> PhotoLibraryAccess
    func albums() -> [PhotoLibraryAlbum]
    /// Photos in the scope, oldest first. Images only.
    func assetIDs(in scope: PhotoLibraryScope) -> [String]
    func export(assetID: String, into directory: URL) async throws -> PhotoLibraryExport
    /// Called when what the app can see changes: new photos, or a changed selection under
    /// selected-photos access (which iOS reports only after the owner finishes picking).
    var onChange: (@MainActor () -> Void)? { get set }
}

@MainActor
final class PhotoKitLibrary: NSObject, PhotoLibraryProviding, PHPhotoLibraryChangeObserver {
    var onChange: (@MainActor () -> Void)?
    private var isObserving = false

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.onChange?()
        }
    }

    /// Registers for changes only once the app can read the library, so a launch never
    /// touches the Photos permission on its own.
    private func observeIfReadable() {
        guard !self.isObserving, self.access().canRead else { return }
        self.isObserving = true
        PHPhotoLibrary.shared().register(self)
    }

    func access() -> PhotoLibraryAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> PhotoLibraryAccess {
        let access = Self.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        self.observeIfReadable()
        return access
    }

    nonisolated static func access(_ status: PHAuthorizationStatus) -> PhotoLibraryAccess {
        switch status {
        case .notDetermined:
            .notAsked
        case .authorized:
            .all
        case .limited:
            .selected
        case .denied:
            .off
        case .restricted:
            .unavailable
        @unknown default:
            .off
        }
    }

    func albums() -> [PhotoLibraryAlbum] {
        guard self.access().canRead else { return [] }
        self.observeIfReadable()
        var albums: [PhotoLibraryAlbum] = [.all, .favorites, .screenshots]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var owned: [PhotoLibraryAlbum] = []
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, !title.isEmpty else { return }
            owned.append(.album(collectionID: collection.localIdentifier, title: title))
        }
        owned.sort { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
        albums.append(contentsOf: owned)
        return albums
    }

    func assetIDs(in scope: PhotoLibraryScope) -> [String] {
        guard self.access().canRead else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue,
            scope.from as NSDate,
            scope.to as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets: PHFetchResult<PHAsset>
        switch scope.album.kind {
        case .all:
            assets = PHAsset.fetchAssets(with: options)
        case .favorites, .screenshots:
            let subtype: PHAssetCollectionSubtype = scope.album.kind == .favorites
                ? .smartAlbumFavorites
                : .smartAlbumScreenshots
            guard let collection = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: subtype,
                options: nil
            ).firstObject else {
                return []
            }
            assets = PHAsset.fetchAssets(in: collection, options: options)
        case .album:
            guard let collectionID = scope.album.collectionID,
                  let collection = PHAssetCollection.fetchAssetCollections(
                      withLocalIdentifiers: [collectionID],
                      options: nil
                  ).firstObject
            else {
                return []
            }
            assets = PHAsset.fetchAssets(in: collection, options: options)
        }
        var ids: [String] = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    func export(assetID: String, into directory: URL) async throws -> PhotoLibraryExport {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw PhotoLibraryExportError.unavailable
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let (data, dataUTI): (Data, String?) = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                if let data {
                    continuation.resume(returning: (data, dataUTI))
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: PhotoLibraryExportError.unavailable)
                } else {
                    continuation.resume(throwing: PhotoLibraryExportError.unreadable)
                }
            }
        }
        let original = PHAssetResource.assetResources(for: asset)
            .first { $0.type == .photo || $0.type == .fullSizePhoto }?
            .originalFilename
        let filename = PhotoLibraryFilename.name(original: original, dataUTI: dataUTI)
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PhotoLibraryExportError.unreadable
        }
        if let created = asset.creationDate {
            PhotoLibraryDateStamp.ensureCreationDate(fileURL: fileURL, created: created)
        }
        return PhotoLibraryExport(fileURL: fileURL, filename: filename)
    }
}

nonisolated enum PhotoLibraryFilename {
    /// The photo's own filename, with the extension the handed-over bytes actually have
    /// (an edited photo can come back as a different format from the original).
    static func name(original: String?, dataUTI: String?) -> String {
        let base = original.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "photo"
        let ext = dataUTI.flatMap { UTType($0)?.preferredFilenameExtension }
            ?? original.map { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "jpg"
        return "\(base).\(ext)"
    }
}

/// The journal dates an imported image by its embedded capture time. A photo without one
/// (many screenshots) would land on the day it was imported, so the copy taken in gets the
/// date Photos holds for it. The original in the library is never touched.
nonisolated enum PhotoLibraryDateStamp {
    static func ensureCreationDate(fileURL: URL, created: Date, timeZone: TimeZone = .current) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source)
        else {
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let existing = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !existing.isEmpty {
            return
        }
        let stamp = self.exifStrings(for: created, timeZone: timeZone)
        var stampedExif = exif
        stampedExif[kCGImagePropertyExifDateTimeOriginal] = stamp.dateTime
        stampedExif[kCGImagePropertyExifOffsetTimeOriginal] = stamp.offset
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".stamp-\(UUID().uuidString)", isDirectory: false)
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, type, 1, nil) else {
            return
        }
        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            [kCGImagePropertyExifDictionary: stampedExif] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
    }

    static func exifStrings(for date: Date, timeZone: TimeZone) -> (dateTime: String, offset: String) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let offset = String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
        return (formatter.string(from: date), offset)
    }
}
