@testable import solstone_swift
import XCTest

nonisolated final class ComposerTalentElapsedModelTests: XCTestCase {
    @MainActor
    func testTickTaskStopsWhenNoTalentWorkRemains() {
        let model = ComposerTalentElapsedModel()

        model.update(isBusy: true, reduceMotion: false)
        XCTAssertTrue(model.isTicking)

        model.update(isBusy: false, reduceMotion: false)
        XCTAssertFalse(model.isTicking)
    }

    @MainActor
    func testTickTaskDoesNotStartUnderReduceMotion() {
        let model = ComposerTalentElapsedModel()

        model.update(isBusy: true, reduceMotion: true)

        XCTAssertFalse(model.isTicking)
    }
}
