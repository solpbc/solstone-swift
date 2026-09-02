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
            mostRecentAttentionLastRetriedAt: representative?.manifest.lastRetriedAt
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
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    now: Date = Date(),
    transferEngine: TransferEngine? = nil,
    launchCaptureRootURL: URL? = nil
) async -> [String] {
    let rows: [(name: String, pending: Int, inFlight: Int, attention: Int, delivered: Int, lastUploadAt: Date?, recentErrorCount: Int, recentErrorDetail: String?, detail: SourceSyncStateDetail)] = await [
        (
            "audio", mobileSegment.pendingCount, mobileSegment.inFlightCount, mobileSegment.failedCount,
            mobileSegment.deliveredCount, mobileSegment.lastUploadAt, mobileSegment.recentErrorCount,
            mobileSegment.lastError, mobileSegment.syncStateDetail()
        ),
        (
            "omi pendant", omi.pendingCount, omi.inFlightCount, omi.failedCount,
            omi.deliveredCount, omi.lastUploadAt, omi.recentErrorCount,
            omi.lastError, omi.syncStateDetail()
        ),
        (
            "watch", watch.pendingCount, watch.inFlightCount, watch.failedCount,
            watch.deliveredCount, watch.lastUploadAt, watch.recentErrorCount,
            watch.lastError, watch.syncStateDetail()
        ),
        (
            "share", share.pendingCount, share.inFlightCount, share.failedCount,
            share.deliveredCount, share.lastUploadAt, share.recentErrorCount,
            share.lastError, share.syncStateDetail()
        ),
    ]

    var lines: [String] = ["--- sync state by source ---"]
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
    }
    if lines.count == 1 {
        lines.append("(nothing waiting on any source)")
    }
    if let transferEngine, let launchCaptureRootURL {
        let staged = await omiLaunchCaptureStagedCount(
            engine: transferEngine,
            launchCaptureRootURL: launchCaptureRootURL
        )
        if staged > 0 {
            lines.append("omi pendant staged: staged=\(staged)")
        }
    }
    return lines
}

func omiLaunchCaptureStagedCount(engine: TransferEngine, launchCaptureRootURL: URL) async -> Int {
    let owned = Set((await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)).map(\.itemID))
    let reserved = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: launchCaptureRootURL)
    var count = 0
    for root in [launchCaptureRootURL, reserved] {
        let materialized = root.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: materialized.path),
              let generations = try? FileManager.default.contentsOfDirectory(
                at: materialized,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { continue }
        for generation in generations {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: generation,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == OmiPendingHandoffEnvelope.pathExtension {
                guard let envelope = try? OmiPendingHandoffStore.read(from: file), envelope.isSupported else { continue }
                if owned.contains(envelope.itemID) { continue }
                count += 1
            }
        }
    }
    return count
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
