// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Swift 6.2-safe async wrapper for awaiting a `DispatchSemaphore` signaled by a synchronous
/// off-main callback without calling `DispatchSemaphore.wait` inside an async context.
nonisolated enum TestSemaphore {
    static func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: timeout))
            }
        }
    }

    static func wait(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}
