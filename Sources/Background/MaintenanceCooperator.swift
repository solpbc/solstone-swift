// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

final class MaintenanceCooperator: @unchecked Sendable {
    let chunkSize: Int

    private struct State: Sendable {
        var stepCount = 0
        var checkpointCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onCheckpoint: (@MainActor () -> Void)?

    init(chunkSize: Int = 25, onCheckpoint: (@MainActor () -> Void)? = nil) {
        self.chunkSize = max(1, chunkSize)
        self.onCheckpoint = onCheckpoint
    }

    var checkpointCount: Int {
        self.state.withLock { $0.checkpointCount }
    }

    func step() async {
        let shouldCheckpoint = self.state.withLock { state in
            state.stepCount += 1
            guard state.stepCount.isMultiple(of: self.chunkSize) else { return false }
            state.checkpointCount += 1
            return true
        }

        guard shouldCheckpoint else { return }
        await Task.yield()
        guard let onCheckpoint else { return }
        await MainActor.run {
            onCheckpoint()
        }
    }
}
