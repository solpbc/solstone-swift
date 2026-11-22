// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WebKit
import XCTest

@MainActor
final class ImportOXTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        self.tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportOXTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempRoot)
        self.tempRoot = nil
        super.tearDown()
    }

    // MARK: - 1. Strict ASCII Import ID Validation & Deep-Link Paths

    func testStrictASCIIImportIDValidation() {
        XCTAssertEqual(ShareImportID.validated("20261122_140500"), "20261122_140500")
        XCTAssertEqual(ShareImportID.detailPath(for: "20261122_140500"), "/app/import/20261122_140500")

        // Reject Unicode digits, traversal, slashes, query strings, wrong lengths, missing underscores
        let invalid = [
            "",
            "20261122_14050",
            "20261122_1405001",
            "20261122-140500",
            "../20261122_140500",
            "20261122_140500/foo",
            "20261122_140500?x=1",
            "20261122_140500#frag",
            "٢٠٢٦١١٢٢_١٤٠٥٠٠", // Arabic-Indic digits
            "20261122_14050a",
            " 20261122_140500",
        ]
        for candidate in invalid {
            XCTAssertNil(ShareImportID.validated(candidate), "must reject: \(candidate)")
            XCTAssertNil(ShareImportID.detailPath(for: candidate), "must not build path for: \(candidate)")
        }
    }

    func testOnThisPhoneItemDetailPresentationUsesImportDetailPathWhenValid() {
        let shareWithID = OnThisPhoneItem(
            id: UUID().uuidString.lowercased(),
            sourceKind: .share,
            sendState: .inYourJournal,
            contentType: "application/zip",
            filename: "export.zip",
            bytes: 100,
            originApp: nil,
            basis: "file",
            itemTime: Date(),
            targetJournal: "",
            stream: nil,
            day: "20261122",
            segment: nil,
            deliveredAt: Date(),
            rawFileURL: nil,
            importID: "20261122_140500"
        )
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.journalPath(for: shareWithID), "/app/import/20261122_140500")

        let shareWithInvalidID = OnThisPhoneItem(
            id: UUID().uuidString.lowercased(),
            sourceKind: .share,
            sendState: .inYourJournal,
            contentType: "application/zip",
            filename: "export.zip",
            bytes: 100,
            originApp: nil,
            basis: "file",
            itemTime: Date(),
            targetJournal: "",
            stream: nil,
            day: "20261122",
            segment: nil,
            deliveredAt: Date(),
            rawFileURL: nil,
            importID: "../bad"
        )
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.journalPath(for: shareWithInvalidID), "/")
    }

    // MARK: - 2. 409 import_preview_required Classification & Refusal Pacing

    func testClassify409ImportPreviewRequiredVariants() {
        let saveState = TransferSaveThenStartState(
            phase: .startPending,
            savedPath: "/imports/20261122_140500/export.zip",
            savedTimestamp: "20261122_140500",
            savedInstanceID: "journal-a"
        )

        // 1. body_confirmation_required -> .importReviewRequired
        let bodyBody = Data(#"{"reason_code":"import_preview_required","kind":"body_confirmation_required","import_id":"20261122_140500","error":"confirm body facet"}"#.utf8)
        let bodyOutcome = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 409, data: bodyBody),
            endpointPhase: .start(saveResult: saveState)
        )
        guard case .terminalAttention(.importReviewRequired(let kind, let importID, let detail)) = bodyOutcome else {
            return XCTFail("expected importReviewRequired, got \(bodyOutcome)")
        }
        XCTAssertEqual(kind, "body_confirmation_required")
        XCTAssertEqual(importID, "20261122_140500")
        XCTAssertEqual(detail, AppStrings.ios_app_importreviewdetailexpiry())

        // 2. confirmation_required (falling back to saveResult.savedTimestamp) -> .importReviewRequired
        let confirmBody = Data(#"{"reason_code":"import_preview_required","kind":"confirmation_required","error":"confirm import"}"#.utf8)
        let confirmOutcome = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 409, data: confirmBody),
            endpointPhase: .start(saveResult: saveState)
        )
        guard case .terminalAttention(.importReviewRequired(let confirmKind, let fallbackID, let confirmDetail)) = confirmOutcome else {
            return XCTFail("expected importReviewRequired with fallback timestamp, got \(confirmOutcome)")
        }
        XCTAssertEqual(confirmKind, "confirmation_required")
        XCTAssertEqual(fallbackID, "20261122_140500")
        XCTAssertEqual(confirmDetail, AppStrings.ios_app_importreviewdetail())

        // 3. Future *_confirmation_required suffix -> .importReviewRequired
        let futureBody = Data(#"{"reason_code":"import_preview_required","kind":"evernote_confirmation_required","import_id":"20261122_141000"}"#.utf8)
        let futureOutcome = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 409, data: futureBody),
            endpointPhase: .start(saveResult: saveState)
        )
        guard case .terminalAttention(.importReviewRequired(let futureKind, let futureID, _)) = futureOutcome else {
            return XCTFail("expected importReviewRequired for suffix kind, got \(futureOutcome)")
        }
        XCTAssertEqual(futureKind, "evernote_confirmation_required")
        XCTAssertEqual(futureID, "20261122_141000")

        // 4. All non-confirmation 409 kinds -> .importPreviewRefused (NEVER .importReviewRequired)
        let nonRetryableKinds = ["plan_failed", "nothing_to_import", "invalid_request", "not_found", "unknown_future_kind"]
        for nonRetryKind in nonRetryableKinds {
            let data = Data(#"{"reason_code":"import_preview_required","kind":"\#(nonRetryKind)","import_id":"20261122_140500","error":"cannot import"}"#.utf8)
            let outcome = TransferHTTPClassifier.classify(
                result: TransferHTTPResult(statusCode: 409, data: data),
                endpointPhase: .start(saveResult: saveState)
            )
            guard case .terminalAttention(.importPreviewRefused(409, let gotKind, _, _, let retryable)) = outcome else {
                return XCTFail("expected importPreviewRefused for \(nonRetryKind), got \(outcome)")
            }
            XCTAssertEqual(gotKind, nonRetryKind)
            XCTAssertFalse(retryable, "\(nonRetryKind) must be non-retryable")
            XCTAssertTrue(TransferRefusalPacing.isSettled(.importPreviewRefused(statusCode: 409, kind: nonRetryKind, importID: nil, detail: nil, retryable: false), phase: .start(saveResult: saveState)))
        }

        // 5. source_changed / already_running -> retryable manual attention, NEVER readyToReview
        for retryKind in ["source_changed", "already_running"] {
            let data = Data(#"{"reason_code":"import_preview_required","kind":"\#(retryKind)","error":"try again"}"#.utf8)
            let outcome = TransferHTTPClassifier.classify(
                result: TransferHTTPResult(statusCode: 409, data: data),
                endpointPhase: .start(saveResult: saveState)
            )
            guard case .terminalAttention(.importPreviewRefused(409, let gotKind, _, _, let retryable)) = outcome else {
                return XCTFail("expected importPreviewRefused for \(retryKind), got \(outcome)")
            }
            XCTAssertEqual(gotKind, retryKind)
            XCTAssertTrue(retryable, "\(retryKind) should allow manual retry")
        }

        // 6. Absent kind or invalid/Unicode import_id without valid fallback -> non-retryable attention (NEVER readyToReview)
        let noKindData = Data(#"{"reason_code":"import_preview_required","import_id":"20261122_140500"}"#.utf8)
        let noKindOutcome = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 409, data: noKindData),
            endpointPhase: .start(saveResult: saveState)
        )
        guard case .terminalAttention(.importPreviewRefused(409, nil, _, _, false)) = noKindOutcome else {
            return XCTFail("absent kind must never enter readyToReview, got \(noKindOutcome)")
        }

        let unicodeIDData = Data(#"{"reason_code":"import_preview_required","kind":"body_confirmation_required","import_id":"٢٠٢٦١١٢٢_١٤٠٥٠٠"}"#.utf8)
        let unicodeOutcome = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 409, data: unicodeIDData),
            endpointPhase: .start(saveResult: TransferSaveThenStartState(phase: .startPending, savedPath: "/p", savedTimestamp: "bad-ts"))
        )
        guard case .terminalAttention(.importPreviewRefused(409, "body_confirmation_required", nil, _, false)) = unicodeOutcome else {
            return XCTFail("invalid import_id must never enter readyToReview, got \(unicodeOutcome)")
        }
    }

    func testReadyToReviewAndPlanFailedNeverAutoRetryAndExcludeFromSendableTotals() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ShareImportStore(
            cacheRootURL: self.tempRoot.appendingPathComponent("ImportQueue", isDirectory: true),
            now: { baseDate }
        )
        let transfer = makeTransferCutoverHarness(
            rootURL: self.tempRoot.appendingPathComponent("Transfers", isDirectory: true),
            endpointResolver: TransferEndpointResolverStub(
                .available(TransferResolvedEndpoint(
                    baseURL: URL(string: "http://127.0.0.1:7071")!,
                    port: 7071,
                    dispatchOwner: TransferDispatchOwner(
                        pairingGeneration: 1,
                        ownerID: UUID(),
                        credentialCID: "cred-a",
                        journalInstanceID: "journal-a"
                    )
                ))
            ),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        let holder = ShareTransferHolder(transferEngine: transfer.engine, mirror: transfer.mirror, store: store)
        let mobileUploader = MobileSegmentUploader(
            transferEngine: transfer.engine,
            store: MobileSegmentStore(rootURL: self.tempRoot.appendingPathComponent("Mobile", isDirectory: true)),
            clock: MockObserverClock()
        )
        let mobileHolder = MobileSegmentTransferHolder(
            transferEngine: transfer.engine,
            mirror: transfer.mirror,
            uploader: mobileUploader
        )
        try await transfer.engine.start()
        await transfer.engine.pause()

        let spool = TransferSpool(rootURL: self.tempRoot.appendingPathComponent("Transfers", isDirectory: true))
        // Record the active pairing identity just as the live connection did before the 409 arrived.
        try spool.recordFollowedPairing("cred-a")
        let reviewID = UUID()
        let planFailedID = UUID()
        try await self.seedAttentionShare(
            engine: transfer.engine,
            spool: spool,
            itemID: reviewID,
            filename: "export.zip",
            instanceID: "journal-a",
            importID: "20261122_140500",
            reviewState: .readyToReview,
            kind: "body_confirmation_required",
            retryable: false,
            now: baseDate
        )
        try await self.seedAttentionShare(
            engine: transfer.engine,
            spool: spool,
            itemID: planFailedID,
            filename: "broken.zip",
            instanceID: "journal-a",
            importID: nil,
            reviewState: nil,
            kind: "plan_failed",
            retryable: false,
            now: baseDate
        )

        // Reload engine from disk to verify persisted state
        let transfer2 = makeTransferCutoverHarness(
            rootURL: self.tempRoot.appendingPathComponent("Transfers", isDirectory: true),
            endpointResolver: TransferEndpointResolverStub(.unavailable("paused")),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        let holder2 = ShareTransferHolder(transferEngine: transfer2.engine, mirror: transfer2.mirror, store: store)
        try await transfer2.engine.start()
        transfer2.mirror.apply(snapshot: await transfer2.engine.snapshot())

        XCTAssertEqual(holder2.readyToReviewCount, 1)
        XCTAssertEqual(holder2.failedCount, 1) // ONLY broken.zip, excludes readyToReview!
        XCTAssertEqual(holder2.refusalPacedCount, 1) // broken.zip is non-retryable / auto-retry suppressed!

        let sendable = sendableUploadTotals(
            mobileSegment: mobileHolder,
            watch: transfer2.watch,
            share: holder2
        )
        XCTAssertEqual(sendable.failed, 0, "readyToReview and non-retryable plan_failed must both be excluded from sendableUploadTotals")
        XCTAssertEqual(sendable.pending, 0)

        // Reconnect to the SAME journal / journal version bump / retryAttention must NEVER auto-retry either item!
        await transfer2.engine.noteNewConnectionEstablished(pairingIdentity: "cred-a")
        await transfer2.engine.noteJournalVersion("2.99.0")
        try await transfer2.engine.retryAttention()
        transfer2.mirror.apply(snapshot: await transfer2.engine.snapshot())

        XCTAssertEqual(holder2.pendingCount, 0, "neither readyToReview nor plan_failed may auto-retry on reconnect")
        XCTAssertEqual(holder2.readyToReviewCount, 1)
        XCTAssertEqual(holder2.failedCount, 1)

        // Re-pairing to a DIFFERENT journal resets both back to queued with savePending!
        await transfer2.engine.noteNewConnectionEstablished(pairingIdentity: "cred-b")
        transfer2.mirror.apply(snapshot: await transfer2.engine.snapshot())
        XCTAssertEqual(holder2.pendingCount, 2)
        XCTAssertEqual(holder2.readyToReviewCount, 0)
        let requeuedReview = await transfer2.engine.itemSnapshot(itemID: reviewID)
        XCTAssertEqual(requeuedReview?.manifest.saveThenStart?.phase, .savePending)
        XCTAssertNil(requeuedReview?.manifest.attention)
    }

    // MARK: - 3. Safe Reconciliation (GET /app/import/api/<id>), sendAgain & Pairing Change

    func testReconciliationConfirmedPersistsReceiptBeforeDeletingBytesAndHandlesAllOutcomes() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ShareImportStore(
            cacheRootURL: self.tempRoot.appendingPathComponent("ImportQueue", isDirectory: true),
            now: { baseDate }
        )
        let transferRoot = self.tempRoot.appendingPathComponent("Transfers", isDirectory: true)
        let spool = TransferSpool(rootURL: transferRoot)
        _ = try spool.initialize(now: baseDate)

        let confirmedID = UUID()
        let keepPendingID = UUID()
        let expiredID = UUID()
        let otherJournalID = UUID()

        try self.writeDirectAttentionShare(
            spool: spool,
            itemID: confirmedID,
            filename: "confirmed.zip",
            instanceID: "journal-a",
            importID: "20261122_140100",
            reviewState: .readyToReview,
            kind: "body_confirmation_required",
            retryable: false,
            now: baseDate
        )
        try self.writeDirectAttentionShare(
            spool: spool,
            itemID: keepPendingID,
            filename: "still-eligible.zip",
            instanceID: "journal-a",
            importID: "20261122_140200",
            reviewState: .readyToReview,
            kind: "body_confirmation_required",
            retryable: false,
            now: baseDate
        )
        try self.writeDirectAttentionShare(
            spool: spool,
            itemID: expiredID,
            filename: "expired.zip",
            instanceID: "journal-a",
            importID: "20261122_140300",
            reviewState: .readyToReview,
            kind: "body_confirmation_required",
            retryable: false,
            now: baseDate
        )
        try self.writeDirectAttentionShare(
            spool: spool,
            itemID: otherJournalID,
            filename: "journal-b.zip",
            instanceID: "journal-b",
            importID: "20261122_140400",
            reviewState: .readyToReview,
            kind: "body_confirmation_required",
            retryable: false,
            now: baseDate
        )

        let transfer = makeTransferCutoverHarness(
            rootURL: transferRoot,
            endpointResolver: TransferEndpointResolverStub(.unavailable("paused")),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        let holder = ShareTransferHolder(transferEngine: transfer.engine, mirror: transfer.mirror, store: store)
        try await transfer.engine.start()
        await transfer.engine.pause()
        transfer.mirror.apply(snapshot: await transfer.engine.snapshot())

        let queriedBox = LockedArray<String>()
        await holder.reconcileReadyToReview(
            localPort: 7071,
            instanceID: "journal-a",
            isPaired: true,
            markConfirmed: true,
            fetchStatus: { _, importID in
                queriedBox.append(importID)
                switch importID {
                case "20261122_140100":
                    return .ok(ImportStatusPollPayload(status: "running", savedStartActive: true, savedStartState: "consumed"))
                case "20261122_140200":
                    return .ok(ImportStatusPollPayload(status: "pending", savedStartActive: false, savedStartState: "unknown"))
                case "20261122_140300":
                    return .notFound
                default:
                    return .transientOrUnexpected(500)
                }
            }
        )
        transfer.mirror.apply(snapshot: await transfer.engine.snapshot())

        // Never queried journal-b's import_id against journal-a!
        XCTAssertFalse(queriedBox.values().contains("20261122_140400"))

        // 1. Confirmed item deleted local bytes and saved 24h recent receipt
        let confirmedSnap = await transfer.engine.itemSnapshot(itemID: confirmedID)
        XCTAssertNil(confirmedSnap)
        let receipts = holder.recentReceipts(instanceID: "journal-a", isPaired: true, markConfirmed: true, now: baseDate)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.filename, "confirmed.zip")
        XCTAssertEqual(receipts.first?.validatedImportID, "20261122_140100")

        // 2. Pending + unknown saved_start preserved local bytes and stayed .readyToReview
        let keptSnap = await transfer.engine.itemSnapshot(itemID: keepPendingID)
        let kept = try XCTUnwrap(keptSnap)
        XCTAssertEqual(kept.manifest.attention?.importReviewState, .readyToReview)
        let keptPayload = await transfer.engine.payloadFileURL(itemID: keepPendingID, partID: "file")
        XCTAssertNotNil(keptPayload)

        // 3. 404 marked .reviewExpired while preserving local bytes
        let expiredSnap = await transfer.engine.itemSnapshot(itemID: expiredID)
        let expired = try XCTUnwrap(expiredSnap)
        XCTAssertEqual(expired.manifest.attention?.importReviewState, .reviewExpired)
        let expiredPayload = await transfer.engine.payloadFileURL(itemID: expiredID, partID: "file")
        XCTAssertNotNil(expiredPayload)

        // 4. sendAgain resets saveThenStart to .savePending, drops cached body.upload, and moves to queued!
        let bodyCacheURL = spool.attentionDirectoryURL
            .appendingPathComponent(expiredID.uuidString, isDirectory: true)
            .appendingPathComponent("body.upload")
        try Data("stale start body".utf8).write(to: bodyCacheURL)
        let sentAgain = await holder.sendAgain(itemID: expiredID)
        XCTAssertTrue(sentAgain)
        let requeuedSnap = await transfer.engine.itemSnapshot(itemID: expiredID)
        let requeued = try XCTUnwrap(requeuedSnap)
        XCTAssertEqual(requeued.state, .queued)
        XCTAssertEqual(requeued.manifest.saveThenStart?.phase, .savePending)
        XCTAssertNil(requeued.manifest.saveThenStart?.savedPath)
        XCTAssertNil(requeued.manifest.saveThenStart?.savedTimestamp)
        XCTAssertNil(requeued.manifest.attention)
        let queuedBodyCache = spool.queuedDirectoryURL
            .appendingPathComponent(expiredID.uuidString, isDirectory: true)
            .appendingPathComponent("body.upload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedBodyCache.path))

        // 5. 401/403 halts batch and records pairing refusal without deleting bytes
        await holder.reconcileReadyToReview(
            localPort: 7071,
            instanceID: "journal-a",
            isPaired: true,
            markConfirmed: true,
            fetchStatus: { _, _ in .pairingRefused(401) }
        )
        XCTAssertTrue(holder.isPairingRefused)
        let stillKeptAfterAuth = await transfer.engine.itemSnapshot(itemID: keepPendingID)
        XCTAssertNotNil(stillKeptAfterAuth)

        // 6. Pairing change to journal-b resets journal-a's review items back to queued .savePending
        await holder.handlePairingChange(currentInstanceID: "journal-b")
        XCTAssertFalse(holder.isPairingRefused)
        let resetFromASnap = await transfer.engine.itemSnapshot(itemID: keepPendingID)
        let resetFromA = try XCTUnwrap(resetFromASnap)
        XCTAssertEqual(resetFromA.state, .queued)
        XCTAssertEqual(resetFromA.manifest.saveThenStart?.phase, .savePending)
        XCTAssertNil(resetFromA.manifest.attention)
        // journal-b's own item remains untouched
        let stayedOnBSnap = await transfer.engine.itemSnapshot(itemID: otherJournalID)
        let stayedOnB = try XCTUnwrap(stayedOnBSnap)
        XCTAssertEqual(stayedOnB.manifest.attention?.importReviewState, .readyToReview)
    }

    func testReconciliationClassifierRules() {
        for status in ["running", "success", "failed", "unconfirmed", "noted", "unavailable"] {
            XCTAssertEqual(
                ImportReconciliationClassifier.classify(.ok(ImportStatusPollPayload(status: status, savedStartActive: false, savedStartState: "eligible"))),
                .confirmed,
                "status=\(status) must confirm"
            )
        }
        XCTAssertEqual(
            ImportReconciliationClassifier.classify(.ok(ImportStatusPollPayload(status: "pending", savedStartActive: true, savedStartState: "eligible"))),
            .confirmed
        )
        XCTAssertEqual(
            ImportReconciliationClassifier.classify(.ok(ImportStatusPollPayload(status: "pending", savedStartActive: false, savedStartState: "consumed"))),
            .confirmed
        )
        for state in [nil, "eligible", "unknown"] {
            XCTAssertEqual(
                ImportReconciliationClassifier.classify(.ok(ImportStatusPollPayload(status: "pending", savedStartActive: false, savedStartState: state))),
                .keepReadyToReview
            )
        }
        XCTAssertEqual(ImportReconciliationClassifier.classify(.notFound), .expired)
        XCTAssertEqual(ImportReconciliationClassifier.classify(.pairingRefused(403)), .pairingRefused(403))
        XCTAssertEqual(ImportReconciliationClassifier.classify(.transientOrUnexpected(429)), .unchanged)
        XCTAssertEqual(ImportReconciliationClassifier.classify(.transientOrUnexpected(503)), .unchanged)
        XCTAssertEqual(ImportReconciliationClassifier.classify(.transientOrUnexpected(nil)), .unchanged)
    }

    // MARK: - 4. Ledger Drop Bug Fix & 24h Recent Receipts Pruning/Scoping

    func testDropItemRemovesDeliveredEntryFromLedgerAndRecentReceipts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ShareImportStore(
            cacheRootURL: self.tempRoot.appendingPathComponent("ImportQueue", isDirectory: true),
            now: { now }
        )
        let id = UUID()
        let idStr = ShareImportStore.itemIDString(id)
        try store.recordDelivered(
            itemID: idStr,
            basis: "file",
            contentType: "application/pdf",
            targetJournal: "",
            serverPath: "/imports/20261122_140000/doc.pdf",
            serverTimestamp: "20261122_140000",
            filename: "doc.pdf",
            originApp: nil,
            itemTime: nil,
            instanceID: "journal-a"
        )
        XCTAssertNotNil(try store.loadLedger()[idStr])
        XCTAssertEqual(store.recentReceipts(forInstanceID: "journal-a", isPaired: true, markConfirmed: true, now: now).count, 1)

        store.dropItem(itemID: id)
        XCTAssertNil(try store.loadLedger()[idStr], "dropItem must remove delivered entry from ledger.json")
        XCTAssertNil(store.lastDeliveredAt)
        XCTAssertTrue(store.recentReceipts(forInstanceID: "journal-a", isPaired: true, markConfirmed: true, now: now).isEmpty)
    }

    func testRecentReceiptsPrune24hCap5AndScopeByInstanceAndConfirmation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ShareImportStore(
            cacheRootURL: self.tempRoot.appendingPathComponent("ImportQueue", isDirectory: true),
            now: { now }
        )

        // 1 expired (>24h ago) + 6 fresh on journal-a + 1 fresh on journal-b
        try store.recordRecentReceipt(
            itemID: "old-1",
            filename: "stale.pdf",
            importID: "20261120_100000",
            instanceID: "journal-a",
            deliveredAt: now.addingTimeInterval(-(24 * 60 * 60 + 60))
        )
        for index in 1...6 {
            try store.recordRecentReceipt(
                itemID: "fresh-\(index)",
                filename: "file-\(index).pdf",
                importID: "20261122_14000\(index)",
                instanceID: "journal-a",
                deliveredAt: now.addingTimeInterval(-Double((7 - index) * 60))
            )
        }
        try store.recordRecentReceipt(
            itemID: "other-journal",
            filename: "other.pdf",
            importID: "20261122_140900",
            instanceID: "journal-b",
            deliveredAt: now.addingTimeInterval(-30)
        )

        // Unpaired or unconfirmed must hide receipts
        XCTAssertTrue(store.recentReceipts(forInstanceID: "journal-a", isPaired: false, markConfirmed: true, now: now).isEmpty)
        XCTAssertTrue(store.recentReceipts(forInstanceID: "journal-a", isPaired: true, markConfirmed: false, now: now).isEmpty)

        // Paired & confirmed on journal-a sees 5 newest (fresh-6 down to fresh-2), no stale, no journal-b
        let visibleA = store.recentReceipts(forInstanceID: "journal-a", isPaired: true, markConfirmed: true, now: now)
        XCTAssertEqual(visibleA.map(\.id), ["fresh-6", "fresh-5", "fresh-4", "fresh-3", "fresh-2"])
        let visibleB = store.recentReceipts(forInstanceID: "journal-b", isPaired: true, markConfirmed: true, now: now)
        XCTAssertEqual(visibleB.map(\.id), ["other-journal"])
    }

    // MARK: - 5. Home Import Tile, Status Pill & Status Pane Lead Honesty

    func testHomeImportTileWorstSignalWinsAndQuietIdle() {
        XCTAssertEqual(
            HomeImportTileSignal.resolve(
                failedCount: 0,
                readyToReviewCount: 0,
                reviewExpiredCount: 0,
                inFlightCount: 0,
                pendingCount: 0,
                activeItems: [],
                isOfflineOrUnpaired: false
            ),
            .idle
        )

        let reviewItem = ShareImportActiveItem(
            id: UUID(),
            filename: "export.zip",
            phase: .readyToReview(kind: "body_confirmation_required", importID: "20261122_140500"),
            createdAt: Date(),
            byteCount: 1024,
            hasLocalCopy: true,
            isUnadopted: false
        )
        let attentionItem = ShareImportActiveItem(
            id: UUID(),
            filename: "holiday.mov",
            phase: .needsAttention(retryable: false, reason: "bad file"),
            createdAt: Date(),
            byteCount: 1024,
            hasLocalCopy: true,
            isUnadopted: false
        )

        // needs attention > ready to review > sending > waiting
        let attentionSignal = HomeImportTileSignal.resolve(
            failedCount: 1,
            readyToReviewCount: 1,
            reviewExpiredCount: 0,
            inFlightCount: 1,
            pendingCount: 2,
            activeItems: [reviewItem, attentionItem],
            isOfflineOrUnpaired: false
        )
        XCTAssertEqual(attentionSignal, .needsAttention(detail: "holiday.mov"))
        XCTAssertEqual(attentionSignal.accessibilityLabel, "import, needs attention. holiday.mov.")

        let reviewSignal = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 1,
            reviewExpiredCount: 0,
            inFlightCount: 1,
            pendingCount: 2,
            activeItems: [reviewItem],
            isOfflineOrUnpaired: false
        )
        XCTAssertEqual(reviewSignal, .readyToReview(detail: "export.zip"))
        XCTAssertEqual(reviewSignal.accessibilityLabel, "import, ready to review. export.zip.")

        let multiReview = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 2,
            reviewExpiredCount: 0,
            inFlightCount: 0,
            pendingCount: 0,
            activeItems: [reviewItem],
            isOfflineOrUnpaired: false
        )
        XCTAssertEqual(multiReview, .readyToReview(detail: "2 ready in your journal"))

        let offlineWaiting = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 0,
            pendingCount: 3,
            activeItems: [],
            isOfflineOrUnpaired: true
        )
        XCTAssertEqual(offlineWaiting, .waiting(detail: "waiting for your journal"))
    }

    func testStatusPillAndLeadHonestyWhenWaitingIsZero() {
        // Ready to review when waiting == 0 and faults == 0
        let reviewPill = HomeStatusPillState.resolve(
            isPaired: true,
            status: .connectedIdle,
            hasBacklog: false,
            isStalled: false,
            awaitingMarkConfirmation: false,
            importReadyToReviewCount: 2,
            importNeedsAttentionCount: 0
        )
        XCTAssertEqual(reviewPill, .importsReadyToReview(2))
        XCTAssertEqual(reviewPill.label, "2 ready to review")
        XCTAssertFalse(reviewPill.shouldPulse(reduceMotion: false))

        let reviewLead = StatusPaneLead.resolve(pillState: reviewPill, waitingTotal: 0, showsConnectionDetails: true)
        XCTAssertEqual(reviewLead.headline, "2 imports ready to review")
        XCTAssertEqual(reviewLead.subline, "open import to review and start.")

        // Needs attention wins over ready to review when waiting == 0 (non-green connected, no fault text rollup in pill)
        let attentionPill = HomeStatusPillState.resolve(
            isPaired: true,
            status: .connectedIdle,
            hasBacklog: false,
            isStalled: false,
            awaitingMarkConfirmation: false,
            importReadyToReviewCount: 2,
            importNeedsAttentionCount: 1
        )
        XCTAssertEqual(attentionPill, .importsNeedAttention)
        XCTAssertEqual(attentionPill.label, SourceVocabulary.connectedLabel)
        XCTAssertFalse(attentionPill.shouldPulse(reduceMotion: false))

        let attentionLead = StatusPaneLead.resolve(pillState: attentionPill, waitingTotal: 0, showsConnectionDetails: true)
        XCTAssertEqual(attentionLead.headline, "imports need you")
        XCTAssertEqual(attentionLead.subline, "open import to see why.")
    }

    // MARK: - 6. In-Place WKWebView Navigation Identity & Additive Host Bridge

    func testJournalWebViewIdentityStaysStableAcrossSameOriginPaths() throws {
        let listURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/app/import/"))
        let detailURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/app/import/20261122_140500"))
        let otherPortURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7072/app/import/20261122_140500"))

        XCTAssertEqual(
            JournalWebView.webViewIdentity(for: listURL, journalInstanceID: "journal-a"),
            JournalWebView.webViewIdentity(for: detailURL, journalInstanceID: "journal-a")
        )
        XCTAssertNotEqual(
            JournalWebView.webViewIdentity(for: detailURL, journalInstanceID: "journal-a"),
            JournalWebView.webViewIdentity(for: otherPortURL, journalInstanceID: "journal-a")
        )
        XCTAssertNotEqual(
            JournalWebView.webViewIdentity(for: detailURL, journalInstanceID: "journal-a"),
            JournalWebView.webViewIdentity(for: detailURL, journalInstanceID: "journal-b")
        )
    }

    func testJournalWebNavigationSessionHonorsNavigationTokenForInPlaceReloads() throws {
        let importListURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/app/import/"))
        let detailURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/app/import/20261122_140500"))
        var loadedURLs: [URL] = []
        let session = JournalWebNavigationSession(
            load: { request in
                if let url = request.url { loadedURLs.append(url) }
                return NSObject()
            },
            setState: { _ in }
        )

        session.requestLoad(url: importListURL, reloadToken: 0, navigationToken: 1)
        session.requestLoad(url: detailURL, reloadToken: 0, navigationToken: 2)
        // Re-opening the same detail URL with a new navigationToken must still issue a load
        session.requestLoad(url: detailURL, reloadToken: 0, navigationToken: 3)
        XCTAssertEqual(loadedURLs, [importListURL, detailURL, detailURL])
    }

    func testJournalImportHostAdditiveStatusFieldsAndReviewPollingContinuity() throws {
        let reviewReply = JournalImportItemState.attention(
            reason: AppStrings.ios_app_importreviewdetail(),
            importID: "20261122_140500",
            reviewRequired: true,
            reviewExpired: false,
            reasonCode: TransferReasonCodes.importPreviewRequired,
            kind: "body_confirmation_required",
            retryable: false
        ).reply
        XCTAssertEqual(reviewReply["state"] as? String, "attention")
        XCTAssertEqual(reviewReply["review_required"] as? Bool, true)
        XCTAssertEqual(reviewReply["reason_code"] as? String, "import_preview_required")
        XCTAssertEqual(reviewReply["kind"] as? String, "body_confirmation_required")
        XCTAssertEqual(reviewReply["import_id"] as? String, "20261122_140500")
        XCTAssertEqual(reviewReply["retryable"] as? Bool, false)

        let expiredReply = JournalImportItemState.attention(
            reason: AppStrings.ios_app_importreviewexpired(),
            importID: "20261122_140500",
            reviewRequired: false,
            reviewExpired: true,
            reasonCode: TransferReasonCodes.importPreviewRequired,
            kind: "body_confirmation_required",
            retryable: true
        ).reply
        XCTAssertEqual(expiredReply["state"] as? String, "attention")
        XCTAssertEqual(expiredReply["review_required"] as? Bool, false)
        XCTAssertEqual(expiredReply["review_expired"] as? Bool, true)
        XCTAssertEqual(expiredReply["retryable"] as? Bool, true)

        let uploadingReply = JournalImportItemState.uploading(deviceNoun: "ipad", sizeBytes: 4096).reply
        XCTAssertEqual(uploadingReply["state"] as? String, "uploading")
        XCTAssertEqual(uploadingReply["device_noun"] as? String, "ipad")
        XCTAssertEqual(uploadingReply["size_bytes"] as? Int64, 4096)

        XCTAssertEqual(JournalImportQueueIntake.currentDeviceNoun(idiom: .phone), "iphone")
        XCTAssertEqual(JournalImportQueueIntake.currentDeviceNoun(idiom: .pad), "ipad")
    }

    // MARK: - Helpers

    private func seedAttentionShare(
        engine: TransferEngine,
        spool: TransferSpool,
        itemID: UUID,
        filename: String,
        instanceID: String,
        importID: String?,
        reviewState: TransferImportReviewState?,
        kind: String,
        retryable: Bool,
        now: Date
    ) async throws {
        _ = engine
        try self.writeDirectAttentionShare(
            spool: spool,
            itemID: itemID,
            filename: filename,
            instanceID: instanceID,
            importID: importID,
            reviewState: reviewState,
            kind: kind,
            retryable: retryable,
            now: now
        )
    }

    private func writeDirectAttentionShare(
        spool: TransferSpool,
        itemID: UUID,
        filename: String,
        instanceID: String,
        importID: String?,
        reviewState: TransferImportReviewState?,
        kind: String,
        retryable: Bool,
        now: Date
    ) throws {
        let fields = ShareImportTransferMetadata.Fields(
            basis: "file",
            contentType: "application/zip",
            targetJournal: "",
            filename: filename,
            originApp: nil,
            itemTime: ShareImportStore.iso8601String(for: now),
            bytes: 128,
            requestSource: "file"
        )
        let manifest = TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: now,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "file",
                    kind: .file,
                    relativePath: "raw.bin",
                    filename: filename,
                    contentType: "application/zip",
                    byteCount: 128
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: ImporterServerURL.savePath,
                startPath: ImporterServerURL.startPath
            ),
            meta: ShareImportTransferMetadata.meta(fields: fields),
            saveThenStart: TransferSaveThenStartState(
                phase: .startPending,
                savedPath: "/imports/\(importID ?? "20261122_140000")/\(filename)",
                savedTimestamp: importID ?? "20261122_140000",
                savedInstanceID: instanceID
            )
        )
        let staged = try spool.stage(manifest: manifest, payloads: ["file": Data("payload".utf8)])
        let committed = try spool.commitStagedItem(itemID: staged.item.manifest.itemID, now: now)
        _ = try spool.moveQueuedItemToAttention(
            committed,
            reason: reviewState != nil ? TransferAttentionReason.importReviewRequiredCode : TransferAttentionReason.httpClientErrorCode,
            detail: reviewState != nil ? AppStrings.ios_app_importreviewdetailexpiry() : "cannot import",
            journalReasonCode: TransferReasonCodes.importPreviewRequired,
            importReviewState: reviewState,
            importPreviewKind: kind,
            importID: importID,
            savedInstanceID: instanceID,
            retryable: retryable,
            now: now
        )
    }
}

private nonisolated final class LockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        self.lock.lock()
        self.storage.append(element)
        self.lock.unlock()
    }

    func values() -> [Element] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}
