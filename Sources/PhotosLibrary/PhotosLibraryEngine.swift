// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
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
@Observable
final class PhotosLibraryEngine {
    nonisolated enum CapabilityState: Equatable, Sendable {
        case unknown
        case listed
        case notListed
    }

    @ObservationIgnored private let media: any PhotosLibraryMediaAccess
    @ObservationIgnored private let store: PhotosLibraryStore
    @ObservationIgnored private let transport: any PhotosLibraryTransport
    @ObservationIgnored private let intake: SourceIntakeStore?
    @ObservationIgnored private let deviceNameProvider: @MainActor () -> String
    @ObservationIgnored private let deviceKind: String
    @ObservationIgnored private let allowICloudDownload: Bool

    private(set) var document: PhotosLibraryDocument
    private(set) var access: ScreenshotsAccess
    private(set) var capability: CapabilityState = .unknown
    private(set) var isScanning = false
    private(set) var isSyncingCopies = false
    private(set) var scanChecked = 0
    private(set) var scanTotal = 0
    private(set) var journalSummary: PhotosJournalDashboardSummary?
    private(set) var lastPromptResult: ScreenshotsAccess?
    private(set) var lastError: String?
    @ObservationIgnored private var isUITestFixture = false
    @ObservationIgnored private var isForegroundRunning = false
    @ObservationIgnored private var hasPendingForeground = false
    @ObservationIgnored private var isHandlingLibraryChange = false
    @ObservationIgnored private var hasPendingLibraryChange = false

    @ObservationIgnored var isPaired: () -> Bool = { false }

    init(
        media: any PhotosLibraryMediaAccess,
        store: PhotosLibraryStore,
        transport: any PhotosLibraryTransport,
        intake: SourceIntakeStore? = nil,
        deviceNameProvider: @escaping @MainActor () -> String = { "iPhone" },
        deviceKind: String = "iphone",
        allowICloudDownload: Bool = true
    ) {
        self.media = media
        self.store = store
        self.transport = transport
        self.intake = intake
        self.deviceNameProvider = deviceNameProvider
        self.deviceKind = deviceKind
        self.allowICloudDownload = allowICloudDownload
        self.document = store.document
        self.access = media.photosAccess()
        self.scanChecked = store.document.itemsChecked
        self.scanTotal = store.document.itemsTotal
    }

    private func syncStore() {
        self.store.save()
        self.document = self.store.document
    }

    func viewState(locale: Locale = .current) -> PhotosLibraryViewState {
        PhotosLibraryViewState.resolve(
            paired: self.isPaired(),
            access: self.access,
            capability: self.capability,
            document: self.document,
            isScanning: self.isScanning,
            scanChecked: self.scanChecked,
            scanTotal: self.scanTotal,
            journal: self.journalSummary,
            lastPromptResult: self.lastPromptResult,
            locale: locale
        )
    }

    var waitingCount: Int {
        guard self.document.enabled, !self.document.paused else { return 0 }
        return self.journalSummary?.progress.waitingOnPhone ?? 0
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

    private func handleTransportError(_ error: any Error, logMessage: String) {
        if let transportError = error as? PhotosLibraryTransportError,
           transportError == .httpStatus(404)
        {
            self.capability = .notListed
            self.journalSummary = nil
            self.lastError = nil
            return
        }
        self.lastError = String(describing: error)
        photosEngineLog.error("\(logMessage, privacy: .public)")
    }

    func refreshJournalState() async {
        guard self.isPaired() else {
            self.journalSummary = nil
            return
        }
        switch await self.transport.fetchDashboardStateResult() {
        case .failed:
            return
        case .notFound:
            self.journalSummary = nil
            let cap = await self.refreshCapability()
            if cap != .listed {
                self.capability = .notListed
            }
            return
        case .ok(let summary):
            self.journalSummary = summary
            if summary.state == "off" && self.store.document.enabled {
                self.media.setPhotosLibraryObserving(false)
                self.store.document.enabled = false
                self.store.document.paused = false
                self.store.document.scanComplete = false
                self.store.document.changeToken = nil
                self.syncStore()
            } else if self.store.document.enabled {
                let journalPaused = (summary.state == "paused")
                if self.store.document.paused != journalPaused {
                    self.store.document.paused = journalPaused
                    self.syncStore()
                }
            }
        }
    }

    func foreground() async {
        guard !self.isUITestFixture else { return }
        if self.isForegroundRunning {
            self.hasPendingForeground = true
            return
        }
        self.isForegroundRunning = true
        defer { self.isForegroundRunning = false }
        while true {
            self.hasPendingForeground = false
            await self.runForegroundOnce()
            if !self.hasPendingForeground || self.isUITestFixture {
                break
            }
        }
    }

    private func runForegroundOnce() async {
        self.access = self.media.photosAccess()
        guard self.isPaired() else {
            self.capability = .unknown
            self.journalSummary = nil
            return
        }
        let cap = await self.refreshCapability()
        guard cap == .listed else {
            if cap == .notListed {
                self.journalSummary = nil
            }
            return
        }
        // Announce this photos-capable iPhone/iPad before reading dashboard state so the
        // journal makes the Photos row visible without enabling the source or creating a
        // holding area before the owner turns Photos on.
        await self.reportDeviceStatus(access: self.access, scanPaused: false)
        guard self.capability == .listed else { return }
        await self.refreshJournalState()
        guard self.capability == .listed else { return }
        if self.store.document.enabled && self.access != .full {
            return
        }
        await self.syncOnce()
    }

    /// Enable the Photos Library source after confirming the paired journal supports it
    /// and full PhotoKit access is granted, start observing changes, and run the initial
    /// metadata-only scan.
    func enableAndScan() async -> Bool {
        guard self.isPaired() else { return false }
        let cap = await self.refreshCapability()
        guard cap == .listed else {
            if cap == .notListed {
                self.journalSummary = nil
            }
            return false
        }
        var access = self.media.photosAccess()
        if access == .notDetermined {
            access = await self.media.requestPhotosAccess()
            self.lastPromptResult = access
        }
        self.access = access
        guard access == .full else {
            await self.reportDeviceStatus(access: access, scanPaused: false)
            return false
        }
        self.store.document.everEnabled = true
        self.store.document.enabled = true
        self.store.document.paused = false
        self.store.document.scanComplete = false
        self.syncStore()
        self.media.setPhotosLibraryObserving(true)
        let ok = await self.runFullMetadataScan()
        if ok {
            await self.refreshJournalState()
        }
        return ok
    }

    func pause() {
        self.store.document.paused = true
        self.syncStore()
    }

    func pauseWithJournalSync() async {
        self.pause()
        if self.isPaired(), self.capability == .listed {
            do {
                try await self.transport.postPause()
            } catch {
                self.handleTransportError(error, logMessage: "photos library pause sync failed")
                return
            }
            await self.refreshJournalState()
        }
    }

    func resume() async {
        self.store.document.paused = false
        self.syncStore()
        if self.isPaired(), self.capability == .listed {
            do {
                try await self.transport.postResume()
            } catch {
                self.handleTransportError(error, logMessage: "photos library resume sync failed")
                return
            }
            await self.refreshJournalState()
        }
        await self.syncOnce()
    }

    /// Privacy Principle 9: wipe per-journal token & counters on re-pairing while
    /// keeping the OS PhotoKit permission untouched.
    func restartFirstSetup() {
        self.media.setPhotosLibraryObserving(false)
        self.store.resetForNewPairing()
        self.document = self.store.document
        self.capability = .unknown
        self.isScanning = false
        self.isSyncingCopies = false
        self.hasPendingForeground = false
        self.hasPendingLibraryChange = false
        self.scanChecked = 0
        self.scanTotal = 0
        self.journalSummary = nil
        self.lastPromptResult = nil
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
            let estimatedTotal = smartAlbums.first(where: { $0.subtype == 209 })?.count ?? 0
            self.scanChecked = 0
            self.scanTotal = estimatedTotal
            let deviceName = self.deviceNameProvider()
            try await self.transport.postScanStart(
                PhotosScanStartPayload(
                    deviceName: deviceName,
                    deviceKind: self.deviceKind,
                    accessState: PhotosLibraryWire.accessString(access),
                    totalItems: estimatedTotal,
                    smartAlbums: smartAlbums
                )
            )
            let transport = self.transport
            let summary = try await self.media.scanAllVisibleMetadata(
                batchSize: PhotosLibraryWire.scanBatchSize
            ) { [weak self] batchIndex, rows, itemsChecked in
                try await transport.postScanBatch(
                    PhotosScanBatchPayload(
                        batchIndex: batchIndex,
                        rows: rows,
                        itemsChecked: itemsChecked
                    )
                )
                await MainActor.run {
                    self?.scanChecked = itemsChecked
                    if let currentTotal = self?.scanTotal, itemsChecked > currentTotal {
                        self?.scanTotal = itemsChecked
                    }
                }
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
            self.scanChecked = summary.totalItems
            self.scanTotal = summary.totalItems
            self.syncStore()
            return true
        } catch {
            self.handleTransportError(error, logMessage: "photos library full metadata scan failed")
            return false
        }
    }

    /// Handle an incremental PhotoKit change notification. Falls back cleanly to a
    /// full metadata rescan if the persistent change token expired.
    ///
    /// Re-entrant PhotoKit notifications (such as iCloud downloads triggered while
    /// exporting copies) coalesce onto a single follow-up pass rather than firing
    /// concurrent delta uploads against the same change token.
    func libraryChanged() async {
        if self.isHandlingLibraryChange {
            self.hasPendingLibraryChange = true
            return
        }
        self.isHandlingLibraryChange = true
        defer { self.isHandlingLibraryChange = false }
        while true {
            self.hasPendingLibraryChange = false
            await self.runLibraryChangedOnce()
            if !self.hasPendingLibraryChange {
                break
            }
        }
    }

    private func runLibraryChangedOnce() async {
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
            if !addedOrUpdated.isEmpty || !removedIDs.isEmpty {
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
                    self.syncStore()
                } catch {
                    self.handleTransportError(error, logMessage: "photos library delta sync failed")
                }
            } else if let nextToken {
                self.store.document.changeToken = nextToken
                self.syncStore()
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

        let previousICloudWaiting = self.store.document.icloudWaitingCount
        var handled = 0
        var icloudWaiting = 0
        for _ in 0..<max(1, maxBatches) {
            guard !self.store.document.paused else { break }
            let response: PhotosWantedResponse
            do {
                response = try await self.transport.fetchWanted(limit: PhotosLibraryWire.wantedBatchLimit)
            } catch {
                self.handleTransportError(error, logMessage: "photos library wanted poll failed")
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
                        let deliveredAt = Date()
                        self.store.document.sentCount += 1
                        self.store.document.lastUploadAt = deliveredAt
                        self.intake?.recordPhoto(assetID: item.assetID, now: deliveredAt)
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
                    self.handleTransportError(error, logMessage: "photos library copy upload failed")
                    break
                }
            }
            self.store.document.icloudWaitingCount = icloudWaiting
            self.syncStore()
            if response.remaining == 0 {
                break
            }
        }
        if icloudWaiting != previousICloudWaiting {
            await self.reportDeviceStatus(access: access, scanPaused: false)
        }
        if handled > 0 {
            await self.refreshJournalState()
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

    /// Deterministic UI-test fixture hook (used only when `--ui-test` is active).
    func applyUITestState(_ mode: String) {
        self.isUITestFixture = true
        self.capability = .listed
        switch mode {
        case "fresh":
            self.access = .notDetermined
            self.store.document = PhotosLibraryDocument()
            self.journalSummary = nil
        case "already-granted":
            self.access = .full
            self.store.document = PhotosLibraryDocument()
            self.journalSummary = nil
        case "scanning":
            self.access = .full
            self.store.document = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: false, itemsChecked: 1_200, itemsTotal: 4_500)
            self.isScanning = true
            self.scanChecked = 1_200
            self.scanTotal = 4_500
            self.journalSummary = PhotosJournalDashboardSummary(
                state: "setting_up",
                substate: "scanning",
                attentionReason: nil,
                choice: .init(range: nil, canWiden: true),
                progress: .init(chosenTotal: 0, arrived: 0, inJournal: 0, waitingOnPhone: 0),
                scan: .init(itemsChecked: 1_200, itemsTotal: 4_500, paused: false)
            )
        case "choose":
            self.access = .full
            self.store.document = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: true, itemsChecked: 4_500, itemsTotal: 4_500)
            self.isScanning = false
            self.journalSummary = PhotosJournalDashboardSummary(
                state: "setting_up",
                substate: "choose",
                attentionReason: nil,
                choice: .init(range: nil, canWiden: true),
                progress: .init(chosenTotal: 0, arrived: 0, inJournal: 0, waitingOnPhone: 0),
                scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
            )
        case "bringing-in":
            self.access = .full
            self.store.document = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: true, itemsChecked: 4_500, itemsTotal: 4_500, sentCount: 80)
            self.isScanning = false
            self.journalSummary = PhotosJournalDashboardSummary(
                state: "on",
                substate: "bringing_in",
                attentionReason: nil,
                choice: .init(range: "1y", canWiden: true),
                progress: .init(chosenTotal: 240, arrived: 80, inJournal: 80, waitingOnPhone: 160),
                scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
            )
        case "steady":
            self.access = .full
            self.store.document = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: true, itemsChecked: 4_500, itemsTotal: 4_500, sentCount: 240)
            self.isScanning = false
            self.journalSummary = PhotosJournalDashboardSummary(
                state: "on",
                substate: "steady",
                attentionReason: nil,
                choice: .init(range: "1y", canWiden: true),
                progress: .init(chosenTotal: 240, arrived: 240, inJournal: 235, waitingOnPhone: 0),
                scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
            )
        case "paused":
            self.access = .full
            self.store.document = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: true, scanComplete: true, itemsChecked: 4_500, itemsTotal: 4_500, sentCount: 80)
            self.isScanning = false
            self.journalSummary = PhotosJournalDashboardSummary(
                state: "paused",
                substate: "paused",
                attentionReason: nil,
                choice: .init(range: "1y", canWiden: true),
                progress: .init(chosenTotal: 240, arrived: 80, inJournal: 80, waitingOnPhone: 160),
                scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
            )
        case "limited-later":
            self.access = .limited
            self.store.document = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: true, itemsChecked: 4_500, itemsTotal: 4_500, sentCount: 240)
            self.isScanning = false
            self.journalSummary = PhotosJournalDashboardSummary(
                state: "needs_attention",
                substate: "access_limited",
                attentionReason: "access_limited",
                choice: .init(range: "1y", canWiden: true),
                progress: .init(chosenTotal: 240, arrived: 240, inJournal: 235, waitingOnPhone: 0),
                scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
            )
        default:
            break
        }
        self.document = self.store.document
    }

    private func reportDeviceStatus(access: ScreenshotsAccess, scanPaused: Bool) async {
        guard self.isPaired() else { return }
        do {
            try await self.transport.postStatus(
                PhotosDeviceStatusPayload(
                    deviceName: self.deviceNameProvider(),
                    deviceKind: self.deviceKind,
                    accessState: PhotosLibraryWire.accessString(access),
                    icloudWaitingCount: self.store.document.icloudWaitingCount,
                    scanPaused: scanPaused,
                    sourceEnabled: self.store.document.enabled
                )
            )
        } catch let error as PhotosLibraryTransportError where error == .httpStatus(404) {
            self.capability = .notListed
            self.journalSummary = nil
        } catch {}
    }
}
