// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import SafariServices

/// Owner-facing words for the Safari source. Shared words (state words, block
/// titles) come from `SourceVocabulary` and `LocationVocabulary`.
nonisolated enum SafariVocabulary {
    static let label = "Safari"
    static let valueLine = "on the sites you allow in Safari, the solstone extension takes in the page's text and rough layout, and all of it goes into your journal."
    static let stepTurnOn = "turn on the extension"
    static let stepTurnOnBody = "one switch in Settings. flip it, then come back here."
    static let stepTurnOnBodyWithLink = "flip Allow Extension in Settings. to put every site in your journal, also set All Websites (or Other Websites) to Allow, further down the same page. then come back here."
    static let switchName = "Allow Extension"
    static let openSettings = "open Settings"
    static let notOnYet = "not on yet. if Settings opened somewhere else, go to Apps, Safari, Extensions, solstone. the switch is Allow Extension."
    static let settingsByHand = "in Safari, open the page menu, then Manage Extensions, and turn on solstone."
    static let settingsByHandPad = "in Safari, tap the extensions button in the address bar and turn on solstone."
    static let stepChooseSites = "which sites do you want in your journal?"
    static let chooseEverySite = "share every site"
    static let chooseOneAtATime = "add sites one at a time"
    static let everySiteBody = "with Allow Extension on, set All Websites (or Other Websites) to Allow in Settings. that's every website, including ones you visit later. you can leave sites out."
    static let everySiteByHand = "in Settings, go to Apps, Safari, Extensions, solstone. with Allow Extension on, set All Websites (or Other Websites) to Allow. that's every website, including ones you visit later. you can leave sites out."
    static let everySiteNext = "once it's set, open any site in Safari, then open solstone from the page menu to check it's on."
    static let everySiteNextPad = "once it's set, open any site in Safari, then open solstone from the extensions button in the address bar to check it's on."
    static let oneAtATimeOtherWebsites = "if All Websites (or Other Websites) is set to Allow in Settings, every site you don't leave out goes into your journal. set it back to Ask to add sites one at a time."
    static let siteField = "which site?"
    static let sitePlaceholder = "eff.org"
    static let tapPageMenu = "page menu"
    // On iPad, Safari keeps extensions behind a button in its address bar; its page menu lists none.
    static let tapExtensions = "extensions"
    static let tapSolstone = "solstone"
    static let tapAdd = "add this site"
    static let tapAlwaysAllow = "Always Allow"
    static let safariAsks = "choose Always Allow so it keeps working when you come back."
    static let openInSafari = "open in Safari"
    static let working = "it's working."
    static let workingBody = "your first page just came in. it's on its way to your journal."
    static let addAnother = "add or leave out a site"
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
    static let noPageYetPad = "no pages from Safari yet. on a site you want in your journal, open solstone from the extensions button in Safari's address bar and add it."
    static let waiting = "some pages are waiting on this device."
    static let nothingWaiting = "nothing from Safari is waiting on this device."
    static let extensionOff = "the extension is off. turn it on in Settings to start intake."
    static let manageInSettings = "turn it on or off in Settings. to put every site in your journal, set All Websites (or Other Websites) to Allow there. to change one site, open it, then open solstone from Safari's page menu."
    static let manageInSettingsPad = "turn it on or off in Settings. to put every site in your journal, set All Websites (or Other Websites) to Allow there. to change one site, open it, then open solstone from the extensions button in Safari's address bar."
    static let manageByHand = "to turn it on or off, in Safari, open the page menu, then Manage Extensions."
    static let manageByHandPad = "to turn it on or off, in Safari, tap the extensions button in the address bar, then Manage Extensions."

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
    private static let log = Logger(subsystem: "app.solstone.swift", category: "safari")

    static var canOpenSettings: Bool {
        if #available(iOS 26.2, *) { return true }
        return false
    }

    static func isOn() async -> Bool? {
        guard #available(iOS 26.2, *) else { return nil }
        do {
            return try await SFSafariExtensionManager.stateOfExtension(withIdentifier: self.identifier).isEnabled
        } catch {
            let error = error as NSError
            self.log.error("extension state unreadable: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            return nil
        }
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
        // The switch says when the system can; before iOS 26.2 only a hello can.
        self = extensionOn ?? (snapshot?.lastContact != nil) ? .addSite : .turnOn
    }

    static func isShown(snapshot: SafariBrowserSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.lastAccepted == nil && !snapshot.full
    }
}

/// The owner's answer to setup's second step. It only picks which panel shows; an
/// unknown stored value is no answer.
nonisolated enum SafariSetUpChoice: String, Sendable {
    case everySite
    case oneAtATime

    static let storageKey = "safari.setup.choice"
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
    @ObservationIgnored private let readExtensionOn: () async -> Bool?
    @ObservationIgnored private let openSettings: () async -> Bool

    init(load: @escaping () throws -> SafariBrowserSnapshot = { try SafariBrowserStore().snapshot() },
         readExtensionOn: @escaping () async -> Bool? = { await SafariExtensionControl.isOn() },
         openSettings: @escaping () async -> Bool = { await SafariExtensionControl.openSettings() }) {
        self.load = load
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

    init(snapshot: SafariBrowserSnapshot?, extensionOn: Bool? = nil) {
        guard let snapshot else {
            self.sourceState = .needsAttention
            self.attention = SafariVocabulary.unreadable
            return
        }
        if snapshot.lastContact == nil {
            self.sourceState = .readyToSetUp
            self.attention = nil
        } else if extensionOn == false {
            self.sourceState = .off
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

nonisolated func safariSourceModel(snapshot: SafariBrowserSnapshot?, extensionOn: Bool? = nil, isJournalPaired: Bool) -> Source {
    let status = SafariSourceStatus(snapshot: snapshot, extensionOn: extensionOn)
    var subtext = status.compactAttention
    if subtext == nil, status.sourceState == .off {
        subtext = extensionOn == false ? SafariVocabulary.extensionOff
            : isJournalPaired ? SafariVocabulary.awaitingMark : SafariVocabulary.notPaired
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
