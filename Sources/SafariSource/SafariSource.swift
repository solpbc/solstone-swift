// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import SafariServices

/// Owner-facing words for the Safari source. Shared words (state words, block
/// titles) come from `SourceVocabulary` and `LocationVocabulary`.
nonisolated enum SafariVocabulary {
    static let label = AppStrings.ios_safarisource_safari()
    static let valueLine = AppStrings.ios_safarisource_valueline()
    static let stepTurnOn = AppStrings.ios_safarisource_turnontheextension()
    static let stepTurnOnBody = AppStrings.ios_safarisource_oneswitchinsettingsflip()
    static let stepTurnOnBodyWithLink = AppStrings.ios_safarisource_flipallowextensioninsettings()
    static let switchName = AppStrings.ios_safarisource_allowextension()
    static let openSettings = AppStrings.ios_safarisource_opensettings()
    static let notOnYet = AppStrings.ios_safarisource_notonyetifsettings()
    static let settingsByHand = AppStrings.ios_safarisource_insafariopenthepage()
    static let settingsByHandPad = AppStrings.ios_safarisource_insafaritaptheextensions()
    static let stepChooseSites = AppStrings.ios_safarisource_whichsitesdoyouwant()
    static let chooseEverySite = AppStrings.ios_safarisource_shareeverysite()
    static let chooseOneAtATime = AppStrings.ios_safarisource_addsitesoneata()
    static let everySiteBody = AppStrings.ios_safarisource_withallowextensiononset()
    static let everySiteByHand = AppStrings.ios_safarisource_insettingsgotoapps()
    static let everySiteNext = AppStrings.ios_safarisource_onceitssetopenany()
    static let everySiteNextPad = AppStrings.ios_safarisource_onceitssetopenany2()
    static let oneAtATimeOtherWebsites = AppStrings.ios_safarisource_ifallwebsitesorother()
    static let siteField = AppStrings.ios_safarisource_whichsite()
    static let sitePlaceholder = "eff.org"
    static let tapPageMenu = AppStrings.ios_safarisource_pagemenu()
    // On iPad, Safari keeps extensions behind a button in its address bar; its page menu lists none.
    static let tapExtensions = AppStrings.ios_safarisource_extensions()
    static let tapSolstone = AppStrings.ios_push_test_title()
    static let tapAdd = AppStrings.ios_safarisource_addthissite()
    static let tapAlwaysAllow = AppStrings.ios_safarisource_alwaysallow()
    static let safariAsks = AppStrings.ios_safarisource_choosealwaysallowsoit()
    /// On iPhone the page menu opens on its top items; the extensions sit below them.
    static let safariAsksPhone = AppStrings.ios_safarisource_solstoneisfurtherdownthe()
    static let openInSafari = AppStrings.ios_safarisource_openinsafari()
    static let working = AppStrings.ios_safarisource_itsworking()
    static let workingBody = AppStrings.ios_safarisource_yourfirstpagejustcame()
    static let addAnother = AppStrings.ios_safarisource_addorleaveouta()
    static let whileClosed = AppStrings.ios_safarisource_whileclosed()
    static let privateBrowsing = AppStrings.ios_safarisource_privatebrowsing()
    static let activeSubtextPaired = AppStrings.ios_safarisource_activesubtextpaired()
    static let notPaired = AppStrings.ios_safarisource_notpaired()
    static let awaitingMark = AppStrings.ios_safarisource_awaitingmark()
    static let full = AppStrings.ios_safarisource_full()
    static let fullCompact = AppStrings.ios_safarisource_fullcompact()
    static let unreadable = AppStrings.ios_safarisource_unreadable()
    static let unreadableCompact = AppStrings.ios_safarisource_unreadablecompact()
    static let noPageYet = AppStrings.ios_safarisource_nopageyet()
    static let noPageYetPad = AppStrings.ios_safarisource_nopagesfromsafariyet()
    static let waiting = AppStrings.ios_safarisource_waiting()
    static let nothingWaiting = AppStrings.ios_safarisource_nothingwaiting()
    static let extensionOff = AppStrings.ios_safarisource_theextensionisoffturn()
    static let manageInSettings = AppStrings.ios_safarisource_turnitonoroff()
    static let manageInSettingsPad = AppStrings.ios_safarisource_turnitonoroff2()
    static let manageByHand = AppStrings.ios_safarisource_toturnitonor()
    static let manageByHandPad = AppStrings.ios_safarisource_toturnitonor2()

    static func waitingFor(_ site: String) -> String {
        AppStrings.ios_safarisource_waitingforapagefrom("\(site)")
    }

    static func activeSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? self.activeSubtextPaired : self.notPaired
    }

    static func lastPage(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        AppStrings.ios_safarisource_calendar("\(CalendarVocabulary.lastCheckedTime(date, now: now, calendar: calendar))")
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
    private var transferMirror: TransferStatusMirror?
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

    func bindTransferMirror(_ mirror: TransferStatusMirror) { self.transferMirror = mirror }

    /// The same period may be visible in both stores during adoption. Count its identity once.
    var waitingCount: Int {
        let queued = self.transferMirror?.sources["browser"]
        let local = self.snapshot?.pendingPeriodIDs ?? []
        return (queued?.queuedCount ?? 0) + (queued?.attentionCount ?? 0)
            + local.subtracting(self.transferMirror?.heldItemIDs ?? []).count
    }

    var waitingIsKnown: Bool { self.snapshot != nil }

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
