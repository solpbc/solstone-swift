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
        XCTAssertTrue(text.contains(".accessibilityValue(self.source.state.label)"))
        XCTAssertFalse(text.contains("homeSourceTileAccessibilityFacts"))
    }

    func testHomeSourceTileControlHasButtonAndExhaustiveSwitchInTopLine() throws {
        let tileText = try Self.contents("Sources/Home/HomeSourceTile.swift")
        XCTAssertTrue(tileText.contains("case button"))
        XCTAssertTrue(tileText.contains("switch self.control"))
        XCTAssertTrue(tileText.contains("self.buttonSlot"))
        XCTAssertTrue(tileText.contains("dayHome.tile.\\(self.source.id).action"))
        XCTAssertFalse(tileText.contains("presentsScreencastPicker"))
        XCTAssertFalse(tileText.contains("onScreencastWillOpen"))

        let dayHomeText = try Self.contents("Sources/Home/DayHomeView.swift")
        XCTAssertFalse(dayHomeText.contains("presentsScreencastPicker"))
        XCTAssertFalse(dayHomeText.contains("onScreencastWillOpen"))
        XCTAssertFalse(dayHomeText.contains("screencastIsOn"))
        XCTAssertFalse(dayHomeText.contains("set: { _ in }"))
        XCTAssertTrue(dayHomeText.contains("control: .button"))
        XCTAssertTrue(dayHomeText.contains("buttonTitle: SourceVocabulary.screencastStartButton"))
        XCTAssertTrue(dayHomeText.contains("showingScreencastPrimer = true"))
    }

    func testScreencastPrimerSheetIdentifiersAndVocabulary() throws {
        let primerText = try Self.contents("Sources/Screencast/ScreencastPrimerSheet.swift")
        XCTAssertTrue(primerText.contains("screencast.primer.sheet"))
        XCTAssertTrue(primerText.contains("screencast.primer.illustration"))
        XCTAssertTrue(primerText.contains("screencast.primer.action"))
        XCTAssertTrue(primerText.contains("LocationVocabulary.alwaysPrimerHeader"))
        XCTAssertTrue(primerText.contains("SourceVocabulary.screencastPrimerBody"))
        XCTAssertTrue(primerText.contains("SourceVocabulary.screencastOpenSystemSheet"))
    }

    private static func contents(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
