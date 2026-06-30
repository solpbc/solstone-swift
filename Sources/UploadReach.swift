// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum UploadReach: Equatable {
    case reaching
    case idle
}

nonisolated func uploadReach(failedTotal: Int, pendingTotal: Int) -> UploadReach {
    (failedTotal + pendingTotal) > 0 ? .reaching : .idle
}

@MainActor
func uploadTotals(
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + omi.failedCount + watch.failedCount + importQueue.failedCount,
        pending: mobileSegment.pendingCount + omi.pendingCount + watch.pendingCount + importQueue.pendingCount
    )
}

@MainActor
func uploadInFlight(
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    mobileSegment.inFlightCount + omi.inFlightCount + watch.inFlightCount + importQueue.inFlightCount
}

@MainActor
func uploadFailedTotal(
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    uploadTotals(
        mobileSegment: mobileSegment,
        omi: omi,
        watch: watch,
        importQueue: importQueue
    ).failed
}

@MainActor
func uploadReach(
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> UploadReach {
    let totals = uploadTotals(
        mobileSegment: mobileSegment,
        omi: omi,
        watch: watch,
        importQueue: importQueue
    )
    return uploadReach(failedTotal: totals.failed, pendingTotal: totals.pending)
}

nonisolated func lastSyncedAt(_ dates: [Date?]) -> Date? {
    dates.compactMap { $0 }.max()
}

@MainActor
func lastSyncedAt(
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        omi.uploader.lastUploadAt,
        watch.lastUploadAt,
        importQueue.lastDeliveredAt,
    ])
}
