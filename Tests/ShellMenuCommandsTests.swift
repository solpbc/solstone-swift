// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import UIKit
import XCTest

final class ShellMenuCommandsTests: XCTestCase {
    func testShellMenuConstructionIsPadOnly() {
        XCTAssertFalse(shouldBuildShellMenuCommands(userInterfaceIdiom: .phone))
        XCTAssertTrue(shouldBuildShellMenuCommands(userInterfaceIdiom: .pad))
    }

    func testShellMenuEnablementMatrix() {
        let shellTargets: [ShellMenuTarget] = [
            .deckToggle,
            .status,
            .journal,
            .journalSetup,
            .import,
            .addMore,
            .shelf,
        ]

        for target in shellTargets {
            XCTAssertFalse(
                shellMenuCommandIsEnabled(
                    target,
                    onboardingIsCompleted: false,
                    journalState: .linkedOnline
                ),
                "\(target) must stay inactive during onboarding"
            )
        }
        XCTAssertTrue(
            shellMenuCommandIsEnabled(
                .settings,
                onboardingIsCompleted: false,
                journalState: .linkedOffline
            )
        )

        for target in [.deckToggle, .status, .import, .addMore, .shelf] as [ShellMenuTarget] {
            XCTAssertTrue(
                shellMenuCommandIsEnabled(
                    target,
                    onboardingIsCompleted: true,
                    journalState: .linkedOnline
                )
            )
        }
        XCTAssertTrue(
            shellMenuCommandIsEnabled(
                .journal,
                onboardingIsCompleted: true,
                journalState: .linkedOnline
            )
        )
        XCTAssertFalse(
            shellMenuCommandIsEnabled(
                .journal,
                onboardingIsCompleted: true,
                journalState: .linkedOffline
            )
        )
        XCTAssertTrue(
            shellMenuCommandIsEnabled(
                .journalSetup,
                onboardingIsCompleted: true,
                journalState: .linkedOffline
            )
        )
        XCTAssertFalse(
            shellMenuCommandIsEnabled(
                .journalSetup,
                onboardingIsCompleted: true,
                journalState: .linkedOnline
            )
        )
    }

    func testShellMenuItemsHaveDistinctTitlesAndTargets() {
        let items = ShellMenuCatalog.items
        XCTAssertEqual(Set(items.map(\.title)).count, items.count)
        XCTAssertEqual(Set(items.map(\.target)).count, items.count)
        XCTAssertEqual(items.filter { $0.target == .shelf }.count, 1)

        let shelf = items.first { $0.target == .shelf }
        let settings = items.first { $0.target == .settings }
        XCTAssertNotEqual(shelf?.title, settings?.title)
    }

    func testShellMenuShortcutsCoverFixedTargetsExactlyOnce() {
        let shortcutItems = ShellMenuCatalog.items.filter { $0.shortcut != nil }
        let expected: Set<ShellMenuTarget> = [
            .deckToggle,
            .status,
            .journal,
            .journalSetup,
            .import,
            .addMore,
            .shelf,
        ]

        XCTAssertEqual(Set(shortcutItems.map(\.target)), expected)
        XCTAssertEqual(shortcutItems.count, expected.count)
        XCTAssertEqual(Set(shortcutItems.compactMap(\.shortcut)).count, shortcutItems.count)
        XCTAssertNil(ShellMenuCatalog.items.first { $0.target == .settings }?.shortcut)
    }
}
