// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class MobileSegmentTransferHolder: ObserverQueueHealthProviding {
    let transferEngine: TransferEngine
    private let mirror: TransferStatusMirror
    private let uploader: MobileSegmentUploader
    private let sourceKey: String

    init(
        transferEngine: TransferEngine,
        mirror: TransferStatusMirror,
        uploader: MobileSegmentUploader,
        sourceKey: String = ObserverAudioTransferSource.mobileSegment
    ) {
        self.transferEngine = transferEngine
        self.mirror = mirror
        self.uploader = uploader
        self.sourceKey = sourceKey
    }

    var pendingCount: Int {
        self.status.queuedCount
    }

    /// No-double-count invariant: a segment is either a store `failed/` dir
    /// that was never enqueued, or an engine item. Once enqueue succeeds the
    /// store dir is removed; the engine records queued state only after
    /// `commitStagedItem` succeeds.
    var failedCount: Int {
        self.status.attentionCount + self.uploader.finalizeFailedCount
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

    var lastError: String? {
        self.status.lastErrorDetail
    }

    var lastUploadAt: Date? {
        self.status.lastDeliveredAt
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
