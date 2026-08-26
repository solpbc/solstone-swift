// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class WatchUploaderHolder {
    let transferEngine: TransferEngine
    private let mirror: TransferStatusMirror
    private let sourceKey: String
    var removeStaging: (@MainActor @Sendable (UUID) -> Void)?

    init(
        transferEngine: TransferEngine,
        mirror: TransferStatusMirror,
        sourceKey: String = ObserverAudioTransferSource.watch
    ) {
        self.transferEngine = transferEngine
        self.mirror = mirror
        self.sourceKey = sourceKey
    }

    var pendingCount: Int {
        self.status.queuedCount
    }

    var failedCount: Int {
        self.status.attentionCount
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
        self.status.lastDeliveredAt
    }

    var lastError: String? {
        self.status.lastErrorDetail
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
