// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The shared shell navigation vocabulary. Hashable, Sendable, no View payloads.
///
/// Live iPhone wiring outside the phone stack:
///   leading shelf control → ShelfPane overlay (`dayHome.yourSolstoneEntry`)
///   add-more tile         → SourcesView sheet (`dayHome.sourcesEntry`)
///   import tile           → `ImportView` via `ShellDestination.import`
///                           (`dayHome.importEntry`)
///   journal pill          → InAppJournalView sheet when paired+reachable
///                           (`dayHome.openInJournal`); otherwise JournalLivesSheet
///                           (`dayHome.journalSetup`)
///   status pill           → StatusPane detent sheet (`dayHome.statusPill`)
nonisolated enum ShellDestination: Hashable, Sendable {
    case status
    case journal
    case journalSetup
    case source(SourceRoute)
    case folderDetail(String)
    case addMore
    case `import`
    case onThisDevice
    case shelf
    case shelfJournal
    case shelfThisDevice
    case shelfNotifications
    case shelfHelp
    case shelfAbout
    case licenses
    case diagnostics
    case problemReports
    case pairFlow

    var shelfTitle: String {
        switch self {
        case .shelfJournal:
            AppStrings.ios_liveactivity_yourjournalsection()
        case .shelfThisDevice:
            AppStrings.ios_home_shelftitle4()
        case .shelfNotifications:
            AppStrings.ios_home_shelftitle3()
        case .shelfHelp:
            AppStrings.ios_home_shelftitle2()
        case .shelfAbout:
            AppStrings.ios_home_shelftitle()
        case .status, .journal, .journalSetup, .source, .folderDetail, .addMore, .import, .onThisDevice, .shelf,
             .licenses, .diagnostics, .problemReports, .pairFlow:
            preconditionFailure("shelfTitle is only available for shelf destinations")
        }
    }

    /// The glyph a shelf row carries. Same slot the deck tile fills for a source, so
    /// the shell's two lists are legible the same way.
    var shelfGlyph: String {
        switch self {
        case .shelfJournal:
            "book.closed"
        case .shelfThisDevice:
            "iphone"
        case .shelfNotifications:
            "bell"
        case .shelfHelp:
            "lifepreserver"
        case .shelfAbout:
            "sun.max"
        case .status, .journal, .journalSetup, .source, .folderDetail, .addMore, .import, .onThisDevice, .shelf,
             .licenses, .diagnostics, .problemReports, .pairFlow:
            preconditionFailure("shelfGlyph is only available for shelf destinations")
        }
    }

    var shelfRowIdentifier: String {
        switch self {
        case .shelfJournal:
            "shell.pane.shelf.journal"
        case .shelfThisDevice:
            "shell.pane.shelf.thisDevice"
        case .shelfNotifications:
            "shell.pane.shelf.notifications"
        case .shelfHelp:
            "shell.pane.shelf.help"
        case .shelfAbout:
            "shell.pane.shelf.about"
        case .status, .journal, .journalSetup, .source, .folderDetail, .addMore, .import, .onThisDevice, .shelf,
             .licenses, .diagnostics, .problemReports, .pairFlow:
            preconditionFailure("shelfRowIdentifier is only available for shelf destinations")
        }
    }
}

/// Whether the deck is showing beside this pane, its pill carrying the journal's mark.
/// Set only on the iPad split's pane root: a pushed pane has a back button to carry,
/// and the phone's single stack has no deck beside it.
private struct PaneBesideDeckKey: EnvironmentKey { static let defaultValue = false }
private struct PushShellDestinationKey: EnvironmentKey { static let defaultValue: (@MainActor (ShellDestination) -> Void)? = nil }
extension EnvironmentValues {
    var paneBesideDeck: Bool {
        get { self[PaneBesideDeckKey.self] }
        set { self[PaneBesideDeckKey.self] = newValue }
    }

    var pushShellDestination: (@MainActor (ShellDestination) -> Void)? {
        get { self[PushShellDestinationKey.self] }
        set { self[PushShellDestinationKey.self] = newValue }
    }
}

nonisolated enum ShellPanePresentation: Sendable {
    case phoneModal
    case detail

    var isPhoneModal: Bool {
        switch self {
        case .phoneModal:
            true
        case .detail:
            false
        }
    }
}

struct ShellDestinationView: View {
    let destination: ShellDestination
    var journalMark: JournalMark? = nil
    var journalPath: String = "/"
    var journalOpenID: UUID? = nil
    var onOpenJournal: (() -> Void)? = nil

    @Environment(ShellNavModel.self) private var nav
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        self.content.shellSurface()
    }

    @ViewBuilder
    private var content: some View {
        switch self.destination {
        case .source(.audio):
            SourceDetailView()
        case .source(.location):
            LocationSourceDetailView()
        case .source(.screencast):
            ScreencastSourceDetailView()
        case .source(.watch):
            WatchSourceDetailView()
        case .source(.calendar):
            CalendarSourceDetailView()
        case .source(.obsidian):
            ObsidianSourceDetailView()
        case .source(.screenshots):
            ScreenshotsSourceDetailView()
        case .source(.photos):
            #if SOLSTONE_PHOTOS_LIBRARY
            PhotosSourceDetailView()
            #else
            EmptyView()
            #endif
        case .source(.safari):
            SafariSourceDetailView()
        case .source(.folders):
            FoldersListView()
        case .folderDetail(let folderID):
            FolderDetailView(folderID: folderID)
        case .status:
            StatusPane(presentation: .detail, journalMark: self.journalMark)
        case .journal:
            InAppJournalView(mark: self.journalMark, presentation: .detail, path: self.journalPath)
        case .journalSetup:
            JournalLivesPane()
        case .addMore:
            AddMoreView { route in
                self.nav.paneStack.append(.source(route))
            }
        case .import:
            ImportView()
        case .onThisDevice:
            OnThisPhoneView()
        case .shelf:
            ShelfPane(
                presentation: .detail,
                journalMark: self.journalMark,
                onOpenJournal: { self.openJournal() }
            )
        case .shelfJournal:
            JournalSettingsPane(
                journalMark: self.journalMark,
                onOpenJournal: { self.openJournal() }
            )
        case .shelfThisDevice:
            ThisDevicePane()
        case .shelfNotifications:
            NotificationsPane()
        case .shelfHelp:
            HelpPane()
        case .shelfAbout:
            AboutPane()
        case .licenses:
            LicensesPane()
        case .diagnostics:
            DiagnosticsView()
        case .problemReports:
            ProblemReportsView()
        case .pairFlow:
            PairFlowView(
                onBack: { self.dismiss() },
                onComplete: {
                    OwnerPairingCompletion.completeOwnerPairing(tunnelManager: self.tunnelManager)
                    self.dismiss()
                }
            )
        }
    }

    private func openJournal() {
        if let onOpenJournal {
            onOpenJournal()
        } else {
            self.nav.paneStack.append(.journal)
        }
    }
}
