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
    /// Retained items on this source whose segment name is not in the wire form, by why the
    /// repair left them alone.
    var unrepairedSegmentNames = UnrepairedSegmentNameCounts()
    /// The spool-wide tally of segment names rewritten. Every source reads the same spool.
    var segmentRepairTally = SegmentRepairTally.empty

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
            refusedItems: RefusedItemsExport(manifests: attentionSnapshots.map(\.manifest)),
            unrepairedSegmentNames: await transferEngine.unrepairedSegmentNameCounts(sourceKey: sourceKey),
            segmentRepairTally: await transferEngine.segmentRepairTally()
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
    /// Evaluated against the export's own `now`, so an old error does not read as recent.
    let recentError: TransferRecentError?
    let detail: SourceSyncStateDetail
}

nonisolated func age(from: Date, to: Date) -> String {
    let seconds = max(0, Int(to.timeIntervalSince(from)))
    if seconds < 60 { return AppStrings.ios_diagnostics_age_seconds(String(seconds)) }
    if seconds < 3600 { return AppStrings.ios_diagnostics_age_minutes(String(seconds / 60)) }
    return AppStrings.ios_diagnostics_age_hours(String(seconds / 3600), String((seconds % 3600) / 60))
}

@MainActor
func syncStateSummaryLines(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder?,
    now: Date
) async -> [String] {
    var rows: [SourceSyncStateLine] = await [
        SourceSyncStateLine(
            name: AppStrings.ios_diagnostics_sync_source_audio(), pending: mobileSegment.pendingCount, inFlight: mobileSegment.inFlightCount,
            attention: mobileSegment.failedCount, delivered: mobileSegment.deliveredCount,
            lastUploadAt: mobileSegment.lastUploadAt, recentError: mobileSegment.recentError(now: now),
            detail: mobileSegment.syncStateDetail()
        ),
        SourceSyncStateLine(
            name: AppStrings.ios_diagnostics_sync_source_watch(), pending: watch.pendingCount, inFlight: watch.inFlightCount,
            attention: watch.failedCount, delivered: watch.deliveredCount,
            lastUploadAt: watch.lastUploadAt, recentError: watch.recentError(now: now),
            detail: watch.syncStateDetail()
        ),
        SourceSyncStateLine(
            name: AppStrings.ios_diagnostics_sync_source_share(), pending: share.pendingCount, inFlight: share.inFlightCount,
            attention: share.failedCount, delivered: share.deliveredCount,
            lastUploadAt: share.lastUploadAt, recentError: share.recentError(now: now),
            detail: share.syncStateDetail()
        ),
    ]
    if let calendar {
        rows.append(await SourceSyncStateLine(
            name: AppStrings.ios_diagnostics_sync_source_calendar(), pending: calendar.pendingCount, inFlight: calendar.inFlightCount,
            attention: calendar.failedCount, delivered: calendar.deliveredCount,
            lastUploadAt: calendar.lastUploadAt, recentError: calendar.recentError(now: now),
            detail: calendar.syncStateDetail()
        ))
    }
    return syncStateSummaryLines(rows: rows, now: now)
}

/// The "sync state by source" block, one entry per source with anything to report.
nonisolated func syncStateSummaryLines(rows: [SourceSyncStateLine], now: Date) -> [String] {
    var lines: [String] = [AppStrings.ios_diagnostics_sync_heading()]
    var listedRefusedItems = false
    for row in rows where row.pending + row.inFlight + row.attention + row.delivered > 0 {
        let line: String
        switch (row.detail.oldestPendingItemCreatedAt, row.lastUploadAt) {
        case (.some(let oldest), .some(let last)):
            line = AppStrings.ios_diagnostics_sync_summary_oldest_delivered(row.name, String(row.pending), String(row.inFlight), String(row.attention), String(row.delivered), age(from: oldest, to: now), age(from: last, to: now))
        case (.some(let oldest), .none):
            line = AppStrings.ios_diagnostics_sync_summary_oldest_never(row.name, String(row.pending), String(row.inFlight), String(row.attention), String(row.delivered), age(from: oldest, to: now))
        case (.none, .some(let last)):
            line = AppStrings.ios_diagnostics_sync_summary_plain_delivered(row.name, String(row.pending), String(row.inFlight), String(row.attention), String(row.delivered), age(from: last, to: now))
        case (.none, .none):
            line = AppStrings.ios_diagnostics_sync_summary_plain_never(row.name, String(row.pending), String(row.inFlight), String(row.attention), String(row.delivered))
        }
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
        } else if let recentError = row.recentError {
            lines.append(
                AppStrings.ios_diagnostics_sync_recent(row.name, recentError.detail, age(from: recentError.at, to: now), String(recentError.count))
            )
        }

        lines.append(contentsOf: row.detail.refusedItems.lines(sourceName: row.name, now: now))
        listedRefusedItems = listedRefusedItems || !row.detail.refusedItems.listed.isEmpty
    }
    if lines.count == 1 {
        lines.append(AppStrings.ios_diagnostics_syncstatesummarylines())
    }
    // The tally is the spool's and every source reads the same one; the unrepaired counts are
    // per source and add up. Not tied to which sources have anything waiting: the tally outlives
    // the items it counts.
    lines.append(contentsOf: SegmentRepairExport(
        tally: rows.map(\.detail.segmentRepairTally).first { !$0.isEmpty } ?? .empty,
        unrepaired: rows.reduce(UnrepairedSegmentNameCounts()) { $0 + $1.detail.unrepairedSegmentNames }
    ).lines(now: now))
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
    let movedAge = age(from: info.movedAt, to: now)
    if retryCount > 0, let lastRetriedAt {
        return AppStrings.ios_diagnostics_stuck_retried_items(attentionItemCount, name, info.reason, info.exportedDetail, movedAge, String(retryCount), age(from: lastRetriedAt, to: now))
    }
    return AppStrings.ios_diagnostics_stuck_items(attentionItemCount, name, info.reason, info.exportedDetail, movedAge)
}

/// Copy and share build the same report, sync block included, from state at the moment the owner acts.
@MainActor
func diagnosticsReport(
    log: DiagnosticLog,
    tunnel: TunnelManager,
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder?,
    now: Date
) async -> String {
    let syncState = await syncStateSummaryLines(
        mobileSegment: mobileSegment, watch: watch, share: share, calendar: calendar, now: now
    )
    return await log.report(tunnel: tunnel, syncState: syncState, now: now)
}

@MainActor
func diagnosticsExportFile(
    log: DiagnosticLog,
    tunnel: TunnelManager,
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder?,
    now: Date
) async -> URL? {
    let syncState = await syncStateSummaryLines(
        mobileSegment: mobileSegment, watch: watch, share: share, calendar: calendar, now: now
    )
    return await log.exportFile(tunnel: tunnel, syncState: syncState, now: now)
}
