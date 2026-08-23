// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Handoff to the panes lode.
///
/// Registered with real bodies:
///   `.source(SourceRoute)` → SourceDetailView / LocationSourceDetailView /
///   ScreencastSourceDetailView / OmiSourceDetailView / WatchSourceDetailView /
///   ImporterSourceDetailView.
///
/// Registered with self-naming developer stubs (this lode does not fill them):
///   `.status`, `.journal`, `.journalSetup`, `.addMore`, `.import`, `.shelf`,
///   plus the five shelf rows in §4.2 order:
///   `.shelfJournal` (journal), `.shelfThisDevice` (this device),
///   `.shelfNotifications` (notifications), `.shelfHelp` (help),
///   `.shelfAbout` (about solstone).
///
/// Interim wiring (this lode, not the enum):
///   leading shelf control → MoreView sheet (`dayHome.yourSolstoneEntry`)
///   add-more tile         → SourcesView sheet (`dayHome.sourcesEntry`)
///   journal pill          → InAppJournalView sheet when paired+reachable
///                           (`dayHome.openInJournal`); otherwise JournalLivesSheet
///                           (`dayHome.journalSetup`)
///   status pill           → StatusPane detent sheet (`dayHome.statusPill`)
///
/// Wave 3 `NavigationSplitView` reuses this type as a selection: Hashable,
/// Sendable, no View payloads, no non-Hashable associated values.
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
}

/// Wave 3 iPad `NavigationSplitView` vocabulary. These cases are Hashable
/// selection values for that split view; they are not pushed on iPhone. The
/// self-naming `ShellPaneStub` bodies are deliberate so an accidental push is
/// visible rather than a silent blank. Never replace them with `EmptyView()`.
struct ShellDestinationView: View {
    let destination: ShellDestination
    @Environment(AppConfig.self) private var appConfig

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
        case .source(.share):
            ImporterSourceDetailView(source: makeShareSource(isJournalPaired: self.appConfig.isPaired))
        case .status:
            ShellPaneStub(name: "status", identifier: "status")
        case .journal:
            ShellPaneStub(name: "journal", identifier: "journal")
        case .journalSetup:
            ShellPaneStub(name: "journalSetup", identifier: "journalSetup")
        case .addMore:
            AddMoreView()
        case .import:
            ImportView()
        case .shelf:
            ShellPaneStub(name: "shelf", identifier: "shelf")
        case .shelfJournal:
            ShellPaneStub(name: "journal", identifier: "shelfJournal")
        case .shelfThisDevice:
            ShellPaneStub(name: "this device", identifier: "thisDevice")
        case .shelfNotifications:
            ShellPaneStub(name: "notifications", identifier: "shelfNotifications")
        case .shelfHelp:
            ShellPaneStub(name: "help", identifier: "shelfHelp")
        case .shelfAbout:
            ShellPaneStub(name: "about solstone", identifier: "aboutSolstone")
        }
    }
}
