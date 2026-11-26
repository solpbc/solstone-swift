// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let photosEngineLog = Logger(subsystem: "app.solstone.swift", category: "photos-library")

/// Client-side coordinator for the Photos Library source (phase 1, iPhone).
///
/// Responsibilities:
/// 1. Metadata-only full & incremental PhotoKit scan into the journal's holding area.
/// 2. Client-initiated polling of the journal's wanted list (`/app/devices/photos-library/wanted`).
/// 3. On-demand 512 px JPEG export and delivery (`/app/devices/photos-library/copy`), reporting
///    `"gone"` for removed assets and `"icloud_waiting"` when iCloud download is pending.
/// 4. Strict adherence to full-access requirement, capability gate (`photos_library`),
///    Privacy Principle 8 (never send before journal confirmation), and Privacy Principle 9
///    (`restartFirstSetup()` on new pairing).
@MainActor
final class PhotosLibraryEngine {
    enum CapabilityState: Equatable, Sendable {
        case unknown
        case listed
        case notListed
    }

    private let media: any PhotosLibraryMediaAccess
    private let store: PhotosLibraryStore
    private let transport: any PhotosLibraryTransport
    private let deviceNameProvider: @MainActor () -> String
    private let deviceKind: String
    private let allowICloudDownload: Bool

    private(set) var capability: CapabilityState = .unknown
    private(set) var isScanning = false
    private(set) var isSyncingCopies = false
    private(set) var lastError: String?

    var isPaired: () -> Bool = { false }

    init(
        media: any PhotosLibraryMediaAccess,
        store: PhotosLibraryStore,
        transport: any PhotosLibraryTransport,
        deviceNameProvider: @escaping @MainActor () -> String = { "iPhone" },
        deviceKind: String = "iphone",
        allowICloudDownload: Bool = true
    ) {
        self.media = media
        self.store = store
        self.transport = transport
        self.deviceNameProvider = deviceNameProvider
        self.deviceKind = deviceKind
        self.allowICloudDownload = allowICloudDownload
    }

    var document: PhotosLibraryDocument {
        self.store.document
    }

    func refreshCapability() async -> CapabilityState {
        guard self.isPaired() else {
            self.capability = .unknown
            return .unknown
        }
        guard let listed = await self.transport.checkCapability() else {
            return self.capability
        }
        self.capability = listed ? .listed : .notListed
        return self.capability
    }

    /// Enable the Photos Library source after confirming full PhotoKit access,
    /// start observing changes, and run the initial metadata-only scan.
    func enableAndScan() async -> Bool {
        var access = self.media.photosAccess()
        if access == .notDetermined {
            access = await self.media.requestPhotosAccess()
        }
        guard access == .full else {
            await self.reportDeviceStatus(access: access, scanPaused: false)
            return false
        }
        self.store.document.everEnabled = true
        self.store.document.enabled = true
        self.store.document.paused = false
        self.store.save()
        self.media.setPhotosLibraryObserving(true)
        return await self.runFullMetadataScan()
    }

    func pause() {
        self.store.document.paused = true
        self.store.save()
    }

    func resume() async {
        self.store.document.paused = false
        self.store.save()
        await self.syncOnce()
    }

    /// Privacy Principle 9: wipe per-journal token & counters on re-pairing while
    /// keeping the OS PhotoKit permission untouched.
    func restartFirstSetup() {
        self.media.setPhotosLibraryObserving(false)
        self.store.resetForNewPairing()
        self.capability = .unknown
        self.isScanning = false
        self.isSyncingCopies = false
        self.lastError = nil
    }

    /// Run a complete metadata-only scan of all visible library assets (zero pixels).
    func runFullMetadataScan() async -> Bool {
        guard !self.isScanning else { return false }
        guard self.isPaired() else { return false }
        let cap = await self.refreshCapability()
        guard cap == .listed else { return false }

        let access = self.media.photosAccess()
        guard access == .full else {
            await self.reportDeviceStatus(access: access, scanPaused: false)
            return false
        }

        self.isScanning = true
        self.lastError = nil
        defer { self.isScanning = false }

        do {
            let smartAlbums = try await self.media.fetchSmartAlbumCatalog()
            let deviceName = self.deviceNameProvider()
            try await self.transport.postScanStart(
                PhotosScanStartPayload(
                    deviceName: deviceName,
                    deviceKind: self.deviceKind,
                    accessState: PhotosLibraryWire.accessString(access),
                    totalItems: 0,
                    smartAlbums: smartAlbums
                )
            )
            let transport = self.transport
            let summary = try await self.media.scanAllVisibleMetadata(
                batchSize: PhotosLibraryWire.scanBatchSize
            ) { batchIndex, rows, itemsChecked in
                try await transport.postScanBatch(
                    PhotosScanBatchPayload(
                        batchIndex: batchIndex,
                        rows: rows,
                        itemsChecked: itemsChecked
                    )
                )
            }
            try await self.transport.postScanFinish(
                PhotosScanFinishPayload(
                    itemsChecked: summary.totalItems,
                    earliestItemAt: summary.earliestItemAt,
                    accessState: PhotosLibraryWire.accessString(access),
                    icloudWaitingCount: self.store.document.icloudWaitingCount
                )
            )
            self.store.document.scanComplete = true
            self.store.document.itemsChecked = summary.totalItems
            self.store.document.itemsTotal = summary.totalItems
            self.store.document.changeToken = summary.changeToken
            self.store.document.lastScanAt = Date()
            self.store.save()
            return true
        } catch {
            self.lastError = String(describing: error)
            photosEngineLog.error("photos library full metadata scan failed")
            return false
        }
    }

    /// Handle an incremental PhotoKit change notification. Falls back cleanly to a
    /// full metadata rescan if the persistent change token expired.
    func libraryChanged() async {
        guard self.store.document.enabled, !self.store.document.paused, self.isPaired() else { return }
        let access = self.media.photosAccess()
        guard access == .full else {
            await self.reportDeviceStatus(access: access, scanPaused: false)
            return
        }
        guard self.store.document.scanComplete else {
            _ = await self.runFullMetadataScan()
            return
        }

        let changes = await self.media.fetchMetadataChanges(since: self.store.document.changeToken)
        switch changes {
        case .expired:
            _ = await self.runFullMetadataScan()
        case .delta(let addedOrUpdated, let removedIDs, let nextToken):
            guard !addedOrUpdated.isEmpty || !removedIDs.isEmpty else {
                if let nextToken {
                    self.store.document.changeToken = nextToken
                    self.store.save()
                }
                return
            }
            do {
                let smartAlbums = try? await self.media.fetchSmartAlbumCatalog()
                try await self.transport.postScanChanges(
                    PhotosScanChangesPayload(
                        addedOrUpdated: addedOrUpdated,
                        removedIDs: removedIDs,
                        smartAlbums: smartAlbums,
                        accessState: PhotosLibraryWire.accessString(access),
                        icloudWaitingCount: self.store.document.icloudWaitingCount
                    )
                )
                self.store.document.changeToken = nextToken
                self.store.document.lastScanAt = Date()
                self.store.save()
            } catch {
                self.lastError = String(describing: error)
                photosEngineLog.error("photos library delta sync failed")
            }
        }
        await self.pollAndDeliverWantedCopies()
    }

    /// Poll the journal's wanted list and deliver 512 px JPEGs (or `"gone"` / `"icloud_waiting"`).
    /// Returns the number of items handled (delivered, gone, or marked waiting).
    @discardableResult
    func pollAndDeliverWantedCopies(maxBatches: Int = 5) async -> Int {
        guard self.store.document.enabled, !self.store.document.paused, !self.isSyncingCopies else {
            return 0
        }
        guard self.isPaired() else { return 0 }
        let cap = await self.refreshCapability()
        guard cap == .listed else { return 0 }
        let access = self.media.photosAccess()
        guard access == .full else {
            await self.reportDeviceStatus(access: access, scanPaused: false)
            return 0
        }

        self.isSyncingCopies = true
        defer { self.isSyncingCopies = false }

        var handled = 0
        var icloudWaiting = 0
        for _ in 0..<max(1, maxBatches) {
            guard !self.store.document.paused else { break }
            let response: PhotosWantedResponse
            do {
                response = try await self.transport.fetchWanted(limit: PhotosLibraryWire.wantedBatchLimit)
            } catch {
                self.lastError = String(describing: error)
                break
            }
            if response.paused || response.wanted.isEmpty {
                break
            }
            for item in response.wanted {
                guard !self.store.document.paused else { break }
                let edge = item.maxEdge > 0 ? item.maxEdge : PhotosLibraryWire.copyMaxEdge
                var exportResult = await self.media.exportPhotoCopy(
                    localIdentifier: item.assetID,
                    maxEdge: edge,
                    allowNetwork: false
                )
                if exportResult == .icloudWaiting && self.allowICloudDownload {
                    exportResult = await self.media.exportPhotoCopy(
                        localIdentifier: item.assetID,
                        maxEdge: edge,
                        allowNetwork: true
                    )
                }
                do {
                    switch exportResult {
                    case .jpeg(let data):
                        try await self.transport.postCopy(
                            PhotosCopyUploadPayload(
                                assetID: item.assetID,
                                cloudID: item.cloudID,
                                status: "ok",
                                jpegBase64: data.base64EncodedString()
                            )
                        )
                        self.store.document.sentCount += 1
                        self.store.document.lastUploadAt = Date()
                        handled += 1
                    case .gone:
                        try await self.transport.postCopy(
                            PhotosCopyUploadPayload(
                                assetID: item.assetID,
                                cloudID: item.cloudID,
                                status: "gone",
                                jpegBase64: nil
                            )
                        )
                        handled += 1
                    case .icloudWaiting:
                        icloudWaiting += 1
                        try await self.transport.postCopy(
                            PhotosCopyUploadPayload(
                                assetID: item.assetID,
                                cloudID: item.cloudID,
                                status: "icloud_waiting",
                                jpegBase64: nil
                            )
                        )
                        handled += 1
                    case .failed:
                        break
                    }
                } catch {
                    self.lastError = String(describing: error)
                    photosEngineLog.error("photos library copy upload failed")
                    break
                }
            }
            self.store.document.icloudWaitingCount = icloudWaiting
            self.store.save()
            if response.remaining == 0 {
                break
            }
        }
        return handled
    }

    /// Run one foreground/background sync pass: incremental scan (or full scan if
    /// needed) followed by wanted-list polling.
    func syncOnce() async {
        guard self.store.document.enabled, !self.store.document.paused, self.isPaired() else { return }
        if !self.store.document.scanComplete {
            _ = await self.runFullMetadataScan()
        } else {
            await self.libraryChanged()
            return
        }
        await self.pollAndDeliverWantedCopies()
    }

    private func reportDeviceStatus(access: ScreenshotsAccess, scanPaused: Bool) async {
        guard self.isPaired() else { return }
        try? await self.transport.postStatus(
            PhotosDeviceStatusPayload(
                deviceName: self.deviceNameProvider(),
                deviceKind: self.deviceKind,
                accessState: PhotosLibraryWire.accessString(access),
                icloudWaitingCount: self.store.document.icloudWaitingCount,
                scanPaused: scanPaused
            )
        )
    }
}
