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

    init(
        store: ProblemReportStore,
        initialEnabled: Bool = UserSettings.problemReportsEnabled,
        makeSubscriber: (@escaping @MainActor @Sendable ([ProblemReportPayloadInput]) -> Void) -> any MetricSubscribing
    ) {
        self.store = store
        self.reports = store.all()
        self.subscriber = nil
        self.subscriber = makeSubscriber { [weak self] inputs in
            self?.ingest(inputs)
        }
        self.setEnabled(initialEnabled)
    }

    convenience init(
        store: ProblemReportStore,
        subscriber: any MetricSubscribing,
        initialEnabled: Bool = UserSettings.problemReportsEnabled
    ) {
        self.init(
            store: store,
            initialEnabled: initialEnabled,
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
        self.reports = self.store.all()
    }

    func ingest(_ inputs: [ProblemReportPayloadInput]) {
        self.store.ingest(inputs)
        self.refresh()
    }

    func report(id: UUID) -> ProblemReport? {
        self.reports.first { $0.id == id } ?? self.store.report(id: id)
    }

    func delete(id: UUID) {
        self.store.delete(id: id)
        self.refresh()
    }

    func deleteAll() {
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
