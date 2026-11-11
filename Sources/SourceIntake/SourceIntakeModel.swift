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
    @ObservationIgnored private var changes: SourceIntakeChanges?

    init(store: SourceIntakeStore?, showsSample: Bool? = nil) {
        let sample = showsSample ?? Self.argumentsRequestSample()
        self.showsSample = sample
        self.store = sample ? nil : store
        if sample {
            self.load = .ready(SourceIntakeSample.snapshot())
        } else {
            self.load = store?.load() ?? .ready(.empty)
        }
        // Every source's count moves through the one store, so one listener keeps every row and
        // page that shows a count current while it is on screen, whichever process wrote it.
        if self.store != nil {
            self.changes = SourceIntakeChanges { [weak self] in self?.reload() }
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

/// The store's change notification, observed for as long as this lives.
nonisolated final class SourceIntakeChanges: @unchecked Sendable {
    let handler: @MainActor @Sendable () -> Void

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            sourceIntakeChangedCallback,
            SourceIntakeStore.changedNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(SourceIntakeStore.changedNotificationName as CFString),
            nil
        )
    }
}

private nonisolated let sourceIntakeChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let changes = Unmanaged<SourceIntakeChanges>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in
        changes.handler()
    }
}
