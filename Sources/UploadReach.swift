// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum UploadReach: Equatable {
    case reaching
    case failing
    case idle
}

nonisolated func uploadReach(failedTotal: Int, pendingTotal: Int) -> UploadReach {
    if failedTotal > 0 {
        return .failing
    }
    if pendingTotal > 0 {
        return .reaching
    }
    return .idle
}

@MainActor
func uploadTotals(
    observer: ObserverUploader,
    omi: OmiUploaderHolder,
    importQueue: ImportQueue,
    location: LocationUploader
) -> (failed: Int, pending: Int) {
    (
        failed: observer.failedCount + omi.failedCount + importQueue.failedCount + location.failedCount,
        pending: observer.pendingCount + omi.pendingCount + importQueue.pendingCount + location.pendingCount
    )
}

@MainActor
func uploadFailedTotal(
    observer: ObserverUploader,
    omi: OmiUploaderHolder,
    importQueue: ImportQueue,
    location: LocationUploader
) -> Int {
    uploadTotals(
        observer: observer,
        omi: omi,
        importQueue: importQueue,
        location: location
    ).failed
}

@MainActor
func uploadReach(
    observer: ObserverUploader,
    omi: OmiUploaderHolder,
    importQueue: ImportQueue,
    location: LocationUploader
) -> UploadReach {
    let totals = uploadTotals(
        observer: observer,
        omi: omi,
        importQueue: importQueue,
        location: location
    )
    return uploadReach(failedTotal: totals.failed, pendingTotal: totals.pending)
}
