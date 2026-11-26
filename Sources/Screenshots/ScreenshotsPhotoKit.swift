// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Photos

/// PhotoKit, scoped to the screenshot subtype. Original resource bytes only: nothing is
/// re-encoded, and no date is written into the file. Nonisolated: PhotoKit calls the change
/// observer and the resource handlers on its own queues.
nonisolated final class ScreenshotsPhotoKit: NSObject, ScreenshotsLibrary, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let library: PHPhotoLibrary
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?
    private var extraOnChange: [@Sendable () -> Void] = []
    private var screenshotsObserving = false
    private var photosLibraryObserving = false
    private var registered = false

    static let batchFetchChunkSize = 500

    init(library: PHPhotoLibrary = .shared()) {
        self.library = library
    }

    static func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) {
            work()
        }.value
    }

    static func runOffMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) {
            try work()
        }.value
    }

    /// Filter non-screenshots before invoking expensive per-asset resource extraction.
    static func filterAndMapAssets<Candidate>(
        _ candidates: [Candidate],
        isScreenshot: (Candidate) -> Bool,
        map: (Candidate) -> ScreenshotsAsset?
    ) -> [ScreenshotsAsset] {
        var result: [ScreenshotsAsset] = []
        for candidate in candidates where isScreenshot(candidate) {
            if let mapped = map(candidate) {
                result.append(mapped)
            }
        }
        return result
    }

    func setOnChange(_ onChange: @escaping @Sendable () -> Void) {
        self.lock.lock()
        self.onChange = onChange
        self.lock.unlock()
    }

    func addPhotosLibraryOnChange(_ listener: @escaping @Sendable () -> Void) {
        self.lock.lock()
        self.extraOnChange.append(listener)
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
        try await Self.runOffMainThrowing {
            try self.assets(matching: Self.fetchOptions(onOrAfter: start))
        }
    }

    func asset(localIdentifier: String) async -> ScreenshotsAsset? {
        await Self.runOffMain {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetched.firstObject, Self.isScreenshot(asset) else { return nil }
            return Self.makeAsset(asset)
        }
    }

    func assets(localIdentifiers: [String]) async -> [ScreenshotsAsset] {
        guard !localIdentifiers.isEmpty else { return [] }
        return await Self.runOffMain {
            var assets: [ScreenshotsAsset] = []
            var offset = 0
            while offset < localIdentifiers.count {
                let end = min(offset + Self.batchFetchChunkSize, localIdentifiers.count)
                let chunk = Array(localIdentifiers[offset..<end])
                offset = end
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
                var candidates: [PHAsset] = []
                candidates.reserveCapacity(fetched.count)
                fetched.enumerateObjects { asset, _, _ in
                    candidates.append(asset)
                }
                assets.append(contentsOf: Self.filterAndMapAssets(
                    candidates,
                    isScreenshot: Self.isScreenshot,
                    map: Self.makeAsset
                ))
            }
            return assets
        }
    }

    func changes(since token: Data?) async -> ScreenshotsChanges {
        guard let token else { return .expired }
        return await Self.runOffMain {
            guard let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else {
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
                guard let current = Self.archive(self.library.currentChangeToken) else { return .expired }
                return .delta(inserted: inserted, updated: updated, deleted: deleted, token: current)
            } catch let error as NSError {
                if error.domain == PHPhotosErrorDomain, error.code == PHPhotosError.persistentChangeTokenExpired.rawValue {
                    return .expired
                }
                return .delta(inserted: [], updated: [], deleted: [], token: token)
            }
        }
    }

    func currentToken() -> Data? {
        Self.archive(self.library.currentChangeToken)
    }

    func currentTokenAsync() async -> Data? {
        await Self.runOffMain {
            Self.archive(self.library.currentChangeToken)
        }
    }

    func export(localIdentifier: String) async -> ScreenshotsExportResult {
        await Task.detached(priority: .utility) {
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
                // @Sendable: PhotoKit runs these on its own queue, not the caller's actor.
                PHAssetResourceManager.default().requestData(for: resource, options: options) { @Sendable chunk in
                    box.append(chunk)
                } completionHandler: { @Sendable error in
                    if error != nil {
                        continuation.resume(returning: .failed)
                    } else {
                        continuation.resume(returning: .bytes(box.data, uniformTypeIdentifier: typeIdentifier))
                    }
                }
            }
        }.value
    }

    func setObserving(_ on: Bool) {
        self.lock.lock()
        self.screenshotsObserving = on
        let shouldRegister = self.screenshotsObserving || self.photosLibraryObserving
        let changed = shouldRegister != self.registered
        if changed {
            self.registered = shouldRegister
        }
        self.lock.unlock()
        guard changed else { return }
        if shouldRegister {
            self.library.register(self)
        } else {
            self.library.unregisterChangeObserver(self)
        }
    }

    func setPhotosLibraryObserving(_ on: Bool) {
        self.lock.lock()
        self.photosLibraryObserving = on
        let shouldRegister = self.screenshotsObserving || self.photosLibraryObserving
        let changed = shouldRegister != self.registered
        if changed {
            self.registered = shouldRegister
        }
        self.lock.unlock()
        guard changed else { return }
        if shouldRegister {
            self.library.register(self)
        } else {
            self.library.unregisterChangeObserver(self)
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        self.lock.lock()
        let primary = self.onChange
        let extras = self.extraOnChange
        self.lock.unlock()
        primary?()
        for listener in extras {
            listener()
        }
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

private nonisolated final class ExportBox: @unchecked Sendable {
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
