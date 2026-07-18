// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class LocationEnrollmentPresentationTests: XCTestCase {
    func testPresentationReferencesLocationVocabularyConstants() {
        let unpaired = LocationEnrollmentPresentation.current(isJournalPaired: false)
        let paired = LocationEnrollmentPresentation.current(isJournalPaired: true)

        XCTAssertEqual(unpaired.preEnrollmentValue, LocationVocabulary.preEnrollmentValue(isJournalPaired: false))
        XCTAssertEqual(paired.preEnrollmentValue, LocationVocabulary.preEnrollmentValue(isJournalPaired: true))
        XCTAssertEqual(paired.tierDialHeader, LocationVocabulary.tierDialHeader)
        XCTAssertEqual(paired.tierDialSubhead, LocationVocabulary.tierDialSubhead)
        XCTAssertEqual(paired.batteryHonesty, LocationVocabulary.batteryHonesty)
        XCTAssertEqual(paired.alwaysBackgroundPrimer, LocationVocabulary.alwaysBackgroundPrimer)
        XCTAssertEqual(paired.turnOnLocation, LocationVocabulary.turnOnLocation)
        XCTAssertEqual(paired.alwaysPrimerHeader, LocationVocabulary.alwaysPrimerHeader)
        XCTAssertEqual(paired.alwaysPrimerContinue, LocationVocabulary.alwaysPrimerContinue)
    }
}
