// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class ProblemReportsManager {
    private(set) var reports: [ProblemReport] = []
    private(set) var isEnabled: Bool = false

    @ObservationIgnored private let store: ProblemReportStore
    @ObservationIgnored private var subscriber: (any MetricSubscribing)?
    @ObservationIgnored private var isSubscribed = false
    @ObservationIgnored private var loadGeneration: UInt64 = 0

    init(
        store: ProblemReportStore,
        initialEnabled: Bool = UserSettings.problemReportsEnabled,
        deferInitialLoad: Bool = false,
        makeSubscriber: (@escaping @MainActor @Sendable ([ProblemReportPayloadInput]) -> Void) -> any MetricSubscribing
    ) {
        self.store = store
        if !deferInitialLoad {
            self.reports = store.all()
        }
        self.subscriber = nil
        self.subscriber = makeSubscriber { [weak self] inputs in
            self?.ingest(inputs)
        }
        self.setEnabled(initialEnabled)
    }

    convenience init(
        store: ProblemReportStore,
        subscriber: any MetricSubscribing,
        initialEnabled: Bool = UserSettings.problemReportsEnabled,
        deferInitialLoad: Bool = false
    ) {
        self.init(
            store: store,
            initialEnabled: initialEnabled,
            deferInitialLoad: deferInitialLoad,
            makeSubscriber: { _ in subscriber }
        )
    }

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        guard let subscriber = self.subscriber else { return }
        if enabled {
            guard !self.isSubscribed else { return }
            subscriber.addSubscriber()
            self.isSubscribed = true
        } else {
            guard self.isSubscribed else { return }
            subscriber.removeSubscriber()
            self.isSubscribed = false
        }
    }

    func refresh() {
        self.loadGeneration &+= 1
        self.reports = self.store.all()
    }

    func refreshAsync() async {
        self.loadGeneration &+= 1
        let generation = self.loadGeneration
        let result = await self.store.loadSnapshotOffMain()
        guard generation == self.loadGeneration else { return }
        if result.failedDecodeCount > 0 {
            self.store.reportDecodeFailures(count: result.failedDecodeCount)
        }
        self.reports = result.reports
    }

    func ingest(_ inputs: [ProblemReportPayloadInput]) {
        self.loadGeneration &+= 1
        self.store.ingest(inputs)
        self.refresh()
    }

    func report(id: UUID) -> ProblemReport? {
        self.reports.first { $0.id == id } ?? self.store.report(id: id)
    }

    func delete(id: UUID) {
        self.loadGeneration &+= 1
        self.store.delete(id: id)
        self.refresh()
    }

    func deleteAll() {
        self.loadGeneration &+= 1
        self.store.deleteAll()
        self.refresh()
    }

    func shareURL(for report: ProblemReport) -> URL? {
        self.store.exportFileURL(for: report)
    }

    func shareAllURL() -> URL? {
        self.store.exportAllFileURL(reports: self.reports)
    }
}
