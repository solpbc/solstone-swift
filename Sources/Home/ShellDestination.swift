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
    case addMore
    case `import`
    case shelf
    case shelfJournal
    case shelfThisDevice
    case shelfNotifications
    case shelfHelp
    case shelfAbout
    case diagnostics
    case problemReports
    case pairFlow

    var shelfTitle: String {
        switch self {
        case .shelfJournal:
            "journal"
        case .shelfThisDevice:
            "this device"
        case .shelfNotifications:
            "notifications"
        case .shelfHelp:
            "help"
        case .shelfAbout:
            "about solstone"
        case .status, .journal, .journalSetup, .source, .addMore, .import, .shelf,
             .diagnostics, .problemReports, .pairFlow:
            preconditionFailure("shelfTitle is only available for shelf destinations")
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
        case .status, .journal, .journalSetup, .source, .addMore, .import, .shelf,
             .diagnostics, .problemReports, .pairFlow:
            preconditionFailure("shelfRowIdentifier is only available for shelf destinations")
        }
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
    var onOpenJournal: (() -> Void)? = nil

    @Environment(ShellNavModel.self) private var nav
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch self.destination {
        case .source(.audio):
            SourceDetailView()
        case .source(.location):
            LocationSourceDetailView()
        case .source(.screencast):
            ScreencastSourceDetailView()
        case .source(.omi):
            OmiSourceDetailView()
        case .source(.watch):
            WatchSourceDetailView()
        case .status:
            StatusPane(presentation: .detail)
        case .journal:
            InAppJournalView(mark: self.journalMark, presentation: .detail)
        case .journalSetup:
            JournalLivesPane()
        case .addMore:
            AddMoreView { route in
                self.nav.paneStack.append(.source(route))
            }
        case .import:
            ImportView()
        case .shelf:
            ShelfPane(
                presentation: .detail,
                onOpenJournal: { self.openJournal() }
            )
        case .shelfJournal:
            JournalSettingsPane(onOpenJournal: { self.openJournal() })
        case .shelfThisDevice:
            ThisDevicePane()
        case .shelfNotifications:
            NotificationsPane()
        case .shelfHelp:
            HelpPane()
        case .shelfAbout:
            AboutPane()
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
