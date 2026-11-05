// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SafariServices

/// Owner-facing words for the Safari source. Shared words (pause, state words, block
/// titles) come from `SourceVocabulary` and `LocationVocabulary`.
nonisolated enum SafariVocabulary {
    static let label = "Safari"
    static let valueLine = "on the sites you allow in Safari, the solstone extension takes in the page's text and rough layout, and all of it goes into your journal."
    static let stepTurnOn = "turn on the extension"
    static let stepTurnOnBody = "one switch in Settings. flip it, then come back here."
    static let switchName = "Allow Extension"
    static let openSettings = "open Settings"
    static let appleWarning = "Apple's page warns about what an extension could read. you choose the sites."
    static let notOnYet = "not on yet. the switch is Allow Extension."
    static let settingsByHand = "in Safari, open the page menu, then Manage Extensions, and turn on solstone."
    static let stepAddSite = "add your first site"
    static let siteField = "which site?"
    static let sitePlaceholder = "nytimes.com"
    static let tapPageMenu = "page menu"
    static let tapSolstone = "solstone"
    static let tapAdd = "add this site"
    static let tapAlwaysAllow = "Always Allow"
    static let safariAsks = "Safari's prompt warns about reading that site. choose Always Allow so it keeps working when you come back."
    static let openInSafari = "open in Safari"
    static let working = "it's working."
    static let workingBody = "your first page just came in. it's on its way to your journal."
    static let addAnother = "add another site"
    static let whileClosed = "while this is on, the solstone extension keeps taking in pages from the sites you allow, even when this app is closed. pages wait on this device and go into your journal the next time you open this app."
    static let privateBrowsing = "the solstone extension takes in nothing from private browsing."
    static let activeSubtextPaired = "adds pages from the sites you allow to your journal."
    static let notPaired = "nothing is taken in until you pair."
    static let awaitingMark = "starts once you confirm your journal's mark."
    static let full = "this device is out of storage for Safari pages. free up some space and new pages go into your journal again."
    static let fullCompact = "out of storage."
    static let unreadable = "this app can't check for Safari pages on this device right now."
    static let unreadableCompact = "can't check right now."
    static let noPageYet = "no pages from Safari yet. on a site you want in your journal, open solstone from Safari's page menu and add it."
    static let waiting = "some pages are waiting on this device."
    static let nothingWaiting = "nothing from Safari is waiting on this device."
    static let pauseHint = "the solstone extension stops taking in new pages. pages already on this device still go into your journal."
    static let resumeHint = "pages from the sites you allow go into your journal again."

    static func waitingFor(_ site: String) -> String {
        "waiting for a page from \(site)."
    }

    static func activeSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? self.activeSubtextPaired : self.notPaired
    }

    static func lastPage(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "last page from Safari: \(CalendarVocabulary.lastCheckedTime(date, now: now, calendar: calendar))"
    }
}

/// What Apple lets the app do about the extension: read its switch and open its page.
/// Both arrived in iOS 26.2. Before that, only the extension's first hello says it's on.
nonisolated enum SafariExtensionControl {
    private static var identifier: String { (Bundle.main.bundleIdentifier ?? "app.solstone.swift") + ".safari" }

    static var canOpenSettings: Bool {
        if #available(iOS 26.2, *) { return true }
        return false
    }

    static func isOn() async -> Bool? {
        guard #available(iOS 26.2, *) else { return nil }
        return try? await SFSafariExtensionManager.stateOfExtension(withIdentifier: self.identifier).isEnabled
    }

    static func openSettings() async -> Bool {
        guard #available(iOS 26.2, *) else { return false }
        do {
            try await SFSafariSettings.openExtensionsSettings(forIdentifiers: [self.identifier])
            return true
        } catch {
            return false
        }
    }
}

/// The first site the owner names during setup, as a bare host.
nonisolated enum SafariFirstSite {
    static func host(from typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        let host = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host
    }

    /// Safari's own scheme first, so another default browser or a site's app doesn't take it.
    static func urls(for host: String) -> [URL] {
        ["x-safari-https://\(host)", "https://\(host)"].compactMap(URL.init(string:))
    }
}

/// Which setup step the owner is on. Setup lasts until the first page comes in.
nonisolated enum SafariSetUpStep: Equatable, Sendable {
    case turnOn
    case addSite

    init(snapshot: SafariBrowserSnapshot?, extensionOn: Bool?) {
        self = extensionOn == true || snapshot?.lastContact != nil ? .addSite : .turnOn
    }

    static func isShown(snapshot: SafariBrowserSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.lastAccepted == nil && !snapshot.paused && !snapshot.full
    }
}

/// The Safari source as the app shows it, read from the store the extension writes.
@MainActor
@Observable
final class SafariSourceModel {
    /// `nil` when the shared store could not be read.
    private(set) var snapshot: SafariBrowserSnapshot?
    /// `nil` where the system can't say.
    private(set) var extensionOn: Bool?
    @ObservationIgnored private let load: () throws -> SafariBrowserSnapshot
    @ObservationIgnored private let writePause: (Bool) throws -> Void
    @ObservationIgnored private let readExtensionOn: () async -> Bool?
    @ObservationIgnored private let openSettings: () async -> Bool

    init(load: @escaping () throws -> SafariBrowserSnapshot = { try SafariBrowserStore().snapshot() },
         writePause: @escaping (Bool) throws -> Void = { try SafariBrowserStore().setPaused($0) },
         readExtensionOn: @escaping () async -> Bool? = { await SafariExtensionControl.isOn() },
         openSettings: @escaping () async -> Bool = { await SafariExtensionControl.openSettings() }) {
        self.load = load
        self.writePause = writePause
        self.readExtensionOn = readExtensionOn
        self.openSettings = openSettings
        self.refresh()
    }

    func refreshExtensionState() async {
        let next = await self.readExtensionOn()
        if next != self.extensionOn { self.extensionOn = next }
    }

    func openExtensionSettings() async -> Bool {
        await self.openSettings()
    }

    func refresh() {
        let next = try? self.load()
        if next != self.snapshot { self.snapshot = next }
    }

    func setPaused(_ paused: Bool) {
        do { try self.writePause(paused) } catch {}
        self.refresh()
    }

    /// Whether the extension has ever answered.
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
        } else if snapshot.lastAccepted == nil {
            self.sourceState = .readyToSetUp
            self.attention = nil
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
