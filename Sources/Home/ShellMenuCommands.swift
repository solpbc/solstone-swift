// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

nonisolated func shouldBuildShellMenuCommands(
    userInterfaceIdiom: UIUserInterfaceIdiom
) -> Bool {
    userInterfaceIdiom == .pad
}

nonisolated enum ShellMenuTarget: Hashable, Sendable {
    case deckToggle
    case status
    case journal
    case journalSetup
    case `import`
    case addMore
    case shelf
    case settings

    var destination: ShellDestination? {
        switch self {
        case .deckToggle, .settings:
            nil
        case .status:
            .status
        case .journal:
            .journal
        case .journalSetup:
            .journalSetup
        case .import:
            .import
        case .addMore:
            .addMore
        case .shelf:
            .shelf
        }
    }
}

nonisolated struct ShellMenuItem: Identifiable, Hashable, Sendable {
    let target: ShellMenuTarget
    let title: String
    let shortcut: Character?

    var id: ShellMenuTarget { self.target }
}

nonisolated enum ShellMenuCatalog {
    nonisolated static let items: [ShellMenuItem] = [
        ShellMenuItem(target: .deckToggle, title: "dev-copy: toggle deck", shortcut: "0"),
        ShellMenuItem(target: .status, title: "dev-copy: status", shortcut: "1"),
        ShellMenuItem(target: .journal, title: SourceVocabulary.openInJournal, shortcut: "2"),
        ShellMenuItem(target: .journalSetup, title: SourceVocabulary.journalLivesTitle, shortcut: "3"),
        ShellMenuItem(target: .import, title: SourceVocabulary.importTitle, shortcut: "4"),
        ShellMenuItem(target: .addMore, title: SourceVocabulary.addMoreTitle, shortcut: "5"),
        ShellMenuItem(target: .shelf, title: "dev-copy: settings", shortcut: "6"),
        ShellMenuItem(target: .settings, title: SourceVocabulary.openSettings, shortcut: nil),
    ]
}

nonisolated func shellMenuCommandIsEnabled(
    _ target: ShellMenuTarget,
    onboardingIsCompleted: Bool,
    journalState: DayHomeJournalState
) -> Bool {
    if target == .settings {
        return true
    }
    guard onboardingIsCompleted else {
        return false
    }

    return switch target {
    case .journal:
        journalState == .linkedOnline
    case .journalSetup:
        journalState != .linkedOnline
    case .deckToggle, .status, .import, .addMore, .shelf:
        true
    case .settings:
        true
    }
}

@MainActor
struct ShellMenuCommands: Commands {
    let nav: ShellNavModel
    let onboardingFlow: OnboardingFlow
    let appConfig: AppConfig
    let connectionSyncModel: ConnectionSyncModel

    private var journalState: DayHomeJournalState {
        dayHomeJournalState(
            isPaired: self.appConfig.isPaired,
            status: self.connectionSyncModel.status
        )
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(ShellMenuCatalog.items) { item in
                self.menuButton(item)
            }
        }
    }

    @ViewBuilder
    private func menuButton(_ item: ShellMenuItem) -> some View {
        if let shortcut = item.shortcut {
            Button(item.title) {
                self.perform(item.target)
            }
            .keyboardShortcut(KeyEquivalent(shortcut))
            .disabled(!self.isMenuItemEnabled(item))
        } else {
            Button(item.title) {
                self.perform(item.target)
            }
            .disabled(!self.isMenuItemEnabled(item))
        }
    }

    private func isMenuItemEnabled(_ item: ShellMenuItem) -> Bool {
        shellMenuCommandIsEnabled(
            item.target,
            onboardingIsCompleted: self.onboardingFlow.isCompleted,
            journalState: self.journalState
        )
    }

    private func perform(_ target: ShellMenuTarget) {
        if let destination = target.destination {
            self.nav.selectFromDeck(destination)
            return
        }

        switch target {
        case .deckToggle:
            self.nav.toggleDeckVisibility()
        case .settings:
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        case .status, .journal, .journalSetup, .import, .addMore, .shelf:
            preconditionFailure("shell destination missing")
        }
    }
}
