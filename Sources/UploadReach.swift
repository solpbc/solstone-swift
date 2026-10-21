// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func uploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder? = nil
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + watch.failedCount + share.failedCount + (calendar?.failedCount ?? 0),
        pending: mobileSegment.pendingCount + watch.pendingCount + share.pendingCount + (calendar?.pendingCount ?? 0)
    )
}

/// What the background drain and finish-syncing wait on: `uploadTotals` less the refusals the
/// engine is pacing and the calendar files no drain sends: those held until the journal takes
/// them, and import files held while calendar is paused or cannot read. The owner's held count
/// stays `uploadTotals`.
@MainActor
func sendableUploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder? = nil
) -> (failed: Int, pending: Int) {
    let totals = uploadTotals(mobileSegment: mobileSegment, watch: watch, share: share, calendar: calendar)
    let paced = mobileSegment.refusalPacedCount + watch.refusalPacedCount + share.refusalPacedCount
        + (calendar?.refusalPacedCount ?? 0)
    let held = calendar?.unsendableCount ?? 0
    return (failed: max(0, totals.failed - paced), pending: max(0, totals.pending - held))
}

@MainActor
func captureUploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    calendar: CalendarTransferHolder? = nil
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + watch.failedCount + (calendar?.failedCount ?? 0),
        pending: mobileSegment.pendingCount + watch.pendingCount + (calendar?.pendingCount ?? 0)
    )
}

@MainActor
func confirmedTransferCount(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder? = nil
) -> Int {
    confirmedTransferCount(
        mobileSegment: mobileSegment.confirmedActiveTransferCount,
        watch: watch.confirmedActiveTransferCount,
        share: share.confirmedActiveTransferCount
    ) + (calendar?.confirmedActiveTransferCount ?? 0)
}

nonisolated func confirmedTransferCount(
    mobileSegment: Int,
    watch: Int,
    share: Int
) -> Int {
    mobileSegment + watch + share
}

@MainActor
func recentBytesTotal(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder? = nil
) -> Double {
    recentBytesTotal(
        mobileSegment: mobileSegment.recentBytesPerSecond,
        watch: watch.recentBytesPerSecond,
        share: share.recentBytesPerSecond
    ) + (calendar?.recentBytesPerSecond ?? 0)
}

nonisolated func recentBytesTotal(
    mobileSegment: Double,
    watch: Double,
    share: Double
) -> Double {
    mobileSegment + watch + share
}

nonisolated struct TransferBackoffStatus: Equatable, Sendable {
    var backoffPendingCount: Int
    var endpointHeld: Bool
}

@MainActor
func uploadBackoff(mirror: TransferStatusMirror) -> TransferBackoffStatus {
    TransferBackoffStatus(
        backoffPendingCount: mirror.backoffPendingCount,
        endpointHeld: mirror.endpointHeld
    )
}

@MainActor
func uploadInFlight(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder,
    calendar: CalendarTransferHolder? = nil
) -> Int {
    mobileSegment.inFlightCount + watch.inFlightCount + share.inFlightCount + (calendar?.inFlightCount ?? 0)
}

@MainActor
func uploadFailedTotal(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    uploadTotals(
        mobileSegment: mobileSegment,
        watch: watch,
        share: share
    ).failed
}

nonisolated func lastSyncedAt(_ dates: [Date?]) -> Date? {
    dates.compactMap { $0 }.max()
}

@MainActor
func lastSyncedAt(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        watch.lastUploadAt,
        share.lastUploadAt,
    ])
}

@MainActor
func lastCaptureSyncedAt(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        watch.lastUploadAt,
    ])
}
