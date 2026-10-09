// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Per-source detail that requires an actor hop into `TransferEngine` — never
/// mirrored into the synchronous `TransferStatusMirror` the count-only
/// properties on each uploader holder read from. Built once per diagnostics
/// export, not on every UI refresh.
nonisolated struct SourceSyncStateDetail: Sendable {
    let oldestPendingItemCreatedAt: Date?
    let mostRecentAttention: TransferAttentionInfo?
    let attentionItemCount: Int
    let mostRecentAttentionRetryCount: Int
    let mostRecentAttentionLastRetriedAt: Date?
    let refusedItems: RefusedItemsExport

    static func build(from transferEngine: TransferEngine, sourceKey: String) async -> SourceSyncStateDetail {
        let snapshots = await transferEngine.itemSnapshots(sourceKey: sourceKey)
        let oldest = snapshots
            .filter { $0.state != .delivered && $0.state != .dropped }
            .map(\.createdAt)
            .min()
        let attentionSnapshots = snapshots.filter { snapshot in
            snapshot.state == .attention && snapshot.manifest.attention != nil
        }
        let representative = attentionSnapshots.max { lhs, rhs in
            (lhs.manifest.attention?.movedAt ?? .distantPast) < (rhs.manifest.attention?.movedAt ?? .distantPast)
        }
        return SourceSyncStateDetail(
            oldestPendingItemCreatedAt: oldest,
            mostRecentAttention: representative?.manifest.attention,
            attentionItemCount: attentionSnapshots.count,
            mostRecentAttentionRetryCount: representative?.manifest.retryCount ?? 0,
            mostRecentAttentionLastRetriedAt: representative?.manifest.lastRetriedAt,
            refusedItems: RefusedItemsExport(manifests: attentionSnapshots.map(\.manifest))
        )
    }
}

/// One source's counts, for the "sync state by source" block in the exportable
/// diagnostic log. `pending`+`inFlight`+`attention` together are what the home
/// screen's `N waiting to sync` badge sums across every source; `delivered` is
/// this session's running total, not a lifetime count.
nonisolated struct SourceSyncStateLine: Sendable {
    let name: String
    let pending: Int
    let inFlight: Int
    let attention: Int
    let delivered: Int
    let lastUploadAt: Date?
    let recentErrorCount: Int
    let recentErrorDetail: String?
    let detail: SourceSyncStateDetail
}

nonisolated func age(from: Date, to: Date) -> String {
    let seconds = max(0, Int(to.timeIntervalSince(from)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
}

@MainActor
func syncStateSummaryLines(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    now: Date = Date()
) async -> [String] {
    let rows: [SourceSyncStateLine] = await [
        SourceSyncStateLine(
            name: "audio", pending: mobileSegment.pendingCount, inFlight: mobileSegment.inFlightCount,
            attention: mobileSegment.failedCount, delivered: mobileSegment.deliveredCount,
            lastUploadAt: mobileSegment.lastUploadAt, recentErrorCount: mobileSegment.recentErrorCount,
            recentErrorDetail: mobileSegment.lastError, detail: mobileSegment.syncStateDetail()
        ),
        SourceSyncStateLine(
            name: "watch", pending: watch.pendingCount, inFlight: watch.inFlightCount,
            attention: watch.failedCount, delivered: watch.deliveredCount,
            lastUploadAt: watch.lastUploadAt, recentErrorCount: watch.recentErrorCount,
            recentErrorDetail: watch.lastError, detail: watch.syncStateDetail()
        ),
        SourceSyncStateLine(
            name: "share", pending: share.pendingCount, inFlight: share.inFlightCount,
            attention: share.failedCount, delivered: share.deliveredCount,
            lastUploadAt: share.lastUploadAt, recentErrorCount: share.recentErrorCount,
            recentErrorDetail: share.lastError, detail: share.syncStateDetail()
        ),
    ]
    return syncStateSummaryLines(rows: rows, now: now)
}

/// The "sync state by source" block, one entry per source with anything to report.
nonisolated func syncStateSummaryLines(rows: [SourceSyncStateLine], now: Date) -> [String] {
    var lines: [String] = ["--- sync state by source ---"]
    var listedRefusedItems = false
    for row in rows where row.pending + row.inFlight + row.attention + row.delivered > 0 {
        var line = "\(row.name): pending=\(row.pending) inFlight=\(row.inFlight)"
            + " attention=\(row.attention) delivered=\(row.delivered)"
        if let oldest = row.detail.oldestPendingItemCreatedAt {
            line += " oldestWaiting=\(age(from: oldest, to: now))"
        }
        line += row.lastUploadAt.map { " lastDelivered=\(age(from: $0, to: now))ago" } ?? " lastDelivered=never"
        lines.append(line)

        if let info = row.detail.mostRecentAttention {
            lines.append(
                sourceSyncStuckLine(
                    name: row.name,
                    info: info,
                    retryCount: row.detail.mostRecentAttentionRetryCount,
                    lastRetriedAt: row.detail.mostRecentAttentionLastRetriedAt,
                    attentionItemCount: row.detail.attentionItemCount,
                    now: now
                )
            )
        } else if let recentError = row.recentErrorDetail, row.recentErrorCount > 0 {
            lines.append("  \(row.name) recent retry error: \(recentError) (\(row.recentErrorCount) recent)")
        }

        lines.append(contentsOf: row.detail.refusedItems.lines(sourceName: row.name, now: now))
        listedRefusedItems = listedRefusedItems || !row.detail.refusedItems.listed.isEmpty
    }
    if lines.count == 1 {
        lines.append("(nothing waiting on any source)")
    }
    if listedRefusedItems {
        lines.append(RefusedItemsExport.appVersionNote)
    }
    return lines
}

nonisolated func sourceSyncStuckLine(
    name: String,
    info: TransferAttentionInfo,
    retryCount: Int,
    lastRetriedAt: Date?,
    attentionItemCount: Int,
    now: Date
) -> String {
    var line = "  \(name) stuck: \(info.reason), \(info.shortDetail)"
        + " (\(age(from: info.movedAt, to: now)) ago, \(attentionItemCount) item(s))"
    if retryCount > 0, let lastRetriedAt {
        line += ", retried \(retryCount)x, last retry \(age(from: lastRetriedAt, to: now)) ago"
    }
    return line
}
