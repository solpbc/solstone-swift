// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Photos
import UIKit
import XCTest
@testable import solstone_swift

@MainActor
final class PhotosLibraryTests: XCTestCase {
    private nonisolated final class FakeMedia: PhotosLibraryMediaAccess, @unchecked Sendable {
        private let lock = NSLock()
        var accessState: ScreenshotsAccess = .full
        var smartAlbums: [PhotosSmartAlbumEntry] = [
            PhotosSmartAlbumEntry(id: "sa-cbm", subtype: 1_000_000_220, title: "Captured by Me", count: 2),
            PhotosSmartAlbumEntry(id: "sa-saved", subtype: 1_000_000_218, title: "Recently Saved", count: 0),
        ]
        var rows: [PhotosScanAssetRow] = []
        var exportResults: [String: PhotosCopyExportResult] = [:]
        var exportCalls: [(id: String, maxEdge: Int, allowNetwork: Bool)] = []
        var changesResult: PhotosMetadataChanges = .delta(addedOrUpdated: [], removedIDs: [], token: Data([2]))
        var observing = false
        var changeListeners: [@Sendable () -> Void] = []

        func photosAccess() -> ScreenshotsAccess { self.lock.withLock { self.accessState } }
        func requestPhotosAccess() async -> ScreenshotsAccess { self.lock.withLock { self.accessState } }
        func fetchSmartAlbumCatalog() async throws -> [PhotosSmartAlbumEntry] { self.lock.withLock { self.smartAlbums } }
        func currentPhotosChangeToken() async -> Data? { Data([1]) }

        func scanAllVisibleMetadata(
            batchSize: Int,
            onBatch: @escaping @Sendable (Int, [PhotosScanAssetRow], Int) async throws -> Void
        ) async throws -> PhotosFullScanSummary {
            let currentRows = self.lock.withLock { self.rows }
            let step = max(1, batchSize)
            var idx = 0
            var offset = 0
            var earliest: String?
            for r in currentRows {
                if let cap = r.capturedAt, earliest == nil || cap < earliest! {
                    earliest = cap
                }
            }
            while offset < currentRows.count {
                let end = min(offset + step, currentRows.count)
                try await onBatch(idx, Array(currentRows[offset..<end]), end)
                idx += 1
                offset = end
            }
            return PhotosFullScanSummary(totalItems: currentRows.count, earliestItemAt: earliest, changeToken: Data([1]))
        }

        func fetchMetadataChanges(since token: Data?) async -> PhotosMetadataChanges {
            self.lock.withLock { self.changesResult }
        }

        func exportPhotoCopy(localIdentifier: String, maxEdge: Int, allowNetwork: Bool) async -> PhotosCopyExportResult {
            self.lock.withLock {
                self.exportCalls.append((localIdentifier, maxEdge, allowNetwork))
                return self.exportResults[localIdentifier] ?? .gone
            }
        }

        func setPhotosLibraryObserving(_ on: Bool) {
            self.lock.withLock { self.observing = on }
        }

        func addPhotosLibraryOnChange(_ listener: @escaping @Sendable () -> Void) {
            self.lock.withLock { self.changeListeners.append(listener) }
        }
    }

    private nonisolated final class FakeTransport: PhotosLibraryTransport, @unchecked Sendable {
        private let lock = NSLock()
        var capabilityListed: Bool? = true
        var scanStarts: [PhotosScanStartPayload] = []
        var scanBatches: [PhotosScanBatchPayload] = []
        var scanFinishes: [PhotosScanFinishPayload] = []
        var scanChanges: [PhotosScanChangesPayload] = []
        var statuses: [PhotosDeviceStatusPayload] = []
        var wantedQueue: [PhotosWantedResponse] = []
        var copyUploads: [PhotosCopyUploadPayload] = []
        var dashboardSummary: PhotosJournalDashboardSummary?
        var dashboardResultOverride: PhotosDashboardFetchResult?
        var statusError: (any Error)?
        var dashboardFetchCount = 0

        func checkCapability() async -> Bool? { self.lock.withLock { self.capabilityListed } }
        func fetchDashboardState() async -> PhotosJournalDashboardSummary? {
            self.lock.withLock {
                self.dashboardFetchCount += 1
                return self.dashboardSummary
            }
        }
        func fetchDashboardStateResult() async -> PhotosDashboardFetchResult {
            self.lock.withLock {
                self.dashboardFetchCount += 1
                if let override = self.dashboardResultOverride { return override }
                if let summary = self.dashboardSummary { return .ok(summary) }
                return .failed
            }
        }
        func postScanStart(_ payload: PhotosScanStartPayload) async throws { self.lock.withLock { self.scanStarts.append(payload) } }
        func postScanBatch(_ payload: PhotosScanBatchPayload) async throws { self.lock.withLock { self.scanBatches.append(payload) } }
        func postScanFinish(_ payload: PhotosScanFinishPayload) async throws { self.lock.withLock { self.scanFinishes.append(payload) } }
        func postScanChanges(_ payload: PhotosScanChangesPayload) async throws { self.lock.withLock { self.scanChanges.append(payload) } }
        func postStatus(_ payload: PhotosDeviceStatusPayload) async throws {
            let err: (any Error)? = self.lock.withLock {
                self.statuses.append(payload)
                return self.statusError
            }
            if let err { throw err }
        }

        func fetchWanted(limit: Int) async throws -> PhotosWantedResponse {
            self.lock.withLock {
                if self.wantedQueue.isEmpty {
                    return PhotosWantedResponse(paused: false, range: "all", wanted: [], remaining: 0)
                }
                return self.wantedQueue.removeFirst()
            }
        }

        func postCopy(_ payload: PhotosCopyUploadPayload) async throws {
            self.lock.withLock { self.copyUploads.append(payload) }
        }
    }

    private func makeRow(id: String, cloudID: String? = nil, capturedAt: String) -> PhotosScanAssetRow {
        PhotosScanAssetRow(
            id: id,
            cloudId: cloudID,
            capturedAt: capturedAt,
            modifiedAt: capturedAt,
            mediaType: "photo",
            width: 4032,
            height: 3024,
            duration: nil,
            favorite: false,
            hidden: false,
            edited: false,
            screenshot: false,
            livePhoto: false,
            panorama: false,
            hdr: false,
            depth: false,
            burstIdentifier: nil,
            representsBurst: false,
            burstSelection: 0,
            location: nil,
            albums: [PhotosAlbumRef(id: "sa-cbm", kind: "smart", subtype: 1_000_000_220, title: "Captured by Me")],
            extended: nil
        )
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-library-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    func testScanMovesMetadataOnlyZeroPixelsAndWantedDelivers512pxAndGone() async {
        let media = FakeMedia()
        media.rows = [
            self.makeRow(id: "asset-1", cloudID: "cloud-1", capturedAt: "2026-11-19T12:00:00Z"),
            self.makeRow(id: "asset-2", cloudID: "cloud-2", capturedAt: "2026-11-19T12:15:00Z"),
        ]
        media.exportResults["asset-1"] = .jpeg(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        media.exportResults["asset-2"] = .gone

        let transport = FakeTransport()
        let store = PhotosLibraryStore(fileURL: self.tempStoreURL())
        let engine = PhotosLibraryEngine(
            media: media,
            store: store,
            transport: transport,
            deviceNameProvider: { "Test iPhone" }
        )
        engine.isPaired = { true }

        // 1. Metadata scan sends smart albums + rows and NEVER touches pixels!
        let scanned = await engine.enableAndScan()
        XCTAssertTrue(scanned)
        XCTAssertTrue(media.observing)
        XCTAssertEqual(media.exportCalls.count, 0)
        XCTAssertEqual(transport.scanStarts.count, 1)
        XCTAssertEqual(transport.scanBatches.count, 1)
        XCTAssertEqual(transport.scanBatches[0].rows.count, 2)
        XCTAssertEqual(transport.scanFinishes.count, 1)
        XCTAssertEqual(engine.document.itemsTotal, 2)
        XCTAssertTrue(engine.document.scanComplete)

        // 2. Wanted list pulls 512 px copy for asset-1 and reports "gone" for removed asset-2.
        transport.wantedQueue = [
            PhotosWantedResponse(
                paused: false,
                range: "all",
                wanted: [
                    PhotosWantedItem(assetID: "asset-1", cloudID: "cloud-1", maxEdge: 512, capturedAt: "2026-11-19T12:00:00Z", reasonKind: "keep"),
                    PhotosWantedItem(assetID: "asset-2", cloudID: "cloud-2", maxEdge: 512, capturedAt: "2026-11-19T12:15:00Z", reasonKind: "keep"),
                ],
                remaining: 0
            )
        ]
        let handled = await engine.pollAndDeliverWantedCopies()
        XCTAssertEqual(handled, 2)
        XCTAssertEqual(media.exportCalls.count, 2)
        XCTAssertEqual(media.exportCalls[0].maxEdge, 512)
        XCTAssertEqual(transport.copyUploads.count, 2)
        XCTAssertEqual(transport.copyUploads[0].assetID, "asset-1")
        XCTAssertEqual(transport.copyUploads[0].status, "ok")
        XCTAssertNotNil(transport.copyUploads[0].jpegBase64)
        XCTAssertEqual(transport.copyUploads[1].assetID, "asset-2")
        XCTAssertEqual(transport.copyUploads[1].status, "gone")
        XCTAssertNil(transport.copyUploads[1].jpegBase64)
        XCTAssertEqual(engine.document.sentCount, 1)
    }

    func testLimitedAccessReportsStatusAndRefusesScan() async {
        let media = FakeMedia()
        media.accessState = .limited
        let transport = FakeTransport()
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport
        )
        engine.isPaired = { true }

        let ok = await engine.enableAndScan()
        XCTAssertFalse(ok)
        XCTAssertEqual(transport.scanStarts.count, 0)
        XCTAssertEqual(transport.statuses.last?.accessState, "limited")
    }

    func testCapabilityMissingBlocksScanAndCopies() async {
        let media = FakeMedia()
        let transport = FakeTransport()
        transport.capabilityListed = false
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport
        )
        engine.isPaired = { true }

        let ok = await engine.enableAndScan()
        XCTAssertFalse(ok)
        XCTAssertEqual(engine.capability, .notListed)
        XCTAssertEqual(transport.scanStarts.count, 0)
    }

    func testRepairingRestartFirstSetupClearsTokenAndCounts() async {
        let media = FakeMedia()
        media.rows = [self.makeRow(id: "asset-1", capturedAt: "2026-11-19T12:00:00Z")]
        let transport = FakeTransport()
        let storeURL = self.tempStoreURL()
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: storeURL),
            transport: transport
        )
        engine.isPaired = { true }
        _ = await engine.enableAndScan()
        XCTAssertTrue(engine.document.scanComplete)
        XCTAssertNotNil(engine.document.changeToken)

        engine.restartFirstSetup()
        XCTAssertFalse(media.observing)
        XCTAssertFalse(engine.document.enabled)
        XCTAssertFalse(engine.document.scanComplete)
        XCTAssertNil(engine.document.changeToken)
        XCTAssertEqual(engine.document.sentCount, 0)
        XCTAssertEqual(engine.capability, .unknown)
    }

    func testExpiredTokenFallsBackToFullRescanAndPauseStopsDelivery() async {
        let media = FakeMedia()
        media.rows = [self.makeRow(id: "asset-1", capturedAt: "2026-11-19T12:00:00Z")]
        media.changesResult = .expired
        let transport = FakeTransport()
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport
        )
        engine.isPaired = { true }
        _ = await engine.enableAndScan()
        XCTAssertEqual(transport.scanStarts.count, 1)

        await engine.libraryChanged()
        XCTAssertEqual(transport.scanStarts.count, 2)

        engine.pause()
        transport.wantedQueue = [
            PhotosWantedResponse(
                paused: false,
                range: "all",
                wanted: [PhotosWantedItem(assetID: "asset-1", cloudID: nil, maxEdge: 512, capturedAt: nil, reasonKind: "keep")],
                remaining: 0
            )
        ]
        let handledWhilePaused = await engine.pollAndDeliverWantedCopies()
        XCTAssertEqual(handledWhilePaused, 0)
        XCTAssertEqual(transport.copyUploads.count, 0)
    }

    func testForegroundDrainsWantedCopiesOnEmptyDeltaAndReconcilesJournalResume() async {
        let media = FakeMedia()
        media.rows = [self.makeRow(id: "asset-1", cloudID: "cloud-1", capturedAt: "2026-11-19T12:00:00Z")]
        media.changesResult = .delta(addedOrUpdated: [], removedIDs: [], token: Data([3]))
        media.exportResults["asset-1"] = .jpeg(Data([0xFF, 0xD8, 0xFF, 0xD9]))

        let transport = FakeTransport()
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport,
            deviceNameProvider: { "Test iPhone" }
        )
        engine.isPaired = { true }
        _ = await engine.enableAndScan()
        XCTAssertTrue(engine.document.scanComplete)

        // Pause locally, then journal resumes ("on") -> foreground clears local pause and drains wanted even with empty PhotoKit delta.
        engine.pause()
        XCTAssertTrue(engine.document.paused)
        transport.dashboardSummary = PhotosJournalDashboardSummary(
            state: "on",
            substate: "bringing_in",
            attentionReason: nil,
            choice: .init(range: "1y", canWiden: true),
            progress: .init(chosenTotal: 1, arrived: 0, inJournal: 0, waitingOnPhone: 1),
            scan: .init(itemsChecked: 1, itemsTotal: 1, paused: false)
        )
        transport.wantedQueue = [
            PhotosWantedResponse(
                paused: false,
                range: "1y",
                wanted: [
                    PhotosWantedItem(assetID: "asset-1", cloudID: "cloud-1", maxEdge: 512, capturedAt: "2026-11-19T12:00:00Z", reasonKind: "keep")
                ],
                remaining: 0
            )
        ]

        await engine.foreground()
        XCTAssertFalse(engine.document.paused)
        XCTAssertEqual(transport.scanChanges.count, 0)
        XCTAssertEqual(transport.copyUploads.count, 1)
        XCTAssertEqual(transport.copyUploads[0].assetID, "asset-1")
        XCTAssertEqual(transport.copyUploads[0].status, "ok")
    }

    func testWantedPollReportsICloudWaitingCountToJournal() async {
        let media = FakeMedia()
        media.rows = [self.makeRow(id: "asset-cloud", cloudID: "cloud-9", capturedAt: "2026-11-19T12:00:00Z")]
        media.exportResults["asset-cloud"] = .icloudWaiting

        let transport = FakeTransport()
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport,
            deviceNameProvider: { "Test iPhone" }
        )
        engine.isPaired = { true }
        _ = await engine.enableAndScan()

        transport.wantedQueue = [
            PhotosWantedResponse(
                paused: false,
                range: "1y",
                wanted: [
                    PhotosWantedItem(assetID: "asset-cloud", cloudID: "cloud-9", maxEdge: 512, capturedAt: "2026-11-19T12:00:00Z", reasonKind: "keep")
                ],
                remaining: 0
            )
        ]

        let handled = await engine.pollAndDeliverWantedCopies()
        XCTAssertEqual(handled, 1)
        XCTAssertEqual(engine.document.icloudWaitingCount, 1)
        XCTAssertEqual(transport.statuses.last?.icloudWaitingCount, 1)
    }

    func testAuthenticatedClientHonorsSendAdmissionGate() async {
        let client = AuthenticatedPhotosLibraryClient(
            localPortProvider: { 12345 },
            admitSend: { false }
        )
        do {
            _ = try await client.fetchWanted(limit: 10)
            XCTFail("expected sendNotAdmitted")
        } catch let error as PhotosLibraryTransportError {
            XCTAssertEqual(error, .sendNotAdmitted)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDefaultBuildFlagEnablesPhotosLibrary() {
        #if !SOLSTONE_PHOTOS_LIBRARY
        XCTFail("SOLSTONE_PHOTOS_LIBRARY must be ON by default on main")
        #endif
    }

    func testForegroundAnnouncesCapableDeviceBeforeReadingDashboardState() async {
        let media = FakeMedia()
        media.accessState = .notDetermined
        let transport = FakeTransport()
        transport.capabilityListed = true
        transport.dashboardSummary = PhotosJournalDashboardSummary(
            state: "ready_to_set_up",
            substate: "never_set_up",
            attentionReason: nil,
            choice: .init(range: nil, canWiden: true),
            progress: .init(chosenTotal: 0, arrived: 0, inJournal: 0, waitingOnPhone: 0),
            scan: .init(itemsChecked: 0, itemsTotal: 0, paused: false)
        )
        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport,
            deviceNameProvider: { "Test iPad" },
            deviceKind: "ipad"
        )
        engine.isPaired = { true }

        await engine.foreground()
        XCTAssertEqual(engine.capability, .listed)
        XCTAssertFalse(engine.document.enabled)
        XCTAssertEqual(transport.statuses.count, 1)
        XCTAssertEqual(transport.statuses[0].deviceKind, "ipad")
        XCTAssertEqual(transport.statuses[0].sourceEnabled, false)
        XCTAssertEqual(transport.dashboardFetchCount, 1)
        XCTAssertEqual(transport.scanStarts.count, 0)
    }

    func testOldJournal404AndMissingCapabilityHandleCleanlyWithoutBrokenState() async {
        let media = FakeMedia()
        media.accessState = .notDetermined
        let transport = FakeTransport()
        transport.capabilityListed = false
        transport.dashboardResultOverride = .notFound
        transport.statusError = PhotosLibraryTransportError.httpStatus(404)

        let engine = PhotosLibraryEngine(
            media: media,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport,
            deviceNameProvider: { "Test iPhone" }
        )
        engine.isPaired = { true }

        // 1. Foreground against an old journal sets .notListed without touching /status, /state, or /scan.
        await engine.foreground()
        XCTAssertEqual(engine.capability, .notListed)
        XCTAssertNil(engine.journalSummary)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(transport.statuses.count, 0)
        XCTAssertEqual(transport.dashboardFetchCount, 0)
        XCTAssertEqual(transport.scanStarts.count, 0)

        // 2. Tile & page stay calm: readyToSetUp, no scanning wedge, no turn-on/open-journal buttons, waiting-for-update copy.
        let view = engine.viewState()
        XCTAssertEqual(view.sourceState, .readyToSetUp)
        XCTAssertFalse(view.showsTileSubtext)
        XCTAssertNil(view.tileSubtext)
        XCTAssertEqual(view.tileControl, .none)
        XCTAssertEqual(view.primaryAction, .none)
        XCTAssertFalse(view.showsAlreadyGrantedLine)
        XCTAssertFalse(view.showsOpenJournalDoor)
        XCTAssertTrue(view.showsWaitingForJournalUpdate)

        // 3. Attempting enableAndScan on an old journal refuses cleanly before flipping document.enabled.
        let started = await engine.enableAndScan()
        XCTAssertFalse(started)
        XCTAssertFalse(engine.document.enabled)
        XCTAssertFalse(engine.document.everEnabled)
        XCTAssertEqual(engine.viewState().sourceState, .readyToSetUp)
        XCTAssertEqual(engine.viewState().primaryAction, .none)
        XCTAssertTrue(engine.viewState().showsWaitingForJournalUpdate)

        // 4. Mid-flight HTTP 404 on /status transitions cleanly to .notListed with no error state.
        transport.capabilityListed = true
        await engine.foreground()
        XCTAssertEqual(engine.capability, .notListed)
        XCTAssertNil(engine.journalSummary)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.viewState().primaryAction, .none)
        XCTAssertFalse(engine.viewState().showsOpenJournalDoor)
        XCTAssertTrue(engine.viewState().showsWaitingForJournalUpdate)
    }

    /// Real PhotoKit simulator proof, skipped unless `PHOTOS_LIBRARY_LIVE_SIM_TEST=1`
    /// is passed by the test harness after granting simulator Photos access and seeding
    /// test media. Exercises the concrete `ScreenshotsPhotoKit` + `PhotosLibraryEngine`
    /// path end-to-end: full-access check, smart-album catalog excluding Hidden,
    /// metadata-only scan, 512 px upright JPEG export, and `.gone` for missing assets.
    func testRealPhotoKitMetadataScanAnd512pxExport() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PHOTOS_LIBRARY_LIVE_SIM_TEST"] == "1",
            "Live simulator PhotoKit test runs only when PHOTOS_LIBRARY_LIVE_SIM_TEST=1"
        )
        let photoKit = ScreenshotsPhotoKit()
        XCTAssertEqual(photoKit.photosAccess(), .full, "simulator harness must grant Full Access")

        let catalog = try await photoKit.fetchSmartAlbumCatalog()
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertFalse(
            catalog.contains { $0.subtype == PHAssetCollectionSubtype.smartAlbumAllHidden.rawValue },
            "Hidden smart album must never appear in catalog"
        )

        let transport = FakeTransport()
        let engine = PhotosLibraryEngine(
            media: photoKit,
            store: PhotosLibraryStore(fileURL: self.tempStoreURL()),
            transport: transport,
            deviceNameProvider: { "Simulator Test iPhone" },
            deviceKind: "iphone"
        )
        engine.isPaired = { true }

        let started = await engine.enableAndScan()
        XCTAssertTrue(started)
        XCTAssertEqual(transport.scanStarts.count, 1)
        XCTAssertEqual(transport.scanFinishes.count, 1)
        let scannedRows = transport.scanBatches.flatMap(\.rows)
        XCTAssertGreaterThanOrEqual(scannedRows.count, 2, "expected seeded test photos in simulator library")
        XCTAssertTrue(scannedRows.allSatisfy { !$0.hidden }, "scan must never include hidden assets")

        let firstPhoto = try XCTUnwrap(scannedRows.first { $0.mediaType == "photo" && !$0.screenshot })
        transport.wantedQueue = [
            PhotosWantedResponse(
                paused: false,
                range: "all",
                wanted: [
                    PhotosWantedItem(
                        assetID: firstPhoto.id,
                        cloudID: firstPhoto.cloudId,
                        maxEdge: 512,
                        capturedAt: firstPhoto.capturedAt,
                        reasonKind: "keep"
                    ),
                    PhotosWantedItem(
                        assetID: "MISSING-ASSET-ID/L0/001",
                        cloudID: nil,
                        maxEdge: 512,
                        capturedAt: nil,
                        reasonKind: "keep"
                    ),
                ],
                remaining: 0
            )
        ]

        let handled = await engine.pollAndDeliverWantedCopies()
        XCTAssertEqual(handled, 2)
        XCTAssertEqual(transport.copyUploads.count, 2)

        let delivered = try XCTUnwrap(transport.copyUploads.first { $0.assetID == firstPhoto.id })
        XCTAssertEqual(delivered.status, "ok")
        let jpegB64 = try XCTUnwrap(delivered.jpegBase64)
        let jpegData = try XCTUnwrap(Data(base64Encoded: jpegB64))
        XCTAssertGreaterThan(jpegData.count, 100)
        XCTAssertEqual(jpegData[0], 0xFF)
        XCTAssertEqual(jpegData[1], 0xD8)
        let image = try XCTUnwrap(UIImage(data: jpegData))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 512.0 + 1.0)
        XCTAssertGreaterThanOrEqual(max(image.size.width, image.size.height), 510.0)

        let gone = try XCTUnwrap(transport.copyUploads.first { $0.assetID == "MISSING-ASSET-ID/L0/001" })
        XCTAssertEqual(gone.status, "gone")
        XCTAssertNil(gone.jpegBase64)
    }

    func testViewStateCoversAllSetupActivePausedOffAndAttentionStates() {
        let baseDoc = PhotosLibraryDocument()

        // Unpaired -> ready to set up with unpaired reason and no primary action.
        let unpaired = PhotosLibraryViewState.resolve(
            paired: false, access: .notDetermined, capability: .unknown, document: baseDoc,
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(unpaired.sourceState, .readyToSetUp)
        XCTAssertEqual(unpaired.primaryAction, .none)
        XCTAssertNotNil(unpaired.pageReason)
        XCTAssertEqual(unpaired.tileControl, .none)

        // Paired, not determined -> turn on photos primary action, no already-granted line.
        let fresh = PhotosLibraryViewState.resolve(
            paired: true, access: .notDetermined, capability: .listed, document: baseDoc,
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(fresh.sourceState, .readyToSetUp)
        XCTAssertEqual(fresh.primaryAction, .turnOn)
        XCTAssertFalse(fresh.showsAlreadyGrantedLine)

        // Paired, full access already granted -> factual line + scan your library.
        let alreadyGranted = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: baseDoc,
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(alreadyGranted.sourceState, .readyToSetUp)
        XCTAssertEqual(alreadyGranted.primaryAction, .scanLibrary)
        XCTAssertTrue(alreadyGranted.showsAlreadyGrantedLine)

        // Scanning -> setting up, no toggle, progress subline.
        let scanningDoc = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: false)
        let scanning = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: scanningDoc,
            isScanning: true, scanChecked: 1_200, scanTotal: 4_500, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(scanning.sourceState, .enrolling)
        XCTAssertEqual(scanning.tileControl, .none)
        XCTAssertNotNil(scanning.pageSubline)
        XCTAssertEqual(scanning.primaryAction, .none)

        // Scan finished, awaiting journal choice -> setting up + chooseInJournal button.
        let scannedDoc = PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: true)
        let chooseJournal = PhotosJournalDashboardSummary(
            state: "setting_up", substate: "choose", attentionReason: nil,
            choice: .init(range: nil, canWiden: true),
            progress: .init(chosenTotal: 0, arrived: 0, inJournal: 0, waitingOnPhone: 0),
            scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
        )
        let choose = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: chooseJournal, lastPromptResult: nil
        )
        XCTAssertEqual(choose.sourceState, .enrolling)
        XCTAssertEqual(choose.primaryAction, .chooseInJournal)
        XCTAssertFalse(choose.showsPauseResume)

        // Bringing in -> active with toggle, pause/resume, and open-journal door.
        let bringingJournal = PhotosJournalDashboardSummary(
            state: "on", substate: "bringing_in", attentionReason: nil,
            choice: .init(range: "1y", canWiden: true),
            progress: .init(chosenTotal: 240, arrived: 80, inJournal: 80, waitingOnPhone: 160),
            scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
        )
        let bringing = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: bringingJournal, lastPromptResult: nil
        )
        XCTAssertEqual(bringing.sourceState, .active)
        XCTAssertEqual(bringing.tileControl, .toggle)
        XCTAssertTrue(bringing.showsPauseResume)
        XCTAssertTrue(bringing.showsOpenJournalDoor)
        XCTAssertFalse(bringing.isPaused)

        // Steady (canWiden vs all) -> active with steady line & open-journal door.
        let steadyWidenJournal = PhotosJournalDashboardSummary(
            state: "on", substate: "steady", attentionReason: nil,
            choice: .init(range: "1y", canWiden: true),
            progress: .init(chosenTotal: 240, arrived: 240, inJournal: 235, waitingOnPhone: 0),
            scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
        )
        let steadyAllJournal = PhotosJournalDashboardSummary(
            state: "on", substate: "steady", attentionReason: nil,
            choice: .init(range: "all", canWiden: false),
            progress: .init(chosenTotal: 900, arrived: 900, inJournal: 900, waitingOnPhone: 0),
            scan: .init(itemsChecked: 4_500, itemsTotal: 4_500, paused: false)
        )
        let steadyWiden = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: steadyWidenJournal, lastPromptResult: nil
        )
        let steadyAll = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: steadyAllJournal, lastPromptResult: nil
        )
        XCTAssertEqual(steadyWiden.sourceState, .active)
        XCTAssertEqual(steadyAll.sourceState, .active)
        XCTAssertNotEqual(steadyWiden.pageSubline, steadyAll.pageSubline)

        // Paused -> paused with toggle and resume control.
        var pausedDoc = scannedDoc
        pausedDoc.paused = true
        let paused = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: pausedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: bringingJournal, lastPromptResult: nil
        )
        XCTAssertEqual(paused.sourceState, .paused)
        XCTAssertEqual(paused.tileControl, .toggle)
        XCTAssertTrue(paused.isPaused)
        XCTAssertTrue(paused.showsOpenJournalDoor)

        // Turned off in journal -> off with journal door and re-entry scan action.
        let offJournal = PhotosJournalDashboardSummary(
            state: "off", substate: "off", attentionReason: nil,
            choice: .init(range: nil, canWiden: true),
            progress: .init(chosenTotal: 0, arrived: 0, inJournal: 235, waitingOnPhone: 0),
            scan: .init(itemsChecked: 0, itemsTotal: 0, paused: false)
        )
        let off = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .listed, document: PhotosLibraryDocument(everEnabled: true),
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: offJournal, lastPromptResult: nil
        )
        XCTAssertEqual(off.sourceState, .off)
        XCTAssertEqual(off.primaryAction, .scanLibrary)
        XCTAssertTrue(off.showsOpenJournalDoor)

        // Limited / denied after being on -> needs attention + openSettings.
        let limitedLater = PhotosLibraryViewState.resolve(
            paired: true, access: .limited, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: steadyWidenJournal, lastPromptResult: nil
        )
        XCTAssertEqual(limitedLater.sourceState, .needsAttention)
        XCTAssertEqual(limitedLater.primaryAction, .openSettings)
        XCTAssertEqual(limitedLater.tileControl, .none)

        let revokedLater = PhotosLibraryViewState.resolve(
            paired: true, access: .denied, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: steadyWidenJournal, lastPromptResult: nil
        )
        XCTAssertEqual(revokedLater.sourceState, .needsAttention)
        XCTAssertEqual(revokedLater.primaryAction, .openSettings)
        XCTAssertNotEqual(limitedLater.pageReason, revokedLater.pageReason)

        let restrictedLater = PhotosLibraryViewState.resolve(
            paired: true, access: .restricted, capability: .listed, document: scannedDoc,
            isScanning: false, scanChecked: 4_500, scanTotal: 4_500, journal: steadyWidenJournal, lastPromptResult: nil
        )
        XCTAssertEqual(restrictedLater.sourceState, .needsAttention)
        XCTAssertEqual(restrictedLater.primaryAction, .none)
        XCTAssertEqual(restrictedLater.pageReason, PhotosVocabulary.restricted)
        XCTAssertEqual(restrictedLater.tileSubtext, PhotosVocabulary.restricted)

        // Journal too old -> waitingForJournalUpdate flag set across ready, scanning, choose, and active states;
        // no turn-on/scan/choose/open-journal buttons offered.
        let oldJournalFresh = PhotosLibraryViewState.resolve(
            paired: true, access: .notDetermined, capability: .notListed, document: baseDoc,
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(oldJournalFresh.sourceState, .readyToSetUp)
        XCTAssertEqual(oldJournalFresh.primaryAction, .none)
        XCTAssertFalse(oldJournalFresh.showsOpenJournalDoor)
        XCTAssertTrue(oldJournalFresh.showsWaitingForJournalUpdate)

        let oldJournalGranted = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .notListed, document: baseDoc,
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(oldJournalGranted.sourceState, .readyToSetUp)
        XCTAssertEqual(oldJournalGranted.primaryAction, .none)
        XCTAssertFalse(oldJournalGranted.showsAlreadyGrantedLine)
        XCTAssertFalse(oldJournalGranted.showsOpenJournalDoor)
        XCTAssertTrue(oldJournalGranted.showsWaitingForJournalUpdate)

        let oldJournal = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .notListed, document: scannedDoc,
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertEqual(oldJournal.sourceState, .readyToSetUp)
        XCTAssertEqual(oldJournal.primaryAction, .none)
        XCTAssertFalse(oldJournal.showsOpenJournalDoor)
        XCTAssertTrue(oldJournal.showsWaitingForJournalUpdate)

        let oldJournalActive = PhotosLibraryViewState.resolve(
            paired: true, access: .full, capability: .notListed,
            document: PhotosLibraryDocument(everEnabled: true, enabled: true, paused: false, scanComplete: true, sentCount: 5),
            isScanning: false, scanChecked: 0, scanTotal: 0, journal: nil, lastPromptResult: nil
        )
        XCTAssertFalse(oldJournalActive.showsOpenJournalDoor)
        XCTAssertTrue(oldJournalActive.showsWaitingForJournalUpdate)
    }

    func testSourceIntakeRecordsLibraryPhotosOncePerAssetID() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SourceIntakeStore(containerRoot: dir)
        let t1 = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(store.recordPhoto(assetID: "asset-1", now: t1), .recorded)
        XCTAssertEqual(store.recordPhoto(assetID: "asset-1", now: t1.addingTimeInterval(60)), .unchanged)
        XCTAssertEqual(store.recordPhoto(assetID: "asset-2", now: t1.addingTimeInterval(120)), .recorded)

        guard case .ready(let snapshot) = store.load() else {
            return XCTFail("expected readable intake snapshot")
        }
        XCTAssertEqual(snapshot.photos.total, 2)
        XCTAssertNotNil(snapshot.photos.last)
    }
}
