// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Owner-facing words for the Safari source. Shared words (pause, state words, block
/// titles) come from `SourceVocabulary` and `LocationVocabulary`.
nonisolated enum SafariVocabulary {
    static let label = "Safari"
    static let valueLine = "on the sites you allow in Safari, the solstone extension takes in the page's text and rough layout, and all of it goes into your journal."
    static let setUpHeader = "set it up"
    static let setUpStepOne = "in Settings, open Apps, then Safari, then Extensions, then solstone, and turn it on."
    static let setUpStepTwo = "in Safari, open the page menu, tap solstone, and agree to what it takes in. then, on a site you want in your journal, open solstone the same way, add the site and allow it."
    static let setUpFootnote = "this page updates by itself once the solstone extension is on in Safari."
    static let whileClosed = "while this is on, the solstone extension keeps taking in the sites you allow, even when this app is closed. pages wait on this device and go into your journal the next time you open this app."
    static let privateBrowsing = "the solstone extension takes in nothing from private browsing."
    static let activeSubtextPaired = "adds pages from the sites you allow to your journal"
    static let notPaired = "nothing is taken in until you pair."
    static let awaitingMark = "starts once you confirm your journal's mark."
    static let full = "this device is out of storage for Safari pages. free up some space and new pages go into your journal again."
    static let fullCompact = "out of storage."
    static let unreadable = "this app can't check for Safari pages on this device right now."
    static let unreadableCompact = "can't check right now."
    static let noPageYet = "no pages from Safari yet."
    static let waiting = "some pages are waiting on this device."
    static let nothingWaiting = "nothing from Safari is waiting on this device."
    static let pauseHint = "the solstone extension stops taking in new pages. pages already on this device still go into your journal."
    static let resumeHint = "pages from the sites you allow go into your journal again."

    static func activeSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? self.activeSubtextPaired : self.notPaired
    }

    static func lastPage(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "last page from Safari: \(CalendarVocabulary.lastCheckedTime(date, now: now, calendar: calendar))"
    }
}

/// The Safari source as the app shows it, read from the store the extension writes.
@MainActor
@Observable
final class SafariSourceModel {
    /// `nil` when the shared store could not be read.
    private(set) var snapshot: SafariBrowserSnapshot?
    @ObservationIgnored private let load: () throws -> SafariBrowserSnapshot
    @ObservationIgnored private let writePause: (Bool) throws -> Void

    init(load: @escaping () throws -> SafariBrowserSnapshot = { try SafariBrowserStore().snapshot() },
         writePause: @escaping (Bool) throws -> Void = { try SafariBrowserStore().setPaused($0) }) {
        self.load = load
        self.writePause = writePause
        self.refresh()
    }

    func refresh() {
        let next = try? self.load()
        if next != self.snapshot { self.snapshot = next }
    }

    func setPaused(_ paused: Bool) {
        do { try self.writePause(paused) } catch {}
        self.refresh()
    }

    /// Whether the owner has turned the extension on: only its hello says so.
    var isSetUp: Bool { self.snapshot?.lastContact != nil }

    /// The Safari source exists only in a build that carries the extension.
    nonisolated static var isBundled: Bool {
        Bundle.main.builtInPlugInsURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SolstoneSafariExtension.appex").path)
        } ?? false
    }
}

/// What the Safari tile and page show, from the store.
nonisolated struct SafariSourceStatus: Equatable, Sendable {
    let sourceState: SourceState
    /// The page's full reason; the tile shows `compactAttention`.
    let attention: String?
    var compactAttention: String? {
        switch self.attention {
        case SafariVocabulary.full: SafariVocabulary.fullCompact
        case SafariVocabulary.unreadable: SafariVocabulary.unreadableCompact
        default: self.attention
        }
    }

    init(snapshot: SafariBrowserSnapshot?) {
        guard let snapshot else {
            self.sourceState = .needsAttention
            self.attention = SafariVocabulary.unreadable
            return
        }
        if snapshot.lastContact == nil {
            self.sourceState = .readyToSetUp
            self.attention = nil
        } else if snapshot.paused {
            self.sourceState = .paused
            self.attention = nil
        } else if !snapshot.confirmed {
            // Pairing and the mark are what let the extension take anything in.
            self.sourceState = .off
            self.attention = nil
        } else if snapshot.full {
            self.sourceState = .needsAttention
            self.attention = SafariVocabulary.full
        } else {
            self.sourceState = .active
            self.attention = nil
        }
    }
}

nonisolated func safariSourceModel(snapshot: SafariBrowserSnapshot?, isJournalPaired: Bool) -> Source {
    let status = SafariSourceStatus(snapshot: snapshot)
    var subtext = status.compactAttention
    if subtext == nil, status.sourceState == .off {
        subtext = isJournalPaired ? SafariVocabulary.awaitingMark : SafariVocabulary.notPaired
    }
    return Source(
        id: "safari",
        displayName: SafariVocabulary.label,
        kind: .safari,
        state: status.sourceState,
        isJournalPaired: isJournalPaired,
        activeSubtext: SafariVocabulary.activeSubtext(isJournalPaired: isJournalPaired),
        subtextOverride: subtext,
        attention: status.attention.map { SourceAttention(message: $0) },
        pendingStatus: .nonePending
    )
}
