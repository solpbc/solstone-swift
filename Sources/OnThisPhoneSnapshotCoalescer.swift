// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Coalesces bursty count-change triggers into at most one snapshot scan per
/// `interval`, with a guaranteed trailing scan. Leading-delayed: the first
/// trigger of a window schedules a scan; further triggers while one is pending
/// are dropped because the pending scan reads live state when it fires.
/// Owned by `OnThisPhoneMomentsView` as `@State`; the injectable `sleep` makes
/// the bound deterministically testable.
@MainActor
final class OnThisPhoneSnapshotCoalescer {
    private let interval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var task: Task<Void, Never>?

    init(
        interval: Duration = .milliseconds(250),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.sleep = sleep
    }

    /// Schedule `perform` to run after the coalescing window. No-op if a scan is
    /// already pending: that pending scan will observe the latest state.
    func schedule(_ perform: @escaping @MainActor () -> Void) {
        guard self.task == nil else { return }
        self.task = Task { @MainActor in
            await self.sleep(self.interval)
            guard !Task.isCancelled else { return }
            self.task = nil
            perform()
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }
}
