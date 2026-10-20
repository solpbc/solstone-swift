// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The library import runs a fake library through the real share-route coordinator and store,
/// so each photo it brings in lands exactly as a picked photo does.
nonisolated final class PhotoLibraryImportTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraryImportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    // MARK: the import

    @MainActor
    func testAnImportBringsInExactlyThePhotosShownAndMarksThemFromPhotos() async throws {
        let harness = self.makeHarness(assets: ["a", "b", "c", "d"])
        let preview = harness.importer.preview(harness.scope)
        XCTAssertEqual(preview.assetIDs, ["a", "b", "c", "d"])
        XCTAssertEqual(preview.alreadyIn, 0)

        harness.importer.start(harness.scope, assetIDs: preview.assetIDs)
        await harness.importer.waitForRun()

        let batch = try XCTUnwrap(harness.importer.latest)
        XCTAssertEqual(batch.state, .finished)
        XCTAssertEqual(batch.broughtIn, 4)
        XCTAssertEqual(harness.queue.pendingCount, 4)
        for itemID in batch.itemIDs.values {
            let row = try self.pendingRow(itemID: itemID, queueRoot: harness.queueRoot)
            XCTAssertEqual(row["origin_app"] as? String, ShareImportOrigin.photos)
            XCTAssertEqual(row["source"] as? String, "image")
        }
        XCTAssertEqual(harness.library.exported, ["a", "b", "c", "d"], "nothing is read past what the owner was shown")
    }

    @MainActor
    func testAPhotoTakenAfterTheImportStartsIsNeverAdded() async throws {
        let harness = self.makeHarness(assets: ["a", "b"])
        let shown = harness.importer.preview(harness.scope).assetIDs
        harness.library.assets.append("c")

        harness.importer.start(harness.scope, assetIDs: shown)
        await harness.importer.waitForRun()

        XCTAssertEqual(harness.importer.latest?.broughtIn, 2)
        XCTAssertFalse(harness.library.exported.contains("c"))
    }

    @MainActor
    func testALaterImportLeavesOutWhatAlreadyCameIn() async throws {
        let harness = self.makeHarness(assets: ["a", "b"])
        harness.importer.start(harness.scope, assetIDs: ["a", "b"])
        await harness.importer.waitForRun()
        harness.library.assets.append("c")

        let reopened = self.makeImporter(harness: harness)
        let preview = reopened.preview(harness.scope)
        XCTAssertEqual(preview.assetIDs, ["c"])
        XCTAssertEqual(preview.alreadyIn, 2)
    }

    @MainActor
    func testTheImportWaitsWhenItsPhotosCannotReachTheJournal() async throws {
        let harness = self.makeHarness(assets: ["a", "b", "c", "d", "e"], settles: false)
        harness.importer.start(harness.scope, assetIDs: harness.library.assets)

        try await self.waitUntil { harness.importer.isWaitingForJournal }
        XCTAssertEqual(harness.importer.latest?.broughtIn, PhotoLibraryImporter.window)
        XCTAssertEqual(harness.importer.latest?.state, .running)

        harness.importer.pause()
        await harness.importer.waitForRun()
        XCTAssertEqual(harness.importer.latest?.state, .paused)
        XCTAssertEqual(harness.importer.latest?.remaining, 2)
        XCTAssertFalse(harness.importer.isWaitingForJournal)
    }

    @MainActor
    func testPauseHoldsAndResumeBringsInTheRest() async throws {
        let harness = self.makeHarness(assets: ["a", "b", "c", "d"])
        harness.library.onExport = { assetID in
            if assetID == "b" { harness.importer.pause() }
        }
        harness.importer.start(harness.scope, assetIDs: harness.library.assets)
        await harness.importer.waitForRun()

        let paused = try XCTUnwrap(harness.importer.latest)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.broughtIn, 2, "the photo being copied when the owner paused still counts")
        XCTAssertEqual(harness.library.exported, ["a", "b"])

        harness.library.onExport = nil
        harness.importer.resume()
        await harness.importer.waitForRun()
        XCTAssertEqual(harness.importer.latest?.state, .finished)
        XCTAssertEqual(harness.importer.latest?.broughtIn, 4)
    }

    @MainActor
    func testAPauseDuringTheLastPhotoFinishesTheImport() async throws {
        let harness = self.makeHarness(assets: ["a", "b"])
        harness.library.onExport = { assetID in
            if assetID == "b" { harness.importer.pause() }
        }
        harness.importer.start(harness.scope, assetIDs: harness.library.assets)
        await harness.importer.waitForRun()

        XCTAssertEqual(harness.importer.latest?.state, .finished)
        XCTAssertEqual(harness.importer.latest?.broughtIn, 2)
        XCTAssertNotNil(harness.importer.latest?.endedAt)
    }

    @MainActor
    func testStopEndsTheImportAndLeavesTheRestInTheLibrary() async throws {
        let harness = self.makeHarness(assets: ["a", "b", "c"])
        harness.library.onExport = { _ in harness.importer.pause() }
        harness.importer.start(harness.scope, assetIDs: harness.library.assets)
        await harness.importer.waitForRun()

        harness.importer.stop()
        let stopped = try XCTUnwrap(harness.importer.latest)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNotNil(stopped.endedAt)
        XCTAssertEqual(stopped.broughtIn, 1)
        XCTAssertEqual(stopped.remaining, 2)

        harness.importer.resume()
        XCTAssertEqual(harness.importer.latest?.state, .stopped, "a stopped import does not resume")
        XCTAssertEqual(harness.library.exported, ["a"])
    }

    @MainActor
    func testLosingPhotoAccessPausesAndRestoringItCarriesOn() async throws {
        let harness = self.makeHarness(assets: ["a", "b", "c"])
        harness.library.onExport = { assetID in
            if assetID == "a" { harness.library.currentAccess = .off }
        }
        harness.importer.start(harness.scope, assetIDs: harness.library.assets)
        await harness.importer.waitForRun()

        XCTAssertEqual(harness.importer.latest?.state, .pausedForAccess)
        XCTAssertEqual(harness.importer.latest?.broughtIn, 1)
        harness.importer.resume()
        XCTAssertEqual(harness.importer.latest?.state, .pausedForAccess, "resume cannot read without access")

        harness.library.onExport = nil
        harness.library.currentAccess = .selected
        harness.importer.refreshAccess()
        await harness.importer.waitForRun()
        XCTAssertEqual(harness.importer.latest?.state, .finished)
        XCTAssertEqual(harness.importer.latest?.broughtIn, 3)
    }

    @MainActor
    func testARunningImportCarriesOnAfterTheAppCloses() async throws {
        let harness = self.makeHarness(assets: ["a", "b", "c"])
        // The record a closed app left behind: one photo in, the import still running.
        let record = PhotoLibraryImportStore(fileURL: harness.recordURL)
        record.save(PhotoLibraryBatch(
            id: UUID(), scope: harness.scope, assetIDs: ["a", "b", "c"], next: 1,
            itemIDs: ["a": "00000000-0000-0000-0000-00000000000a"], unreadable: [],
            state: .running, startedAt: Date(), endedAt: nil
        ))

        let relaunched = self.makeImporter(harness: harness)
        XCTAssertEqual(relaunched.latest?.state, .running)
        relaunched.resumeIfRunning()
        await relaunched.waitForRun()

        XCTAssertEqual(relaunched.latest?.state, .finished)
        XCTAssertEqual(relaunched.latest?.broughtIn, 3)
        XCTAssertEqual(harness.library.exported, ["b", "c"], "it carries on from where it was, never from the start")
    }

    @MainActor
    func testAPhotoTheLibraryCannotHandOverIsCountedAndSkipped() async throws {
        let harness = self.makeHarness(assets: ["a", "gone", "c"])
        harness.library.missing = ["gone"]
        harness.importer.start(harness.scope, assetIDs: harness.library.assets)
        await harness.importer.waitForRun()

        let batch = try XCTUnwrap(harness.importer.latest)
        XCTAssertEqual(batch.state, .finished)
        XCTAssertEqual(batch.broughtIn, 2)
        XCTAssertEqual(batch.unreadable, ["gone"])
    }

    @MainActor
    func testAChangedSelectionBumpsTheLibraryRevision() {
        let harness = self.makeHarness(assets: [])
        XCTAssertEqual(harness.importer.libraryRevision, 0)
        harness.library.assets = ["a"]
        harness.library.onChange?()
        XCTAssertEqual(harness.importer.libraryRevision, 1)
        XCTAssertEqual(harness.importer.preview(harness.scope).assetIDs, ["a"])
    }

    @MainActor
    func testNothingStartsWithoutPhotosOrWhileAnImportIsOpen() async throws {
        let harness = self.makeHarness(assets: ["a", "b"])
        harness.importer.start(harness.scope, assetIDs: [])
        XCTAssertNil(harness.importer.latest)

        harness.library.onExport = { _ in harness.importer.pause() }
        harness.importer.start(harness.scope, assetIDs: ["a", "b"])
        await harness.importer.waitForRun()
        let open = try XCTUnwrap(harness.importer.latest)
        harness.importer.start(harness.scope, assetIDs: ["b"])
        XCTAssertEqual(harness.importer.latest?.id, open.id)
    }

    // MARK: provenance

    @MainActor
    func testPickedPhotosCarryPhotosAndOtherImportsDoNot() async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let png = self.tempDirectory.appendingPathComponent("pick.png")
        try Self.onePixelPNG.write(to: png)

        let picked = await InAppImport.accept(
            itemProviders: [try XCTUnwrap(NSItemProvider(contentsOf: png))],
            queue: store,
            originApp: ShareImportOrigin.photos
        )
        let dropped = await InAppImport.accept(itemProviders: [try XCTUnwrap(NSItemProvider(contentsOf: png))], queue: store)

        guard case .success(let pickedID) = picked.first, case .success(let droppedID) = dropped.first else {
            return XCTFail("expected both to land")
        }
        XCTAssertEqual(try self.pendingRow(itemID: ShareImportStore.itemIDString(pickedID), queueRoot: queueRoot)["origin_app"] as? String, "Photos")
        XCTAssertTrue(try self.pendingRow(itemID: ShareImportStore.itemIDString(droppedID), queueRoot: queueRoot)["origin_app"] is NSNull)
    }

    func testTheJournalDoorIsMobilePhotosOnlyForPhotos() {
        XCTAssertEqual(ShareImportOrigin.importedVia(originApp: "Photos"), "mobile_photos")
        XCTAssertEqual(ShareImportOrigin.importedVia(originApp: nil), "mobile_share")
        XCTAssertEqual(ShareImportOrigin.importedVia(originApp: "Mail"), "mobile_share")
    }

    @MainActor
    func testTheSaveBodyNamesTheDoorFromTheItemsOrigin() throws {
        let photos = try self.saveBody(originApp: ShareImportOrigin.photos)
        XCTAssertTrue(photos.contains("name=\"imported_via\"\r\n\r\nmobile_photos\r\n"))
        let share = try self.saveBody(originApp: nil)
        XCTAssertTrue(share.contains("name=\"imported_via\"\r\n\r\nmobile_share\r\n"))
        XCTAssertFalse(share.contains("mobile_photos"))
    }

    // MARK: processing status and the date stamp

    func testProcessingStatusReadsTheJournalsImportDetail() {
        func parse(_ json: String) -> PhotoProcessingStatus? {
            PhotoProcessingStatus.parse(Data(json.utf8))
        }
        XCTAssertEqual(parse(#"{"status":"pending"}"#), .processing)
        XCTAssertEqual(parse(#"{"status":"running"}"#), .processing)
        XCTAssertEqual(parse(#"{"status":"success","unavailable_description":null}"#), .described)
        XCTAssertEqual(parse(#"{"status":"success"}"#), .described)
        XCTAssertEqual(parse(#"{"status":"success","unavailable_description":"no model"}"#), .notDescribed)
        XCTAssertEqual(parse(#"{"status":"failed","error":"x"}"#), .failed)
        XCTAssertNil(parse(#"{"status":"unconfirmed"}"#), "an unknown status is not guessed")
        XCTAssertNil(parse("not json"))
    }

    func testAPhotoWithoutACaptureTimeGetsTheDatePhotosHolds() throws {
        let url = self.tempDirectory.appendingPathComponent("screenshot.png")
        try Self.onePixelPNG.write(to: url)
        let created = Date(timeIntervalSince1970: 1_781_000_000)
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))

        PhotoLibraryDateStamp.ensureCreationDate(fileURL: url, created: created, timeZone: zone)

        let exif = try self.exif(at: url)
        let expected = PhotoLibraryDateStamp.exifStrings(for: created, timeZone: zone)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, expected.dateTime)
        XCTAssertEqual(expected.offset, "-06:00")
    }

    func testAPhotoThatHasACaptureTimeKeepsIt() throws {
        let url = self.tempDirectory.appendingPathComponent("camera.png")
        try Self.onePixelPNG.write(to: url)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        PhotoLibraryDateStamp.ensureCreationDate(fileURL: url, created: first, timeZone: .gmt)
        let stamped = try Data(contentsOf: url)

        PhotoLibraryDateStamp.ensureCreationDate(fileURL: url, created: Date(), timeZone: .gmt)

        XCTAssertEqual(try Data(contentsOf: url), stamped)
    }

    func testTheExportedNameFollowsTheBytesHandedOver() {
        XCTAssertEqual(PhotoLibraryFilename.name(original: "IMG_0001.HEIC", dataUTI: UTType.heic.identifier), "IMG_0001.heic")
        XCTAssertEqual(PhotoLibraryFilename.name(original: "IMG_0001.HEIC", dataUTI: UTType.jpeg.identifier), "IMG_0001.jpeg")
        XCTAssertEqual(PhotoLibraryFilename.name(original: nil, dataUTI: UTType.png.identifier), "photo.png")
    }

    func testADayRangeCoversBothDaysEndToEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let june1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 15)))
        let june3 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9)))
        let scope = PhotoLibraryScope.days(album: .all, from: june3, to: june1, calendar: calendar)
        XCTAssertEqual(scope.from, calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        XCTAssertEqual(scope.to, calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 23, minute: 59, second: 59)))
    }

    func testRecentListsOnlyPhotosNewestFirst() {
        let ledger: [String: ShareImportStore.LedgerEntry] = [
            "p1": ShareImportStore.LedgerEntry(
                itemID: "p1", basis: "file", contentType: "public.png", targetJournal: "",
                serverPath: "/x", serverTimestamp: "20261020_101500", deliveredAt: Date(timeIntervalSince1970: 2),
                filename: "a.png", originApp: "Photos", itemTime: nil
            ),
        ]
        let items = [
            self.item(id: "p1", origin: "Photos", state: .inYourJournal, time: 2),
            self.item(id: "s1", origin: nil, state: .savedOnThisPhone, time: 3),
            self.item(id: "p2", origin: "Photos", state: .savedOnThisPhone, time: 4),
        ]
        let recent = PhotoContribution.recent(items: items, ledger: ledger)
        XCTAssertEqual(recent.map(\.id), ["p2", "p1"])
        XCTAssertEqual(recent.last?.importID, "20261020_101500")
        XCTAssertNil(recent.first?.importID, "a photo still on this device has no journal import yet")
    }

    func testRecentStatusWordsFollowTheJournal() {
        var contribution = PhotoContribution(id: "p", filename: nil, itemTime: nil, sendState: .inYourJournal, importID: "x", processing: nil)
        XCTAssertEqual(PhotoLibraryVocabulary.status(for: contribution), "saved to your journal")
        contribution.processing = .processing
        XCTAssertEqual(PhotoLibraryVocabulary.status(for: contribution), "in your journal · being described")
        contribution.processing = .notDescribed
        XCTAssertEqual(PhotoLibraryVocabulary.status(for: contribution), "in your journal · saved without a description")
        let waiting = PhotoContribution(id: "q", filename: nil, itemTime: nil, sendState: .savedOnThisPhone, importID: nil, processing: nil)
        XCTAssertEqual(PhotoLibraryVocabulary.status(for: waiting), "on this device")
    }

    // MARK: harness

    @MainActor
    private final class Harness {
        let library: FakePhotoLibrary
        let queue: ShareImportStore
        let queueRoot: URL
        let recordURL: URL
        let scope = PhotoLibraryScope.days(album: .all, from: Date(timeIntervalSince1970: 0), to: Date())
        var settles: Bool
        var importer: PhotoLibraryImporter!

        init(library: FakePhotoLibrary, queue: ShareImportStore, queueRoot: URL, recordURL: URL, settles: Bool) {
            self.library = library
            self.queue = queue
            self.queueRoot = queueRoot
            self.recordURL = recordURL
            self.settles = settles
        }
    }

    @MainActor
    private func makeHarness(assets: [String], settles: Bool = true) -> Harness {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let harness = Harness(
            library: FakePhotoLibrary(assets: assets),
            queue: ShareImportStore(cacheRootURL: queueRoot),
            queueRoot: queueRoot,
            recordURL: self.tempDirectory.appendingPathComponent("photo-library.json"),
            settles: settles
        )
        harness.importer = self.makeImporter(harness: harness)
        return harness
    }

    @MainActor
    private func makeImporter(harness: Harness) -> PhotoLibraryImporter {
        PhotoLibraryImporter(
            library: harness.library,
            store: PhotoLibraryImportStore(fileURL: harness.recordURL),
            queue: harness.queue,
            exportDirectory: self.tempDirectory.appendingPathComponent("export", isDirectory: true),
            dependencies: PhotoLibraryImporter.Dependencies(
                unsettledItemIDs: { [weak harness] in
                    guard let harness, !harness.settles else { return [] }
                    let pending = (try? FileManager.default.contentsOfDirectory(atPath: harness.queueRoot.appendingPathComponent("pending").path)) ?? []
                    return Set(pending)
                },
                drain: {},
                sleep: { _ in await Task.yield() }
            )
        )
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition never held")
    }

    @MainActor
    private func pendingRow(itemID: String, queueRoot: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: queueRoot.appendingPathComponent("pending/\(itemID)/item.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func saveBody(originApp: String?) throws -> String {
        let itemID = UUID()
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent(itemID.uuidString, isDirectory: true))
        let fields = ShareImportTransferMetadata.Fields(
            basis: "file", contentType: "public.png", targetJournal: "", filename: "a.png",
            originApp: originApp, itemTime: nil, bytes: 4, requestSource: "image"
        )
        let manifest = TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Date(timeIntervalSince1970: 1_783_536_000),
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(partID: "file", kind: .file, relativePath: "raw.bin", filename: "image.png", contentType: "image/png"),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .saveThenStart, path: ImporterServerURL.savePath, startPath: ImporterServerURL.startPath),
            meta: ShareImportTransferMetadata.meta(fields: fields),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
        let staged = try spool.stage(manifest: manifest, payloads: ["file": Data("png!".utf8)])
        let item = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        guard case .written(let url, _) = try ShareImportSaveBody.build(item: item, spool: spool) else {
            XCTFail("expected a streamed body")
            return ""
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func exif(at url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    }

    private func item(id: String, origin: String?, state: OnThisPhoneSendState, time: TimeInterval) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id, sourceKind: .share, sendState: state, contentType: "public.png", filename: "\(id).png",
            bytes: nil, originApp: origin, basis: "file", itemTime: Date(timeIntervalSince1970: time),
            targetJournal: "", stream: nil, day: nil, segment: nil, deliveredAt: nil, rawFileURL: nil
        )
    }

    fileprivate static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!
}

@MainActor
private final class FakePhotoLibrary: PhotoLibraryProviding {
    var assets: [String]
    var currentAccess: PhotoLibraryAccess = .all
    var missing: Set<String> = []
    var exported: [String] = []
    var onExport: (@MainActor (String) -> Void)?
    var onChange: (@MainActor () -> Void)?

    init(assets: [String]) {
        self.assets = assets
    }

    func access() -> PhotoLibraryAccess { self.currentAccess }
    func requestAccess() async -> PhotoLibraryAccess { self.currentAccess }
    func albums() -> [PhotoLibraryAlbum] { [.all] }
    func assetIDs(in scope: PhotoLibraryScope) -> [String] { self.assets }

    func export(assetID: String, into directory: URL) async throws -> PhotoLibraryExport {
        guard !self.missing.contains(assetID) else { throw PhotoLibraryExportError.unavailable }
        self.exported.append(assetID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(assetID).png")
        try PhotoLibraryImportTests.onePixelPNG.write(to: url)
        self.onExport?(assetID)
        return PhotoLibraryExport(fileURL: url, filename: "\(assetID).png")
    }
}
