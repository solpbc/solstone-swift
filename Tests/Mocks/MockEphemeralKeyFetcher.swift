// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

final class MockEphemeralKeyFetcher: EphemeralKeyFetching, @unchecked Sendable {
    var result: Result<String, Error> = .success("test-key")
    var fetchCallCount = 0
    var delay: Duration?

    func fetchKey(localPort: Int) async throws -> String {
        self.fetchCallCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try self.result.get()
    }
}
