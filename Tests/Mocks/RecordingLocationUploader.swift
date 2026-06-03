// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import os

final class RecordingLocationUploader: @unchecked Sendable, LocationUploading {
    private let lock = OSAllocatedUnfairLock<[LocationSegmentBatch]>(initialState: [])

    func enqueue(_ batch: LocationSegmentBatch) async {
        self.lock.withLock {
            $0.append(batch)
        }
    }

    func batches() -> [LocationSegmentBatch] {
        self.lock.withLock { $0 }
    }

    func batchCount() -> Int {
        self.lock.withLock { $0.count }
    }
}
