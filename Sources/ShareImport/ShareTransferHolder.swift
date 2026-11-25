// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Lightweight view-facing snapshot of one active, awaiting-review, or faulted share import.
nonisolated struct ShareImportActiveItem: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case readyToReview(kind: String, importID: String)
        case reviewExpired
        case sending
        case waiting
        case needsAttention(retryable: Bool, reason: String)
    }

    let id: UUID
    let filename: String
    let phase: Phase
    let createdAt: Date
    let byteCount: Int64?
    let hasLocalCopy: Bool
    let isUnadopted: Bool
    var resumableProgress: TransferResumableProgress? = nil

    var importID: String? {
        if case .readyToReview(_, let importID) = self.phase {
            return importID
        }
        return nil
    }

    var isResumableActiveOrPaused: Bool {
        guard self.resumableProgress != nil else { return false }
        switch self.phase {
        case .sending, .waiting:
            return true
        case .readyToReview, .reviewExpired, .needsAttention:
            return false
        }
    }

    var isReviewCardItem: Bool {
        switch self.phase {
        case .readyToReview, .reviewExpired:
            true
        case .sending, .waiting, .needsAttention:
            false
        }
    }

    var isDeviceListItem: Bool {
        !self.isReviewCardItem
    }

    var isAppleHealthExpiryNote: Bool {
        if case .readyToReview(let kind, _) = self.phase {
            return kind == "body_confirmation_required"
        }
        return false
    }

    /// Actionable-first sort order for the `on this device` card:
    /// `needs attention` -> `sending` -> `waiting`, newest first within each band.
    var deviceSortRank: Int {
        switch self.phase {
        case .needsAttention: 0
        case .sending: 1
        case .waiting: 2
        case .readyToReview: 3
        case .reviewExpired: 4
        }
    }
}

@MainActor
extension ShareImportStore {
    func unadoptedActiveItems(excluding seenIDs: Set<UUID>) -> [ShareImportActiveItem] {
        let ledger = (try? self.loadLedger()) ?? [:]
        var items: [ShareImportActiveItem] = []
        for status in [ItemStatus.pending, .failed] {
            for directory in (try? self.itemDirectories(status: status)) ?? [] {
                let itemIDString = directory.lastPathComponent
                guard ledger[itemIDString] == nil,
                      let uuid = UUID(uuidString: itemIDString),
                      !seenIDs.contains(uuid)
                else {
                    continue
                }
                let note = self.readNoteObject(itemID: itemIDString, status: status)
                let filename = (note?["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? AppStrings.ios_app_onthisphonefilelabel()
                let bytes = (note?["bytes"] as? NSNumber)?.int64Value
                let createdAt = Self.parseItemTime(note?["item_time"] as? String) ?? self.now()
                let hasLocalCopy = self.fileManager.fileExists(atPath: self.rawURL(itemID: itemIDString, status: status).path)
                let phase: ShareImportActiveItem.Phase
                if status == .failed {
                    let failure = self.loadFailureRecordIfPresent(itemID: itemIDString, status: .failed)
                    let retryable = failure?.classification != .terminal
                    let reason = failure?.reason.isEmpty == false ? (failure?.reason ?? "") : AppStrings.ios_app_importneedsattentionfallback()
                    phase = .needsAttention(retryable: retryable, reason: reason)
                } else {
                    phase = .waiting
                }
                items.append(ShareImportActiveItem(
                    id: uuid,
                    filename: filename,
                    phase: phase,
                    createdAt: createdAt,
                    byteCount: bytes,
                    hasLocalCopy: hasLocalCopy,
                    isUnadopted: true
                ))
            }
        }
        return items
    }
}

@MainActor
@Observable
final class ShareTransferHolder {
    let transferEngine: TransferEngine
    let store: ShareImportStore
    private let mirror: TransferStatusMirror
    private let sourceKey: String
    private(set) var activeItems: [ShareImportActiveItem] = []
    private var reconcilePairingRefused = false
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var reconcilePendingAgain = false

    /// `true` when either upload delivery (`401`/`403` on `/save` or `/start`) or
    /// ready-to-review reconciliation saw the journal refuse this device's pairing.
    var isPairingRefused: Bool {
        self.reconcilePairingRefused || self.status.authHeld
    }

    /// Queued share items held while the journal is refusing this device's pairing.
    /// Excluded from `sendableUploadTotals` so background drains quiesce while `uploadTotals`
    /// keeps reporting the waiting count.
    var unsendableCount: Int {
        self.isPairingRefused ? self.pendingCount : 0
    }

    init(
        transferEngine: TransferEngine,
        mirror: TransferStatusMirror,
        store: ShareImportStore,
        sourceKey: String = ObserverAudioTransferSource.share
    ) {
        self.transferEngine = transferEngine
        self.mirror = mirror
        self.store = store
        self.sourceKey = sourceKey
    }

    var pendingCount: Int {
        self.status.queuedCount + self.store.pendingCount
    }

    /// Saved imports waiting for owner preview & confirmation in the journal.
    var readyToReviewCount: Int {
        self.status.readyToReviewCount
    }

    /// Saved imports whose waiting copy in the journal expired while local bytes remain.
    var reviewExpiredCount: Int {
        self.status.reviewExpiredCount
    }

    /// True import faults (excluding `.readyToReview` and `.reviewExpired`).
    /// No-double-count invariant: a share item is in exactly one of three states - a `ShareImportStore` `pending/`/`failed/` row before adoption, a `TransferEngine` item after adoption, or a ledger row after delivery.
    var failedCount: Int {
        let engineFaults = max(0, self.status.attentionCount - self.status.readyToReviewCount - self.status.reviewExpiredCount)
        return engineFaults + self.store.failedCount
    }

    /// Held non-review refusals the engine is pacing (including non-retryable 409 preview refusals).
    /// Counted in `failedCount`; excluded from `sendableUploadTotals`.
    var refusalPacedCount: Int {
        self.status.refusalPacedCount
    }

    var inFlightCount: Int {
        self.status.inFlightCount
    }

    var recentBytesPerSecond: Double {
        self.status.bytesPerSecond
    }

    var confirmedActiveTransferCount: Int {
        self.status.inFlightCount
    }

    var recentErrorCount: Int {
        self.status.recentErrorCount
    }

    var lastUploadAt: Date? {
        self.store.lastDeliveredAt ?? self.status.lastDeliveredAt
    }

    var lastError: String? {
        self.status.lastErrorDetail ?? self.store.lastError
    }

    /// The source's transfer error, only while it is still recent at `now`.
    func recentError(now: Date) -> TransferRecentError? {
        TransferRecentError.evaluate(self.status, now: now)
    }

    var deliveredCount: Int {
        self.status.deliveredCount
    }

    var resumableProgressByItemID: [UUID: TransferResumableProgress] {
        self.mirror.resumableProgressByItemID
    }

    var advertisedResumableThresholdBytes: Int64 {
        self.mirror.advertisedResumableThresholdBytes
    }

    /// Active items overlaid with live per-chunk resumable progress from the transfer mirror.
    var liveActiveItems: [ShareImportActiveItem] {
        let liveByID = self.mirror.resumableProgressByItemID
        return self.activeItems.map { item in
            guard let live = liveByID[item.id] else { return item }
            switch item.phase {
            case .sending, .waiting:
                var updated = item
                updated.resumableProgress = live
                return updated
            case .readyToReview, .reviewExpired, .needsAttention:
                return item
            }
        }
    }

    /// True when at least one active or queued import qualifies for a dedicated large-import
    /// background continued-processing run (either already resumable or at/above threshold).
    var hasLargeBackgroundImportCandidate: Bool {
        let threshold = self.advertisedResumableThresholdBytes
        return self.onDeviceItems.contains { item in
            switch item.phase {
            case .sending, .waiting:
                if item.resumableProgress != nil { return true }
                if let bytes = item.byteCount, bytes >= threshold { return true }
                return false
            case .readyToReview, .reviewExpired, .needsAttention:
                return false
            }
        }
    }

    var reviewItems: [ShareImportActiveItem] {
        self.liveActiveItems.filter(\.isReviewCardItem).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var onDeviceItems: [ShareImportActiveItem] {
        self.liveActiveItems.filter(\.isDeviceListItem).sorted { lhs, rhs in
            if lhs.deviceSortRank != rhs.deviceSortRank {
                return lhs.deviceSortRank < rhs.deviceSortRank
            }
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func recentReceipts(
        instanceID: String,
        isPaired: Bool,
        markConfirmed: Bool,
        now: Date? = nil
    ) -> [ImportRecentReceipt] {
        self.store.recentReceipts(
            forInstanceID: instanceID,
            isPaired: isPaired,
            markConfirmed: markConfirmed,
            now: now
        )
    }

    func refreshActiveItems() async {
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: self.sourceKey)
        var built: [ShareImportActiveItem] = []
        var seenIDs: Set<UUID> = []

        for snapshot in snapshots {
            let manifest = snapshot.manifest
            let fields = try? ShareImportTransferMetadata.fields(from: manifest)
            let part = manifest.payloadParts.first
            let filename = fields?.filename ?? part?.filename ?? AppStrings.ios_app_onthisphonefilelabel()
            let byteCount = fields?.bytes ?? part?.byteCount.map(Int64.init)
            let hasLocalCopy: Bool
            if let part {
                hasLocalCopy = await self.transferEngine.payloadFileURL(itemID: snapshot.itemID, partID: part.partID) != nil
            } else {
                hasLocalCopy = false
            }
            let phase: ShareImportActiveItem.Phase
            switch snapshot.state {
            case .dispatching:
                phase = .sending
            case .queued, .held, .paused, .salvaged, .staged:
                phase = .waiting
            case .attention:
                if let attention = manifest.attention, attention.isReadyToReview,
                   let importID = ShareImportID.validated(attention.importID ?? manifest.saveThenStart?.savedTimestamp)
                {
                    phase = .readyToReview(
                        kind: attention.importPreviewKind ?? "confirmation_required",
                        importID: importID
                    )
                } else if manifest.attention?.isReviewExpired == true {
                    phase = .reviewExpired
                } else {
                    let retryable = manifest.attention?.isRetryableAttention ?? true
                    let reason = manifest.attention?.ownerFailureReason(totalBytes: byteCount)
                        ?? AppStrings.ios_app_importneedsattentionfallback()
                    phase = .needsAttention(retryable: retryable, reason: reason)
                }
            case .delivered, .dropped:
                continue
            }
            seenIDs.insert(manifest.itemID)
            built.append(ShareImportActiveItem(
                id: manifest.itemID,
                filename: filename,
                phase: phase,
                createdAt: manifest.createdAt,
                byteCount: byteCount,
                hasLocalCopy: hasLocalCopy,
                isUnadopted: false,
                resumableProgress: snapshot.resumableProgress
            ))
        }

        // Also surface any unadopted ShareImportStore pending/failed items immediately.
        let unadopted = self.store.unadoptedActiveItems(excluding: seenIDs)
        built.append(contentsOf: unadopted)
        self.activeItems = built
    }

    func clearPairingRefused() {
        self.reconcilePairingRefused = false
    }

    func handlePairingChange(currentInstanceID: String) async {
        self.reconcilePairingRefused = false
        await self.transferEngine.clearAuthHold(sourceKey: self.sourceKey)
        guard !currentInstanceID.isEmpty else { return }
        _ = try? await self.transferEngine.resetImportReviewItemsForPairingChange(currentInstanceID: currentInstanceID)
        await self.refreshActiveItems()
    }

    func syncStateDetail() async -> SourceSyncStateDetail {
        await SourceSyncStateDetail.build(from: self.transferEngine, sourceKey: self.sourceKey)
    }

    func dropShare(itemID: UUID) async {
        if await self.transferEngine.itemSnapshot(itemID: itemID) != nil {
            await self.transferEngine.drop(itemID: itemID)
        } else {
            self.store.dropItem(itemID: itemID)
        }
        await self.refreshActiveItems()
    }

    /// `false` when the item is still held after the attempt.
    @discardableResult
    func retryShare(itemID: UUID) async -> Bool {
        let retried = (try? await self.transferEngine.retryAttention(itemID: itemID)) ?? false
        await self.refreshActiveItems()
        return retried
    }

    /// Re-sends a held `.reviewExpired` (or save-then-start) import cleanly from `/save` + `/start`.
    @discardableResult
    func sendAgain(itemID: UUID) async -> Bool {
        let sent = (try? await self.transferEngine.sendAgain(itemID: itemID)) ?? false
        await self.refreshActiveItems()
        return sent
    }

    /// Safely reconciles `.readyToReview` items against `GET /app/import/api/<id>` when paired,
    /// mark-confirmed, connected, and not pairing-refused. Runs even when `waiting == 0`.
    func reconcileReadyToReview(
        localPort: Int?,
        instanceID: String,
        isPaired: Bool,
        markConfirmed: Bool,
        fetchStatus: @escaping @Sendable (Int, String) async -> ImportStatusFetchResult = { port, importID in
            await AuthenticatedHomeClient().fetchImportStatus(localPort: port, importID: importID)
        }
    ) async {
        guard isPaired,
              markConfirmed,
              !self.isPairingRefused,
              !instanceID.isEmpty,
              let localPort
        else {
            return
        }
        if self.isReconciling {
            self.reconcilePendingAgain = true
            return
        }
        self.isReconciling = true
        defer {
            self.isReconciling = false
        }

        while true {
            self.reconcilePendingAgain = false
            let candidates = await self.transferEngine.readyToReviewCandidates(
                sourceKey: self.sourceKey,
                instanceID: instanceID
            )
            guard !candidates.isEmpty else {
                await self.refreshActiveItems()
                break
            }

            var haltedForAuth = false
            for candidate in candidates {
                let result = await fetchStatus(localPort, candidate.importID)
                switch ImportReconciliationClassifier.classify(result) {
                case .confirmed:
                    let store = self.store
                    _ = try? await self.transferEngine.confirmReadyToReviewItem(
                        itemID: candidate.itemID,
                        expectedImportID: candidate.importID,
                        expectedInstanceID: candidate.savedInstanceID,
                        persistReceipt: { manifest, confirmedImportID in
                            try await MainActor.run {
                                try store.recordConfirmedImport(
                                    manifest: manifest,
                                    importID: confirmedImportID,
                                    instanceID: candidate.savedInstanceID
                                )
                            }
                        }
                    )
                case .expired:
                    _ = try? await self.transferEngine.markReviewExpired(
                        itemID: candidate.itemID,
                        expectedImportID: candidate.importID,
                        expectedInstanceID: candidate.savedInstanceID
                    )
                case .pairingRefused:
                    self.reconcilePairingRefused = true
                    await self.transferEngine.markAuthHeld(sourceKey: self.sourceKey)
                    haltedForAuth = true
                case .keepReadyToReview, .unchanged:
                    break
                }
                if haltedForAuth {
                    break
                }
            }
            await self.refreshActiveItems()
            if haltedForAuth || !self.reconcilePendingAgain {
                break
            }
        }
    }

    func onThisPhoneSourceSnapshot() async -> OnThisPhoneSourceResult {
        let storeResult = self.store.onThisPhoneSourceSnapshot()
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: self.sourceKey)
        let transferItems = await ShareTransferSnapshotMapper.items(snapshots: snapshots, engine: self.transferEngine)
        if case .failed = storeResult, transferItems.isEmpty {
            return .failed
        }
        return OnThisPhoneSnapshotAggregator.combinedResult(storeResult, .loaded(items: transferItems))
    }

    private var status: TransferSourceStatusSnapshot {
        self.mirror.sources[self.sourceKey] ?? TransferSourceStatusSnapshot(
            queuedCount: 0,
            attentionCount: 0,
            inFlightCount: 0,
            deliveredCount: 0,
            droppedCount: 0,
            lastDeliveredAt: nil,
            lastErrorDetail: nil,
            recentErrorCount: 0,
            bytesPerSecond: 0
        )
    }
}

nonisolated enum ShareTransferSnapshotMapper {
    @MainActor
    static func items(snapshots: [TransferItemSnapshot], engine: TransferEngine) async -> [OnThisPhoneItem] {
        var items: [OnThisPhoneItem] = []
        for snapshot in snapshots {
            let manifest = snapshot.manifest
            guard let part = manifest.payloadParts.first,
                  let fields = try? ShareImportTransferMetadata.fields(from: manifest)
            else {
                continue
            }
            let rawURL = await engine.payloadFileURL(itemID: snapshot.itemID, partID: part.partID)
            let attention = manifest.attention
            let failureReason = attention.map { $0.ownerFailureReason(totalBytes: fields.bytes) }
            let itemTime: Date?
            if let value = fields.itemTime {
                itemTime = ShareImportStore.parseItemTime(value)
            } else {
                itemTime = nil
            }
            let importID = ShareImportID.validated(attention?.importID ?? manifest.saveThenStart?.savedTimestamp)
            let retryAvailable = snapshot.state == .attention && (attention?.isRetryableAttention ?? true)
            items.append(OnThisPhoneItem(
                id: manifest.itemID.uuidString.lowercased(),
                sourceKind: .share,
                sendState: self.sendState(for: snapshot.state),
                contentType: fields.contentType,
                filename: fields.filename,
                bytes: fields.bytes,
                originApp: fields.originApp,
                basis: fields.basis,
                itemTime: itemTime,
                targetJournal: fields.targetJournal,
                stream: nil,
                day: nil,
                segment: nil,
                deliveredAt: nil,
                rawFileURL: rawURL,
                failureReason: failureReason,
                failureAttemptCount: snapshot.attempts > 0 ? snapshot.attempts : nil,
                retryAvailable: retryAvailable,
                lastAttemptAt: attention?.movedAt,
                refusalPaced: snapshot.refusalPaced,
                importID: importID
            ))
        }
        return OnThisPhoneItemSort.newestFirst(items)
    }

    private static func sendState(for state: TransferRuntimeState) -> OnThisPhoneSendState {
        switch state {
        case .queued, .held, .paused, .salvaged:
            return .savedOnThisPhone
        case .dispatching:
            return .sending
        case .attention:
            return .needsAttention
        case .delivered:
            return .inYourJournal
        case .dropped, .staged:
            return .savedOnThisPhone
        }
    }
}
