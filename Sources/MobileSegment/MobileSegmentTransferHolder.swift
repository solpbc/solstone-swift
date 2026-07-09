// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

private struct MobileSegmentFacetTransferCounts: Equatable, Sendable {
    var pendingCount = 0
    var failedCount = 0

    static let empty = MobileSegmentFacetTransferCounts()
}

@MainActor
@Observable
final class MobileSegmentTransferHolder: ObserverQueueHealthProviding {
    let transferEngine: TransferEngine
    private let mirror: TransferStatusMirror
    private let uploader: MobileSegmentUploader
    private let sourceKey: String
    private var facetTransferCounts: [MobileSegmentSource: MobileSegmentFacetTransferCounts] = [:]
    @ObservationIgnored
    private var facetSummaryRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var facetSummaryRefreshApplyCount = -1
    @ObservationIgnored
    private var scheduledFacetSummaryRefreshApplyCount = -1

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
        self.status.queuedCount + self.uploader.pendingCount
    }

    /// No-double-count invariant: a segment is in exactly one of three states:
    /// store `pending/` before enqueue, store `failed/` for finalize failures,
    /// or an engine item. The pending dir is removed only after enqueue returns;
    /// the engine records queued state only after `commitStagedItem` succeeds.
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

    func summary(for source: MobileSegmentSource) -> MobileSegmentSourceSummary {
        self.scheduleFacetSummaryRefreshIfNeeded()
        let storeSummary = self.uploader.summary(for: source)
        let transferCounts = self.facetTransferCounts[source] ?? .empty
        return MobileSegmentSourceSummary(
            pendingCount: storeSummary.pendingCount + transferCounts.pendingCount,
            failedCount: storeSummary.failedCount + transferCounts.failedCount,
            lastUploadAt: self.lastUploadAt,
            lastError: self.lastError
        )
    }

    func refreshFacetSummaries() async {
        let applyCount = self.mirror.applyCount
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: self.sourceKey)
        guard !Task.isCancelled else { return }
        self.applyFacetTransferCounts(from: snapshots)
        self.facetSummaryRefreshApplyCount = applyCount
        self.scheduledFacetSummaryRefreshApplyCount = -1
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

    private func scheduleFacetSummaryRefreshIfNeeded() {
        let applyCount = self.mirror.applyCount
        guard applyCount != self.facetSummaryRefreshApplyCount,
              applyCount != self.scheduledFacetSummaryRefreshApplyCount
        else { return }
        self.scheduledFacetSummaryRefreshApplyCount = applyCount
        self.facetSummaryRefreshTask?.cancel()
        self.facetSummaryRefreshTask = Task { [weak self] in
            await self?.refreshFacetSummaries()
        }
    }

    private func applyFacetTransferCounts(from snapshots: [TransferItemSnapshot]) {
        var counts: [MobileSegmentSource: MobileSegmentFacetTransferCounts] = [:]
        for snapshot in snapshots {
            let sources = Set(snapshot.manifest.payloadParts.compactMap { MobileSegmentSource(payloadKind: $0.kind) })
            for source in sources {
                switch snapshot.state {
                case .queued, .dispatching, .held, .paused, .salvaged, .staged:
                    counts[source, default: .empty].pendingCount += 1
                case .attention:
                    counts[source, default: .empty].failedCount += 1
                case .delivered, .dropped:
                    break
                }
            }
        }
        self.facetTransferCounts = counts
    }
}
