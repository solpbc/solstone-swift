// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MetricKit

@MainActor
protocol MetricSubscribing: AnyObject {
    func addSubscriber()
    func removeSubscriber()
}

final class LiveMetricSubscriber: NSObject, MetricSubscribing, MXMetricManagerSubscriber {
    private let manager: MXMetricManager
    private let ingest: @MainActor @Sendable ([ProblemReportPayloadInput]) -> Void

    init(
        manager: MXMetricManager = .shared,
        ingest: @escaping @MainActor @Sendable ([ProblemReportPayloadInput]) -> Void
    ) {
        self.manager = manager
        self.ingest = ingest
        super.init()
    }

    @MainActor
    func addSubscriber() {
        self.manager.add(self)
        var inputs = self.metricInputs(from: self.manager.pastPayloads)
        inputs.append(contentsOf: self.diagnosticInputs(from: self.manager.pastDiagnosticPayloads))
        guard !inputs.isEmpty else { return }
        self.ingest(inputs)
    }

    @MainActor
    func removeSubscriber() {
        self.manager.remove(self)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let inputs = Self.metricInputs(from: payloads, receivedAt: Date())
        guard !inputs.isEmpty else { return }
        Task { @MainActor [ingest] in
            ingest(inputs)
        }
    }

    @available(iOS 14.0, *)
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let inputs = Self.diagnosticInputs(from: payloads, receivedAt: Date())
        guard !inputs.isEmpty else { return }
        Task { @MainActor [ingest] in
            ingest(inputs)
        }
    }
}

private extension LiveMetricSubscriber {
    @MainActor
    func metricInputs(from payloads: [MXMetricPayload]) -> [ProblemReportPayloadInput] {
        Self.metricInputs(from: payloads, receivedAt: Date())
    }

    @MainActor
    func diagnosticInputs(from payloads: [MXDiagnosticPayload]) -> [ProblemReportPayloadInput] {
        Self.diagnosticInputs(from: payloads, receivedAt: Date())
    }

    nonisolated static func metricInputs(from payloads: [MXMetricPayload], receivedAt: Date) -> [ProblemReportPayloadInput] {
        payloads.map {
            ProblemReportPayloadInput(source: .metric, jsonData: $0.jsonRepresentation(), receivedAt: receivedAt)
        }
    }

    nonisolated static func diagnosticInputs(from payloads: [MXDiagnosticPayload], receivedAt: Date) -> [ProblemReportPayloadInput] {
        payloads.map {
            ProblemReportPayloadInput(source: .diagnostic, jsonData: $0.jsonRepresentation(), receivedAt: receivedAt)
        }
    }
}

#if DEBUG
@MainActor
final class NoOpMetricSubscriber: MetricSubscribing {
    func addSubscriber() {}
    func removeSubscriber() {}
}
#endif
