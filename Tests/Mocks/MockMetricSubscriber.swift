// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockMetricSubscriber: MetricSubscribing {
    var addSubscriberCallCount = 0
    var removeSubscriberCallCount = 0
    var ingest: (@MainActor @Sendable ([ProblemReportPayloadInput]) -> Void)?

    func addSubscriber() {
        self.addSubscriberCallCount += 1
    }

    func removeSubscriber() {
        self.removeSubscriberCallCount += 1
    }

    func emit(_ inputs: [ProblemReportPayloadInput]) {
        self.ingest?(inputs)
    }
}
