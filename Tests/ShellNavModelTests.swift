// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

@MainActor
final class ShellNavModelTests: XCTestCase {
    func testSelectFromDeckReplacesRootAndClearsStack() {
        let nav = ShellNavModel()
        nav.selectFromDeck(.source(.audio))
        nav.paneStack = [.shelfThisDevice, .shelfNotifications]
        XCTAssertEqual(nav.paneStack.count, 2)

        nav.selectFromDeck(.status)

        XCTAssertEqual(nav.paneRoot, .status)
        XCTAssertTrue(nav.paneStack.isEmpty)
    }

    func testDefaultPaneIsJournalSetupUnpairedAndStatusPaired() {
        XCTAssertEqual(ShellNavModel.defaultPane(isPaired: false), .journalSetup)
        XCTAssertEqual(ShellNavModel.defaultPane(isPaired: true), .status)
    }

    /// The journal is somewhere the owner goes, never where the pane rests.
    func testDefaultPaneIsNeverTheJournal() {
        for paired in [true, false] {
            XCTAssertNotEqual(ShellNavModel.defaultPane(isPaired: paired), .journal)
            XCTAssertNotEqual(ShellNavModel().resolvedPaneRoot(isPaired: paired), .journal)
        }
    }

    func testResolvedRootFallsBackToDefaultAndNeverStoresIt() {
        let nav = ShellNavModel()
        XCTAssertNil(nav.paneRoot)
        XCTAssertEqual(nav.resolvedPaneRoot(isPaired: false), .journalSetup)
        XCTAssertEqual(nav.resolvedPaneRoot(isPaired: true), .status)
        // Reading the default must not write it: pairing completing inside the
        // journal-setup pane has to move the default on its own.
        XCTAssertNil(nav.paneRoot)
    }

    func testResolvedRootPrefersTheDeckSelection() {
        let nav = ShellNavModel()
        nav.selectFromDeck(.import)
        XCTAssertEqual(nav.resolvedPaneRoot(isPaired: true), .import)
        XCTAssertEqual(nav.resolvedPaneRoot(isPaired: false), .import)
    }

    /// Retention, not display: changing how the split is shown must not disturb
    /// either channel. This is the layer a collapse can actually be driven at.
    func testColumnVisibilityChangesRetainBothChannels() {
        let nav = ShellNavModel()
        nav.selectFromDeck(.source(.location))
        nav.paneStack = [.shelfThisDevice, .shelfHelp]
        let rootBefore = nav.paneRoot
        let stackBefore = nav.paneStack

        for visibility in [
            NavigationSplitViewVisibility.detailOnly,
            .doubleColumn,
            .all,
            .automatic,
            .detailOnly,
            .all,
        ] {
            nav.columnVisibility = visibility
            XCTAssertEqual(nav.paneRoot, rootBefore)
            XCTAssertEqual(nav.paneStack, stackBefore)
        }
    }

    func testToggleDeckVisibilityChangesOnlyColumnVisibility() {
        let nav = ShellNavModel()
        nav.selectFromDeck(.source(.audio))
        nav.paneStack = [.shelfThisDevice]
        let rootBefore = nav.paneRoot
        let stackBefore = nav.paneStack

        nav.columnVisibility = .detailOnly
        nav.toggleDeckVisibility()
        XCTAssertEqual(nav.columnVisibility, .all)
        XCTAssertEqual(nav.paneRoot, rootBefore)
        XCTAssertEqual(nav.paneStack, stackBefore)

        for visibility in [
            NavigationSplitViewVisibility.all,
            .doubleColumn,
        ] {
            nav.columnVisibility = visibility
            nav.toggleDeckVisibility()
            XCTAssertEqual(nav.columnVisibility, .detailOnly)
            XCTAssertEqual(nav.paneRoot, rootBefore)
            XCTAssertEqual(nav.paneStack, stackBefore)
        }

        // This SDK canonicalizes `.automatic` to `.detailOnly` when it is
        // assigned to the binding. The toggle therefore follows the binding's
        // observable value, which is the only public state SwiftUI exposes.
        nav.columnVisibility = .automatic
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleDeckVisibility()
        XCTAssertEqual(nav.columnVisibility, .all)
        XCTAssertEqual(nav.paneRoot, rootBefore)
        XCTAssertEqual(nav.paneStack, stackBefore)
    }
}
