// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class ShareTransferHolder: ObserverQueueHealthProviding {
    let transferEngine: TransferEngine
    let store: ShareImportStore
    private let mirror: TransferStatusMirror
    private let sourceKey: String

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

    /// No-double-count invariant: a share item is in exactly one of three states - a `ShareImportStore` `pending/`/`failed/` row before adoption, a `TransferEngine` item after adoption, or a ledger row after delivery. The legacy directory is removed only after `enqueue` returns non-throwing; the engine records queued state only after `commitStagedItem` succeeds; the ledger row is written only from the delivered hook.
    var failedCount: Int {
        self.status.attentionCount + self.store.failedCount
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

    func dropShare(itemID: UUID) async {
        if await self.transferEngine.itemSnapshot(itemID: itemID) != nil {
            await self.transferEngine.drop(itemID: itemID)
        } else {
            self.store.dropItem(itemID: itemID)
        }
    }

    func retryShare(itemID: UUID) async {
        try? await self.transferEngine.retryAttention(itemID: itemID)
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
            let failureReason = attention.map { info in
                info.reason == info.shortDetail ? info.reason : "\(info.reason): \(info.shortDetail)"
            }
            let itemTime: Date?
            if let value = fields.itemTime {
                itemTime = ShareImportStore.parseItemTime(value)
            } else {
                itemTime = nil
            }
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
                retryAvailable: snapshot.state == .attention,
                lastAttemptAt: attention?.movedAt
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
