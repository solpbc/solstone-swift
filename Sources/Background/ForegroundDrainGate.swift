// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation

@MainActor
@Observable
final class ForegroundDrainGate {
    @ObservationIgnored private let drive: () async -> Void
    @ObservationIgnored private var isDraining = false
    @ObservationIgnored private var pendingFollowUp = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?

    init(drive: @escaping () async -> Void) {
        self.drive = drive
    }

    func requestDrain() async {
        // Coalesce, don't queue. The gate prevents redundant drain passes and
        // caught-and-logged filesystem move races during foreground catch-up.
        if self.isDraining {
            self.pendingFollowUp = true
            await self.drainTask?.value
            return
        }
        self.isDraining = true
        let task = Task { @MainActor in
            await self.runDrainLoop()
        }
        self.drainTask = task
        await task.value
    }

    private func runDrainLoop() async {
        defer {
            self.pendingFollowUp = false
            self.isDraining = false
            self.drainTask = nil
        }
        while true {
            // Reset before the pass so a segment that fails during this drive
            // is still picked up by exactly one trailing follow-up.
            self.pendingFollowUp = false
            await self.drive()
            guard self.pendingFollowUp else { break }
        }
    }
}
