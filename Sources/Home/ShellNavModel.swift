// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The iPad shell's two navigation channels.
///
/// The leading column is permanently the deck; everything variable lives in the
/// detail column. Two channels reach it:
///
///   `paneRoot`  is the replace channel. A tap in the deck replaces what the pane
///                 shows and clears anything pushed on top of it.
///   `paneStack` is the push channel. A link inside the pane adds to the stack.
///
/// `selectFromDeck(_:)` is the only writer of `paneRoot`, so "a deck tap
/// replaces" is enforced here rather than at each call site.
@Observable
@MainActor
final class ShellNavModel {
    /// What the detail column shows at the root of its stack. `nil` means no deck
    /// selection has been made yet and the computed default stands in; the default
    /// is never written here. See `resolvedPaneRoot(isPaired:)`.
    private(set) var paneRoot: ShellDestination?

    /// Pushed above `paneRoot`. Settable because it is the detail column's
    /// `NavigationStack(path:)` binding.
    var paneStack: [ShellDestination] = []

    /// The split's column visibility. Settable because it is the split's binding;
    /// the system sidebar toggle writes through it.
    var columnVisibility: NavigationSplitViewVisibility = .all

    init() {}

    /// Replace the pane root from the deck, discarding anything pushed above it.
    ///
    /// The only writer of `paneRoot`. Takes an optional so that returning to the
    /// deck, which the collapsed shell does on a back navigation, stays inside
    /// this one method rather than needing a second writer or a raw setter.
    func selectFromDeck(_ destination: ShellDestination?) {
        self.paneRoot = destination
        self.paneStack.removeAll()
    }

    /// Swap between the full split and its detail column without disturbing
    /// either navigation channel.
    func toggleDeckVisibility() {
        if self.columnVisibility == .detailOnly {
            self.columnVisibility = .all
        } else {
            self.columnVisibility = .detailOnly
        }
    }

    /// What the pane shows before the owner has chosen anything.
    ///
    /// Journal setup when there is no journal to show yet, status once there is.
    /// Never the journal itself: the pane is a resting state, not a destination
    /// the owner asked for.
    nonisolated static func defaultPane(isPaired: Bool) -> ShellDestination {
        isPaired ? .status : .journalSetup
    }

    /// The pane root to render: the deck's selection when there is one, otherwise
    /// the computed default.
    ///
    /// Computed rather than stored so that pairing completing inside the
    /// journal-setup pane moves the default on its own, with no second writer.
    func resolvedPaneRoot(isPaired: Bool) -> ShellDestination {
        self.paneRoot ?? Self.defaultPane(isPaired: isPaired)
    }
}
