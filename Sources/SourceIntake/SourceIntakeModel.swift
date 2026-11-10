// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// The install's intake totals for the status pane and the source pages.
/// A read never creates the file. Screenshot runs can show a fixed sample and write nothing.
@MainActor
@Observable
final class SourceIntakeModel {
    private let store: SourceIntakeStore?
    private let showsSample: Bool
    private(set) var load: SourceIntakeLoad

    init(store: SourceIntakeStore?, showsSample: Bool? = nil) {
        let sample = showsSample ?? Self.argumentsRequestSample()
        self.showsSample = sample
        self.store = sample ? nil : store
        if sample {
            self.load = .ready(SourceIntakeSample.snapshot())
        } else {
            self.load = store?.load() ?? .ready(.empty)
        }
    }

    var now: Date {
        self.showsSample ? SourceIntakeSample.now : Date()
    }

    func reload() {
        guard !self.showsSample else { return }
        self.load = self.store?.load() ?? .ready(.empty)
    }

    func statusRows(includeSafari: Bool, includeWatch: Bool, locale: Locale, calendar: Calendar) -> [SourceIntakeStatusRow]? {
        guard case .ready(let snapshot) = self.load else { return nil }
        return SourceIntakeRows.statusRows(
            snapshot: snapshot,
            includeSafari: includeSafari,
            includeWatch: includeWatch,
            now: self.now,
            locale: locale,
            calendar: calendar
        )
    }

    func pageFacts(source: SourceIntakeSource, locale: Locale, calendar: Calendar) -> (soFar: String, lastTakenIn: String?)? {
        guard case .ready(let snapshot) = self.load else { return nil }
        return SourceIntakeFormat.page(
            lane: snapshot.lane(source),
            kind: source.kind,
            started: snapshot.started,
            now: self.now,
            locale: locale,
            calendar: calendar
        )
    }

    private static func argumentsRequestSample() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-test") && arguments.contains("--ui-test-intake-sample")
    }
}
