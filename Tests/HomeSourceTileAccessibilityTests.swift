// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class HomeSourceTileAccessibilityTests: XCTestCase {
    func testAccessibilityValueIsSourceStateLabel() {
        XCTAssertEqual(SourceState.off.label, "off")
        XCTAssertEqual(SourceState.paused.label, "paused")
        XCTAssertNotEqual(SourceState.off.label, SourceState.paused.label)
    }

    func testHomeSourceTileUsesStateLabelAsAccessibilityValue() throws {
        let text = try Self.contents("Sources/Home/HomeSourceTile.swift")
        XCTAssertTrue(text.contains(".accessibilityValue(Self.accessibilityValue(for: self.source))"))
        XCTAssertFalse(text.contains("homeSourceTileAccessibilityFacts"))

        let audioSource = Source(
            id: "audio",
            displayName: "audio",
            kind: .observer,
            state: .paused,
            isJournalPaired: true,
            activeSubtext: SourceVocabulary.observerActiveSubtext,
            subtextOverride: SourceVocabulary.microphoneTakenSubtextCompact,
            attention: nil,
            pendingStatus: .nonePending
        )
        let audioAccessibility = HomeSourceTile.accessibilityValue(for: audioSource)
        XCTAssertTrue(audioAccessibility.contains(SourceVocabulary.microphoneTakenSubtextCompact))
        XCTAssertTrue(audioAccessibility.starts(with: SourceState.paused.label))

        let nonObserverSource = Source(
            id: "screen",
            displayName: "screen",
            kind: .screencast,
            state: .off,
            isJournalPaired: true,
            activeSubtext: "screen",
            subtextOverride: "off",
            attention: nil,
            pendingStatus: .nonePending
        )
        XCTAssertEqual(HomeSourceTile.accessibilityValue(for: nonObserverSource), SourceState.off.label)
    }

    func testNeedsAttentionTileSpeaksTheLineForEveryKind() throws {
        let locationSource = makeLocationSource(
            state: .needsAttention,
            attention: nil,
            isJournalPaired: true,
            subtextOverride: LocationVocabulary.locationAttentionDenied
        )
        XCTAssertEqual(
            HomeSourceTile.accessibilityValue(for: locationSource),
            "\(SourceState.needsAttention.label). \(LocationVocabulary.locationAttentionDenied)"
        )

        let screenSource = screencastSourcePresentation(
            managerState: .needsAttention(.noVideo),
            isJournalPaired: true,
            enrolled: true
        )
        let screenOverride = try XCTUnwrap(screenSource.subtextOverride)
        XCTAssertEqual(screenOverride, SourceVocabulary.screencastAttentionNoVideo)
        XCTAssertEqual(
            HomeSourceTile.accessibilityValue(for: screenSource),
            "\(screenSource.state.label). \(screenSource.subtextOverride!)"
        )

        let calendarState = CalendarSourceState(
            setupStep: .notSetUp,
            access: .denied,
            everOn: true,
            paused: false,
            lastCompletedCheck: nil,
            followedCount: 0,
            calendarCount: 0,
            recent: [],
            notesWaiting: 0,
            notesNeedingAttention: 0,
            waitingForJournalUpdate: false
        )
        let calendarTile = calendarSourceModel(state: calendarState, isJournalPaired: true)
        XCTAssertEqual(calendarTile.state, .needsAttention)
        let calendarLine = try XCTUnwrap(calendarTile.subtextOverride)
        XCTAssertEqual(
            HomeSourceTile.accessibilityValue(for: calendarTile),
            "\(calendarTile.state.label). \(calendarLine)"
        )

        let watchSource = try XCTUnwrap(
            watchSourceModel(from: .installedActive(.stoppedItself(.audioStoppedItself)), isJournalPaired: true)
        )
        XCTAssertEqual(watchSource.state, .needsAttention)
        let watchLine = try XCTUnwrap(watchSource.subtextOverride)
        XCTAssertEqual(
            HomeSourceTile.accessibilityValue(for: watchSource),
            "\(watchSource.state.label). \(watchLine)"
        )
    }

    func testLocationActiveAndOffTilesSpeakTheStateWordAlone() {
        let activeLocation = makeLocationSource(state: .active, attention: nil, isJournalPaired: true, subtextOverride: nil)
        XCTAssertEqual(HomeSourceTile.accessibilityValue(for: activeLocation), SourceState.active.label)

        let offLocation = makeLocationSource(state: .off, attention: nil, isJournalPaired: true, subtextOverride: nil)
        XCTAssertEqual(HomeSourceTile.accessibilityValue(for: offLocation), SourceState.off.label)
    }

    func testHomeSourceTileControlsAreConsistentToggles() throws {
        let tileText = try Self.contents("Sources/Home/HomeSourceTile.swift")
        XCTAssertFalse(tileText.contains("case button"))
        XCTAssertTrue(tileText.contains("switch self.control"))
        XCTAssertFalse(tileText.contains("self.buttonSlot"))
        XCTAssertTrue(tileText.contains("dayHome.tile.\\(self.source.id).toggle"))
        XCTAssertFalse(tileText.contains("presentsScreencastPicker"))
        XCTAssertFalse(tileText.contains("onScreencastWillOpen"))

        let dayHomeText = try Self.contents("Sources/Home/DayHomeView.swift")
        XCTAssertFalse(dayHomeText.contains("presentsScreencastPicker"))
        XCTAssertFalse(dayHomeText.contains("onScreencastWillOpen"))
        XCTAssertTrue(dayHomeText.contains("isOn: self.screencastIsOn"))
        XCTAssertTrue(dayHomeText.contains("var screencastIsOn: Binding<Bool>"))
        XCTAssertTrue(dayHomeText.contains("guard requestedOn != self.screencastIsActive else { return }"))
        XCTAssertFalse(dayHomeText.contains("control: .button"))
        XCTAssertTrue(dayHomeText.contains("showingScreencastPrimer = true"))
    }

    func testScreencastPrimerSheetIdentifiersAndVocabulary() throws {
        let primerText = try Self.contents("Sources/Screencast/ScreencastPrimerSheet.swift")
        XCTAssertTrue(primerText.contains("screencast.primer.sheet"))
        XCTAssertTrue(primerText.contains("screencast.primer.illustration"))
        XCTAssertTrue(primerText.contains("screencast.primer.action"))
        XCTAssertTrue(primerText.contains("LocationVocabulary.alwaysPrimerHeader"))
        XCTAssertTrue(primerText.contains("SourceVocabulary.screencastPrimerBody(state:"))
        XCTAssertTrue(primerText.contains("SourceVocabulary.screencastOpenSystemSheet"))
        XCTAssertFalse(primerText.contains(".fill(Color.solOrange)"))
        XCTAssertFalse(primerText.contains("Color.deckSurfaceRaised"))
        XCTAssertFalse(primerText.contains(".fill(Color.deckSurface)"))
        XCTAssertTrue(primerText.contains("Color.solOrangeAdaptive"))
        XCTAssertTrue(primerText.contains(".fill(Color.secondary)"))
        XCTAssertTrue(primerText.contains(".fill(Color.primary)"))
    }

    private static func contents(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
