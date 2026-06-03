// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class LocationEnrollmentPresentationTests: XCTestCase {
    func testPresentationReferencesLocationVocabularyConstants() {
        let presentation = LocationEnrollmentPresentation.current

        XCTAssertEqual(presentation.preEnrollmentValue, LocationVocabulary.preEnrollmentValue)
        XCTAssertEqual(presentation.tierDialHeader, LocationVocabulary.tierDialHeader)
        XCTAssertEqual(presentation.tierDialSubhead, LocationVocabulary.tierDialSubhead)
        XCTAssertEqual(presentation.batteryHonesty, LocationVocabulary.batteryHonesty)
        XCTAssertEqual(presentation.alwaysBackgroundPrimer, LocationVocabulary.alwaysBackgroundPrimer)
        XCTAssertEqual(presentation.turnOnLocation, LocationVocabulary.turnOnLocation)
        XCTAssertEqual(presentation.alwaysPrimerHeader, LocationVocabulary.alwaysPrimerHeader)
        XCTAssertEqual(presentation.alwaysPrimerContinue, LocationVocabulary.alwaysPrimerContinue)
    }
}
