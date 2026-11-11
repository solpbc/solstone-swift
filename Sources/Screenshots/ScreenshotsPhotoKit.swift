// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Photos

/// PhotoKit, scoped to the screenshot subtype. Original resource bytes only: nothing is
/// re-encoded, and no date is written into the file.
final class ScreenshotsPhotoKit: NSObject, ScreenshotsLibrary, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let library: PHPhotoLibrary
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?
    private var observing = false

    init(library: PHPhotoLibrary = .shared()) {
        self.library = library
    }

    func setOnChange(_ onChange: @escaping @Sendable () -> Void) {
        self.lock.lock()
        self.onChange = onChange
        self.lock.unlock()
    }

    func access() -> ScreenshotsAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> ScreenshotsAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }

    func screenshots(onOrAfter start: Date) async throws -> [ScreenshotsAsset] {
        try self.assets(matching: Self.fetchOptions(onOrAfter: start))
    }

    func asset(localIdentifier: String) async -> ScreenshotsAsset? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetched.firstObject, Self.isScreenshot(asset) else { return nil }
        return Self.makeAsset(asset)
    }

    func changes(since token: Data?) async -> ScreenshotsChanges {
        guard let token, let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else {
            return .expired
        }
        do {
            let result = try self.library.fetchPersistentChanges(since: stored)
            var inserted: [String] = []
            var updated: [String] = []
            var deleted: [String] = []
            for change in result {
                let details = try change.changeDetails(for: .asset)
                inserted.append(contentsOf: details.insertedLocalIdentifiers)
                updated.append(contentsOf: details.updatedLocalIdentifiers)
                deleted.append(contentsOf: details.deletedLocalIdentifiers)
            }
            guard let token = Self.archive(self.library.currentChangeToken) else { return .expired }
            return .delta(inserted: inserted, updated: updated, deleted: deleted, token: token)
        } catch let error as NSError {
            if error.domain == PHPhotosErrorDomain, error.code == PHPhotosError.persistentChangeTokenExpired.rawValue {
                return .expired
            }
            return .delta(inserted: [], updated: [], deleted: [], token: token)
        }
    }

    func currentToken() -> Data? {
        Self.archive(self.library.currentChangeToken)
    }

    func export(localIdentifier: String) async -> ScreenshotsExportResult {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetched.firstObject else { return .missing }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }) else {
            return .failed
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let typeIdentifier = resource.uniformTypeIdentifier
        return await withCheckedContinuation { continuation in
            let box = ExportBox()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                box.append(chunk)
            } completionHandler: { error in
                if error != nil {
                    continuation.resume(returning: .failed)
                } else {
                    continuation.resume(returning: .bytes(box.data, uniformTypeIdentifier: typeIdentifier))
                }
            }
        }
    }

    func setObserving(_ on: Bool) {
        guard on != self.observing else { return }
        self.observing = on
        if on {
            self.library.register(self)
        } else {
            self.library.unregisterChangeObserver(self)
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        self.lock.lock()
        let onChange = self.onChange
        self.lock.unlock()
        onChange?()
    }

    static func fetchOptions(onOrAfter start: Date?) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = self.predicate(onOrAfter: start)
        return options
    }

    static func predicate(onOrAfter start: Date?) -> NSPredicate {
        let subtype = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        guard let start else { return subtype }
        let created = NSPredicate(format: "creationDate >= %@", start as NSDate)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [subtype, created])
    }

    private func assets(matching options: PHFetchOptions) throws -> [ScreenshotsAsset] {
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [ScreenshotsAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            guard Self.isScreenshot(asset), let made = Self.makeAsset(asset) else { return }
            assets.append(made)
        }
        return assets
    }

    private static func isScreenshot(_ asset: PHAsset) -> Bool {
        ScreenshotsWire.isScreenshot(
            mediaSubtypeRaw: asset.mediaSubtypes.rawValue,
            screenshotRaw: PHAssetMediaSubtype.photoScreenshot.rawValue
        )
    }

    private static func makeAsset(_ asset: PHAsset) -> ScreenshotsAsset? {
        guard let created = asset.creationDate else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo })
        return ScreenshotsAsset(
            localIdentifier: asset.localIdentifier,
            created: created,
            uniformTypeIdentifier: resource?.uniformTypeIdentifier ?? "public.image",
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private static func map(_ status: PHAuthorizationStatus) -> ScreenshotsAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .full
        case .limited: .limited
        @unknown default: .denied
        }
    }

    private static func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}

private final class ExportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ chunk: Data) {
        self.lock.lock()
        self.storage.append(chunk)
        self.lock.unlock()
    }
}
