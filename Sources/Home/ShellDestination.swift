// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Wave 3 iPad `NavigationSplitView` selection vocabulary. Hashable, Sendable,
/// no View payloads.
///
/// On iPhone only `.source(...)` is pushed (deck tiles via `DayHomeView`).
/// `.status`, `.journal`, `.journalSetup`, `.shelf`, and the five shelf-row
/// cases are unreachable on iPhone; they resolve to a self-naming
/// `ShellPaneStub` so an accidental push is visible rather than a silent blank.
/// Never replace stubs with `EmptyView()`. `.addMore` and `.import` resolve to
/// L2.3 placeholders.
///
/// Live iPhone wiring (not this enum):
///   leading shelf control → ShelfPane overlay (`dayHome.yourSolstoneEntry`)
///   add-more tile         → SourcesView sheet (`dayHome.sourcesEntry`)
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
