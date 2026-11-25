// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

@MainActor
final class ResumableImportPresentationTests: XCTestCase {
    func testBytePercentHonestyAndCatalogStrings() {
        XCTAssertEqual(ImportByteFormat.bytes(0), "0 KB")
        XCTAssertEqual(ImportByteFormat.percent(sent: 0, total: 0), 0)
        XCTAssertEqual(ImportByteFormat.percent(sent: 0, total: 100), 0)
        XCTAssertEqual(ImportByteFormat.percent(sent: 50, total: 100), 50)
        // Never claims 100% until every byte is confirmed.
        XCTAssertEqual(ImportByteFormat.percent(sent: 999_999_999, total: 1_000_000_000), 99)
        XCTAssertEqual(ImportByteFormat.percent(sent: 1_000_000_000, total: 1_000_000_000), 100)

        let progressLine = AppStrings.ios_app_importrowprogress("128 MB", "4 GB", "3")
        XCTAssertEqual(progressLine, "128 MB of 4 GB (3%)")

        let oneMore = AppStrings.ios_app_importtileprogressmore(1, "128 MB", "4 GB")
        XCTAssertEqual(oneMore, "128 MB of 4 GB · 1 more waiting")

        let threeMore = AppStrings.ios_app_importtileprogressmore(3, "128 MB", "4 GB")
        XCTAssertEqual(threeMore, "128 MB of 4 GB · 3 more waiting")
    }

    func testHostImportStatusReplyCarriesAdditiveResumableFields() {
        let uploading = JournalImportItemState.uploading(
            deviceNoun: "iphone",
            sizeBytes: 33_554_432,
            bytesSent: 4_194_304,
            bytesTotal: 33_554_432,
            resumable: true,
            phase: .sending
        ).reply
        XCTAssertEqual(uploading["state"] as? String, "uploading")
        XCTAssertEqual(uploading["device_noun"] as? String, "iphone")
        XCTAssertEqual(uploading["size_bytes"] as? Int64, 33_554_432)
        XCTAssertEqual(uploading["bytes_sent"] as? Int64, 4_194_304)
        XCTAssertEqual(uploading["bytes_total"] as? Int64, 33_554_432)
        XCTAssertEqual(uploading["resumable"] as? Bool, true)
        XCTAssertEqual(uploading["phase"] as? String, "sending")

        let checking = JournalImportItemState.uploading(
            deviceNoun: "ipad",
            sizeBytes: 33_554_432,
            bytesSent: 33_554_432,
            bytesTotal: 33_554_432,
            resumable: true,
            phase: .checking
        ).reply
        XCTAssertEqual(checking["device_noun"] as? String, "ipad")
        XCTAssertEqual(checking["phase"] as? String, "checking")

        let paused = JournalImportItemState.waiting(
            deviceNoun: "iphone",
            sizeBytes: 33_554_432,
            bytesSent: 8_388_608,
            bytesTotal: 33_554_432,
            resumable: true,
            phase: .paused
        ).reply
        XCTAssertEqual(paused["state"] as? String, "waiting")
        XCTAssertEqual(paused["bytes_sent"] as? Int64, 8_388_608)
        XCTAssertEqual(paused["bytes_total"] as? Int64, 33_554_432)
        XCTAssertEqual(paused["resumable"] as? Bool, true)
        XCTAssertEqual(paused["phase"] as? String, "paused")

        let smallUpload = JournalImportItemState.uploading(deviceNoun: "iphone", sizeBytes: 1024).reply
        XCTAssertNil(smallUpload["bytes_sent"])
        XCTAssertNil(smallUpload["bytes_total"])
        XCTAssertNil(smallUpload["resumable"])
        XCTAssertNil(smallUpload["phase"])
    }

    func testResumableFaultOwnerCopyMapping() {
        let now = Date()
        let spaceFault = TransferAttentionInfo(
            reason: TransferAttentionReason.resumableFaultCode,
            shortDetail: "raw detail",
            movedAt: now,
            journalReasonCode: TransferReasonCodes.insufficientJournalSpace,
            retryable: true
        )
        let formatted4GB = ImportByteFormat.bytes(4_000_000_000)
        XCTAssertEqual(
            spaceFault.ownerFailureReason(totalBytes: 4_000_000_000),
            "not enough space where your journal lives for this \(formatted4GB) file. free up space there or wait for other imports to finish, then try again."
        )

        let integrityFault = TransferAttentionInfo(
            reason: TransferAttentionReason.resumableFaultCode,
            shortDetail: "raw detail",
            movedAt: now,
            journalReasonCode: TransferReasonCodes.wholeFileChecksumMismatch,
            retryable: true
        )
        XCTAssertEqual(
            integrityFault.ownerFailureReason(totalBytes: 4_000_000_000),
            "the file didn't arrive intact. try sending it again."
        )

        let expiredFault = TransferAttentionInfo(
            reason: TransferAttentionReason.resumableFaultCode,
            shortDetail: "raw detail",
            movedAt: now,
            journalReasonCode: TransferReasonCodes.uploadNotFound,
            retryable: true
        )
        XCTAssertEqual(
            expiredFault.ownerFailureReason(totalBytes: 4_000_000_000),
            "this unfinished import expired after waiting too long. try again to start over."
        )

        let unreadableFault = TransferAttentionInfo(
            reason: TransferAttentionReason.resumableFaultCode,
            shortDetail: "raw detail",
            movedAt: now,
            journalReasonCode: TransferReasonCodes.localFileUnreadable,
            retryable: false
        )
        XCTAssertEqual(
            unreadableFault.ownerFailureReason(totalBytes: 4_000_000_000),
            "this file could no longer be read on this device. remove it and choose the file again."
        )
    }

    func testHomeImportTileSignalForResumableSendingCheckingPausedAndRefusedPairing() {
        let now = Date()
        let sentStr = ImportByteFormat.bytes(500_000_000)
        let totalStr = ImportByteFormat.bytes(2_000_000_000)

        let sendingItem = ShareImportActiveItem(
            id: UUID(),
            filename: "archive.zip",
            phase: .sending,
            createdAt: now,
            byteCount: 2_000_000_000,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: TransferResumableProgress(
                bytesSent: 500_000_000,
                bytesTotal: 2_000_000_000,
                phase: .sending
            )
        )

        // Single resumable file sending (pendingCount includes in-flight item -> 0 more waiting).
        let sendingSingle = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 1,
            pendingCount: 1,
            activeItems: [sendingItem],
            isOfflineOrUnpaired: false
        )
        XCTAssertEqual(sendingSingle, .sending(detail: "\(sentStr) of \(totalStr)"))

        // Single resumable file sending + 2 more queued behind it.
        let sendingWithMore = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 1,
            pendingCount: 3,
            activeItems: [sendingItem],
            isOfflineOrUnpaired: false
        )
        XCTAssertEqual(sendingWithMore, .sending(detail: "\(sentStr) of \(totalStr) · 2 more waiting"))

        // Checking phase shows "checking file" + confirmed bytes.
        let checkingItem = ShareImportActiveItem(
            id: UUID(),
            filename: "archive.zip",
            phase: .sending,
            createdAt: now,
            byteCount: 2_000_000_000,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: TransferResumableProgress(
                bytesSent: 2_000_000_000,
                bytesTotal: 2_000_000_000,
                phase: .checking
            )
        )
        let checkingSignal = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 1,
            pendingCount: 1,
            activeItems: [checkingItem],
            isOfflineOrUnpaired: false
        )
        XCTAssertEqual(checkingSignal, .checking(detail: "\(totalStr) of \(totalStr)"))
        XCTAssertEqual(checkingSignal.statusWord, "checking file")

        // Transiently paused while in-flight -> paused (never sending, never needs attention).
        let pausedInFlightItem = ShareImportActiveItem(
            id: UUID(),
            filename: "archive.zip",
            phase: .sending,
            createdAt: now,
            byteCount: 2_000_000_000,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: TransferResumableProgress(
                bytesSent: 500_000_000,
                bytesTotal: 2_000_000_000,
                phase: .paused
            )
        )
        let pausedInFlightSignal = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 1,
            pendingCount: 1,
            activeItems: [pausedInFlightItem],
            isOfflineOrUnpaired: true
        )
        XCTAssertEqual(pausedInFlightSignal, .paused(detail: "\(sentStr) of \(totalStr)"))
        XCTAssertEqual(pausedInFlightSignal.statusWord, "paused")

        // Waiting with resumable progress after relaunch/offline -> paused.
        let pausedWaitingItem = ShareImportActiveItem(
            id: UUID(),
            filename: "archive.zip",
            phase: .waiting,
            createdAt: now,
            byteCount: 2_000_000_000,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: TransferResumableProgress(
                bytesSent: 500_000_000,
                bytesTotal: 2_000_000_000,
                phase: .paused
            )
        )
        let pausedWaitingSignal = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 0,
            pendingCount: 2,
            activeItems: [pausedWaitingItem],
            isOfflineOrUnpaired: true
        )
        XCTAssertEqual(pausedWaitingSignal, .paused(detail: "\(sentStr) of \(totalStr) · 1 more waiting"))

        // Refused pairing holding waiting imports -> needs attention.
        let refusedSignal = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 0,
            pendingCount: 1,
            activeItems: [pausedWaitingItem],
            isOfflineOrUnpaired: true,
            isPairingRefused: true
        )
        XCTAssertEqual(refusedSignal, .needsAttention(detail: "archive.zip"))

        // Refused pairing with zero waiting imports stays idle.
        let refusedIdle = HomeImportTileSignal.resolve(
            failedCount: 0,
            readyToReviewCount: 0,
            reviewExpiredCount: 0,
            inFlightCount: 0,
            pendingCount: 0,
            activeItems: [],
            isOfflineOrUnpaired: true,
            isPairingRefused: true
        )
        XCTAssertEqual(refusedIdle, .idle)
    }

    func testImportRowProgressPresentationAndCancelDialog() {
        let now = Date()
        let sentStr = ImportByteFormat.bytes(500_000_000)
        let totalStr = ImportByteFormat.bytes(2_000_000_000)

        let sending = ShareImportActiveItem(
            id: UUID(),
            filename: "takeout.zip",
            phase: .sending,
            createdAt: now,
            byteCount: 2_000_000_000,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: TransferResumableProgress(
                bytesSent: 500_000_000,
                bytesTotal: 2_000_000_000,
                phase: .sending,
                isResuming: false
            )
        )
        let sendingPres = ImportRowProgressPresentation.build(for: sending)
        XCTAssertEqual(sendingPres?.kind, .sending)
        XCTAssertEqual(sendingPres?.statusWord, "sending")
        XCTAssertEqual(sendingPres?.detailLine, "\(sentStr) of \(totalStr) (25%)")
        XCTAssertEqual(sendingPres?.fraction ?? -1, 0.25, accuracy: 0.001)

        var resuming = sending
        resuming.resumableProgress?.isResuming = true
        let resumingPres = ImportRowProgressPresentation.build(for: resuming)
        XCTAssertEqual(resumingPres?.kind, .sending)
        XCTAssertEqual(resumingPres?.detailLine, "resuming from \(sentStr) of \(totalStr)")

        var checking = sending
        checking.resumableProgress = TransferResumableProgress(
            bytesSent: 2_000_000_000,
            bytesTotal: 2_000_000_000,
            phase: .checking
        )
        let checkingPres = ImportRowProgressPresentation.build(for: checking)
        XCTAssertEqual(checkingPres?.kind, .checking)
        XCTAssertEqual(checkingPres?.statusWord, "checking file")
        XCTAssertEqual(checkingPres?.detailLine, "checking the complete file")
        XCTAssertEqual(checkingPres?.fraction, 1.0)

        let paused = ShareImportActiveItem(
            id: UUID(),
            filename: "takeout.zip",
            phase: .waiting,
            createdAt: now,
            byteCount: 2_000_000_000,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: TransferResumableProgress(
                bytesSent: 500_000_000,
                bytesTotal: 2_000_000_000,
                phase: .paused
            )
        )
        let pausedPres = ImportRowProgressPresentation.build(for: paused)
        XCTAssertEqual(pausedPres?.kind, .paused)
        XCTAssertEqual(pausedPres?.statusWord, "paused")
        XCTAssertEqual(
            pausedPres?.detailLine,
            "paused at \(sentStr) of \(totalStr). will pick up from here when your journal reconnects."
        )

        let smallItem = ShareImportActiveItem(
            id: UUID(),
            filename: "note.pdf",
            phase: .sending,
            createdAt: now,
            byteCount: 4096,
            hasLocalCopy: true,
            isUnadopted: false,
            resumableProgress: nil
        )
        XCTAssertNil(ImportRowProgressPresentation.build(for: smallItem))

        XCTAssertEqual(ImportCancelDialogPresentation.title(for: sending), "cancel takeout.zip?")
        XCTAssertEqual(
            ImportCancelDialogPresentation.body,
            "this stops sending, removes the copy on this device, and clears the unfinished import from your journal if it's reachable."
        )
    }

    func testShareTransferHolderOverlaysLiveMirrorProgressAndJournalHostStatus() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resumable-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let spool = TransferSpool(rootURL: dir.appendingPathComponent("spool", isDirectory: true))
        let mirror = TransferStatusMirror()
        let engine = TransferEngine(
            spool: spool,
            transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
            endpointResolver: TransferEndpointResolverStub(.unavailable("offline")),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [1], maxDelay: 10)),
            clock: LiveTransferClock(),
            statusMirror: mirror,
            maxConcurrent: 1
        )
        try await engine.start()
        await engine.pause()

        let store = ShareImportStore(cacheRootURL: dir.appendingPathComponent("share", isDirectory: true))
        let holder = ShareTransferHolder(transferEngine: engine, mirror: mirror, store: store)

        let itemID = UUID()
        let manifest = TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Date(),
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "file",
                    kind: .file,
                    relativePath: "raw.bin",
                    filename: "export.zip",
                    contentType: "application/zip",
                    byteCount: 20_000_000
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: ImporterServerURL.savePath,
                startPath: ImporterServerURL.startPath
            ),
            meta: ShareImportTransferMetadata.meta(fields: ShareImportTransferMetadata.Fields(
                basis: "file",
                contentType: "public.zip-archive",
                targetJournal: "journal-A",
                filename: "export.zip",
                originApp: "files",
                itemTime: nil,
                bytes: 20_000_000,
                requestSource: "file"
            )),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
        _ = try await engine.enqueue(manifest: manifest, payloads: ["file": Data(repeating: 0x2A, count: 64)])
        await holder.refreshActiveItems()
        XCTAssertTrue(holder.hasLargeBackgroundImportCandidate)

        let liveProgress = TransferResumableProgress(
            bytesSent: 8_388_608,
            bytesTotal: 20_000_000,
            phase: .sending
        )
        var snapshot = await engine.snapshot()
        snapshot.resumableProgressByItemID[itemID] = liveProgress
        snapshot.advertisedResumableThresholdBytes = 16_777_216
        mirror.apply(snapshot: snapshot)

        XCTAssertEqual(holder.advertisedResumableThresholdBytes, 16_777_216)
        XCTAssertEqual(holder.onDeviceItems.first?.resumableProgress, liveProgress)

        let drainGate = ForegroundDrainGate(drive: {})
        let intake = JournalImportQueueIntake(holder: holder, drainGate: drainGate, deviceNounProvider: { "ipad" })
        let hostState = await intake.state(of: itemID)
        XCTAssertEqual(
            hostState,
            JournalImportItemState.waiting(
                deviceNoun: "ipad",
                sizeBytes: 20_000_000,
                bytesSent: 8_388_608,
                bytesTotal: 20_000_000,
                resumable: true,
                phase: .paused
            )
        )
        XCTAssertEqual(hostState.reply["bytes_sent"] as? Int64, 8_388_608)
        XCTAssertEqual(hostState.reply["bytes_total"] as? Int64, 20_000_000)
        XCTAssertEqual(hostState.reply["resumable"] as? Bool, true)
        XCTAssertEqual(hostState.reply["phase"] as? String, "paused")
        XCTAssertEqual(hostState.reply["device_noun"] as? String, "ipad")
    }
}
