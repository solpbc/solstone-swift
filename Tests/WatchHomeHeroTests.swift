// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchHomeHeroTests: XCTestCase {
    func testActiveWithNilStartProducesLargeTitleAndNoElapsed() {
        let presentation = WatchCaptureOwnerPresentation(
            status: .active,
            queuedCount: 0,
            isSessionRunning: true,
            sessionStartedAt: nil
        )
        let model = watchFaceModel(for: presentation, isReachable: true)
        XCTAssertTrue(model.showsElapsed)
        XCTAssertEqual(model.stateColorRole, .live)

        let hero = watchHomeHero(
            model: model,
            status: presentation.status,
            sessionStartedAt: presentation.sessionStartedAt,
            now: Date()
        )
        XCTAssertEqual(hero.title, SourceVocabulary.watchHeadlineListening)
        XCTAssertTrue(hero.titleIsLarge)
        XCTAssertEqual(hero.titleHex, WatchHomePalette.liveText)
        XCTAssertNil(hero.elapsedDisplay)
        XCTAssertNil(hero.spokenElapsed)
    }

    func testActiveWithStartProducesSmallTitleAndElapsed() {
        let now = Date()
        let start = now.addingTimeInterval(-125)
        let presentation = WatchCaptureOwnerPresentation(
            status: .active,
            queuedCount: 0,
            isSessionRunning: true,
            sessionStartedAt: start
        )
        let model = watchFaceModel(for: presentation, isReachable: true)

        let hero = watchHomeHero(
            model: model,
            status: presentation.status,
            sessionStartedAt: presentation.sessionStartedAt,
            now: now
        )
        XCTAssertEqual(hero.title, SourceVocabulary.watchHeadlineListening)
        XCTAssertFalse(hero.titleIsLarge)
        XCTAssertEqual(hero.titleHex, WatchHomePalette.liveText)
        XCTAssertEqual(hero.elapsedDisplay, "2m")
        XCTAssertEqual(hero.spokenElapsed, "2 minutes")
        XCTAssertEqual(hero.elapsedHex, WatchHomePalette.cream)
    }

    func testEnrollingProducesCreamTitleAndModelRemainsLiveWithoutElapsed() {
        let presentation = WatchCaptureOwnerPresentation(
            status: .enrolling,
            queuedCount: 0,
            isSessionRunning: true,
            sessionStartedAt: nil
        )
        let model = watchFaceModel(for: presentation, isReachable: true)
        XCTAssertFalse(model.showsElapsed)
        XCTAssertEqual(model.stateColorRole, .live)

        let hero = watchHomeHero(
            model: model,
            status: presentation.status,
            sessionStartedAt: presentation.sessionStartedAt,
            now: Date()
        )
        XCTAssertEqual(hero.title, SourceVocabulary.watchHeadlineEnrolling)
        XCTAssertTrue(hero.titleIsLarge)
        XCTAssertEqual(hero.titleHex, WatchHomePalette.cream)
        XCTAssertNil(hero.elapsedDisplay)
        XCTAssertNil(hero.spokenElapsed)
    }

    func testOffProducesCalmTitle() {
        let presentation = WatchCaptureOwnerPresentation(
            status: .off,
            queuedCount: 0,
            isSessionRunning: false,
            sessionStartedAt: nil
        )
        let model = watchFaceModel(for: presentation, isReachable: false)

        let hero = watchHomeHero(
            model: model,
            status: presentation.status,
            sessionStartedAt: presentation.sessionStartedAt,
            now: Date()
        )
        XCTAssertEqual(hero.title, SourceVocabulary.watchHeadlineOff)
        XCTAssertTrue(hero.titleIsLarge)
        XCTAssertEqual(hero.titleHex, WatchHomePalette.calm)
        XCTAssertNil(hero.elapsedDisplay)
    }

    func testNeedsAttentionProducesAlertTitleWithTwoLines() {
        let presentation = WatchCaptureOwnerPresentation(
            status: .needsAttention(.unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable)),
            queuedCount: 0,
            isSessionRunning: false,
            sessionStartedAt: nil
        )
        let model = watchFaceModel(for: presentation, isReachable: true)

        let hero = watchHomeHero(
            model: model,
            status: presentation.status,
            sessionStartedAt: presentation.sessionStartedAt,
            now: Date()
        )
        XCTAssertEqual(hero.title, SourceVocabulary.watchMicrophoneUnavailable)
        XCTAssertTrue(hero.titleIsLarge)
        XCTAssertEqual(hero.titleLineLimit, 2)
        XCTAssertEqual(hero.titleHex, WatchHomePalette.alert)
        XCTAssertNil(hero.elapsedDisplay)
    }
}
