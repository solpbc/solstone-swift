// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LocationManagerTests: XCTestCase {
    @MainActor private lazy var provider = MockLocationProvider()
    @MainActor private lazy var clock = MockObserverClock()
    @MainActor private lazy var liveActivity = MockLocationLiveActivity()
    private lazy var uploader = RecordingLocationUploader()
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "LocationManagerTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testInitDoesNotRequestAuthorizationBeforeTierChoice() async {
        _ = self.makeManager()

        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
    }

    @MainActor
    func testLightRequestsWhenInUseOnlyAndStartsVisits() async {
        let manager = self.makeManager()

        await manager.start(tier: .light)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(manager.sourceState, .enrolling)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.currentStartedModes, [.visits])
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testBalancedRequestsAlwaysFromAuthorizationCallback() async {
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)
        XCTAssertEqual(manager.sourceState, .enrolling)

        self.provider.emitAuthorization(.always(accuracy: .reduced))
        await self.yieldToMainActor()
        XCTAssertEqual(self.provider.currentStartedModes, [.visits, .significantChanges])
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testFullRequiresAlwaysFullAccuracy() async {
        let manager = self.makeManager()

        await manager.start(tier: .full)
        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)

        self.provider.emitAuthorization(.always(accuracy: .reduced))
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertNil(self.provider.currentStartedModes)

        self.provider.emitAuthorization(.always(accuracy: .full))
        await self.yieldToMainActor()
        XCTAssertEqual(self.provider.currentStartedModes, [.liveUpdates])
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testLesserGrantKeepsTierAndStartedModesUnchanged() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        XCTAssertEqual(self.provider.currentStartedModes, [.visits, .significantChanges])

        let startCallCount = self.provider.startCallCount
        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.tier, .balanced)
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(self.provider.startCallCount, startCallCount)
        XCTAssertEqual(self.provider.currentStartedModes, [.visits, .significantChanges])
    }

    @MainActor
    func testSufficientAuthorizationCallbackDoesNotRestartObservation() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        XCTAssertEqual(self.provider.currentStartedModes, [.visits, .significantChanges])

        let startCallCount = self.provider.startCallCount
        self.provider.emitAuthorization(.always(accuracy: .full))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.tier, .balanced)
        XCTAssertEqual(manager.sourceState, .active)
        XCTAssertEqual(self.provider.startCallCount, startCallCount)
        XCTAssertEqual(self.provider.currentStartedModes, [.visits, .significantChanges])
    }

    @MainActor
    func testRestrictedExposesNoOpenSettingsRecovery() async {
        self.provider.capability = .restricted
        let manager = self.makeManager()

        await manager.start(tier: .balanced)

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttention, SourceAttention(message: LocationVocabulary.restrictedBody))
        XCTAssertEqual(manager.recoveryActions, [])
    }

    @MainActor
    func testDeniedExposesOpenSettingsRecovery() async {
        self.provider.capability = .denied
        let manager = self.makeManager()

        await manager.start(tier: .balanced)

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttention?.actionHint, LocationVocabulary.openSettingsAction)
        XCTAssertEqual(manager.recoveryActions, [.openSettings])
    }

    @MainActor
    func testSegmentationEnqueuesEvery300Seconds() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitFix(MockLocationProvider.fix())
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].fixes.count, 1)
        XCTAssertEqual(batches[0].tier, .balanced)
        XCTAssertEqual(batches[0].accuracy, .full)
        XCTAssertEqual(batches[0].coveredSeconds, 300)
    }

    @MainActor
    func testEmptySegmentSkippedOnTimer() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        XCTAssertEqual(self.uploader.batchCount(), 0)
        guard case .active(let session) = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.currentSegmentIndex, 0)
        XCTAssertTrue(self.liveActivity.updateCalls.isEmpty)
    }

    @MainActor
    func testGapOnlySegmentIsEnqueued() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        self.provider.emitGap()
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].gap)
    }

    @MainActor
    func testSegmentWithFixIsEnqueued() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        let fix = MockLocationProvider.fix()
        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].fixes, [fix])
    }

    @MainActor
    func testCoveredSecondsNotInflatedAfterSkippedEmptyWindow() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        XCTAssertEqual(self.uploader.batchCount(), 0)

        self.provider.emitFix(MockLocationProvider.fix())
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].coveredSeconds, 300)
    }

    @MainActor
    func testStopFlushesFinalPartialSegment() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)

        self.provider.emitVisit(MockLocationProvider.visit())
        await self.yieldToMainActor()
        await manager.stop()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].visits.count, 1)
    }

    @MainActor
    func testProviderGapSetsBatchGapAndResetsAfterEnqueue() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        self.provider.emitGap()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].gap)
    }

    @MainActor
    func testWatchdogTripForcesNeedsAttentionAndGapOnNextBatch() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager(watchdogThreshold: .seconds(10))
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        manager.noteAppDidEnterBackground()
        await self.yieldToMainActor()
        self.clock.advance(by: 10)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttention?.actionHint, LocationVocabulary.matchToAllowedAction)

        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        let batches = self.uploader.batches()
        XCTAssertTrue(batches.last?.gap ?? false)
    }

    @MainActor
    func testBackgroundFixDisarmsWatchdog() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager(watchdogThreshold: .seconds(10))
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        manager.noteAppDidEnterBackground()
        await self.yieldToMainActor()
        self.provider.emitFix(MockLocationProvider.fix(), context: .background)
        await self.yieldToMainActor()
        self.clock.advance(by: 10)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testTierChangePersistsRestartsModesAndDoesNotEnqueue() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        let batchesBefore = self.uploader.batches()

        await manager.changeTier(.full)

        XCTAssertEqual(self.uploader.batches(), batchesBefore)
        XCTAssertEqual(manager.tier, .full)
        XCTAssertEqual(self.defaults.string(forKey: "location.tier"), "full")
        XCTAssertEqual(self.provider.currentStartedModes, [.liveUpdates])
    }

    @MainActor
    func testTierPersistsAcrossReinitWithSameSuite() async {
        var manager: LocationManager? = self.makeManager()
        await manager?.changeTier(.full)
        manager = nil

        let nextProvider = MockLocationProvider()
        let nextManager = LocationManager(
            provider: nextProvider,
            uploader: self.uploader,
            clock: self.clock,
            defaults: self.defaults
        )

        XCTAssertEqual(nextManager.tier, .full)
    }

    @MainActor
    func testGapOnRevokeMidRunHasOnlyProviderEmittedFixes() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitFix(MockLocationProvider.fix())
        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let batches = self.uploader.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].gap)
        XCTAssertEqual(batches[0].fixes, [MockLocationProvider.fix()])
    }

    @MainActor
    func testOffToEnrollingToActiveSourceState() async {
        let manager = self.makeManager()
        XCTAssertEqual(manager.sourceState, .off)

        await manager.start(tier: .light)
        XCTAssertEqual(manager.sourceState, .enrolling)

        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testMatchToAllowedIsOnlyProgrammaticDowngradePath() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.tier, .balanced)
        XCTAssertEqual(manager.recoveryActions, [.openSettings, .matchToAllowed(suggestedTier: .light)])

        await manager.matchToAllowed()

        XCTAssertEqual(manager.tier, .light)
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testPauseCancelsSegmentationAndBackgroundSustain() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)

        await manager.pause()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        XCTAssertEqual(self.provider.stopCallCount, 1)
        XCTAssertEqual(self.provider.endBackgroundSustainCallCount, 1)
        XCTAssertEqual(self.uploader.batchCount(), 0)
        XCTAssertEqual(manager.sourceState, .paused)
        XCTAssertNil(manager.sourceAttention)
        XCTAssertTrue(manager.recoveryActions.isEmpty)

        await manager.resume()

        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testLiveActivityStartsOnActiveForBalancedTier() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)

        guard case .active(let session) = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
        XCTAssertEqual(self.liveActivity.startCalls.first?.tierLabel, LocationTier.balanced.label)
        XCTAssertEqual(self.liveActivity.startCalls.first?.sessionID, session.sessionID.uuidString)
    }

    @MainActor
    func testLiveActivityStartsOnActiveForFullTier() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .full)

        guard case .active(let session) = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
        XCTAssertEqual(self.liveActivity.startCalls.first?.tierLabel, LocationTier.full.label)
        XCTAssertEqual(self.liveActivity.startCalls.first?.sessionID, session.sessionID.uuidString)
    }

    @MainActor
    func testLiveActivityDoesNotStartOrUpdateForLightTier() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .light)
        await manager.stop()

        XCTAssertTrue(self.liveActivity.startCalls.isEmpty)
        XCTAssertTrue(self.liveActivity.updateCalls.isEmpty)
        XCTAssertEqual(self.liveActivity.endCallCount, 1)
    }

    @MainActor
    func testLiveActivityEndsExactlyOnceOnStop() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await manager.stop()

        XCTAssertEqual(self.liveActivity.endCallCount, 1)
        XCTAssertEqual(self.provider.endBackgroundSustainCallCount, 1)
        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testLiveActivityPauseEndsExactlyOnceThroughStop() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await manager.pause()

        XCTAssertEqual(self.liveActivity.endCallCount, 1)
        XCTAssertEqual(manager.sourceState, .paused)
    }

    @MainActor
    func testLiveActivityUpdatesOnSegmentBoundaries() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitFix(MockLocationProvider.fix())
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        self.provider.emitFix(MockLocationProvider.fix())
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        XCTAssertEqual(self.liveActivity.updateCalls.count, 2)
        guard self.liveActivity.updateCalls.count == 2 else { return }
        XCTAssertEqual(self.liveActivity.updateCalls[0].tierLabel, LocationTier.balanced.label)
        XCTAssertEqual(self.liveActivity.updateCalls[0].segmentCount, 1)
        XCTAssertEqual(self.liveActivity.updateCalls[1].tierLabel, LocationTier.balanced.label)
        XCTAssertEqual(self.liveActivity.updateCalls[1].segmentCount, 2)
    }

    @MainActor
    func testLiveActivityDoesNotUpdateDuringStopFlush() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.provider.emitFix(MockLocationProvider.fix())
        await self.yieldToMainActor()

        await manager.stop()

        XCTAssertTrue(self.liveActivity.updateCalls.isEmpty)
        XCTAssertEqual(self.liveActivity.endCallCount, 1)
        XCTAssertEqual(self.uploader.batchCount(), 1)
    }

    @MainActor
    func testLiveActivityEndsWhenChangingFromFullToLight() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .full)

        await manager.changeTier(.light)

        XCTAssertEqual(self.liveActivity.endCallCount, 1)
        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
        XCTAssertTrue(self.liveActivity.updateCalls.isEmpty)
    }

    @MainActor
    func testLiveActivityStartsWhenChangingFromLightToBalanced() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        guard case .active(let session) = manager.state else {
            return XCTFail("Expected active state")
        }

        await manager.changeTier(.balanced)

        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
        XCTAssertEqual(self.liveActivity.startCalls.first?.tierLabel, LocationTier.balanced.label)
        XCTAssertEqual(self.liveActivity.startCalls.first?.sessionID, session.sessionID.uuidString)
        XCTAssertEqual(self.liveActivity.endCallCount, 0)
    }

    @MainActor
    func testLiveActivityUpdatesWhenChangingFromBalancedToFull() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)

        await manager.changeTier(.full)

        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
        XCTAssertEqual(self.liveActivity.updateCalls.count, 1)
        XCTAssertEqual(self.liveActivity.updateCalls.first?.tierLabel, LocationTier.full.label)
        XCTAssertEqual(self.liveActivity.updateCalls.first?.segmentCount, 0)
        XCTAssertEqual(self.liveActivity.endCallCount, 0)
    }

    @MainActor
    func testStopEndsLiveActivityAfterTierRestartFailure() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.provider.startError = LocationManagerTestError.restartFailed

        await manager.changeTier(.full)
        guard case .error = manager.state else {
            return XCTFail("Expected error state")
        }
        await manager.stop()

        XCTAssertEqual(self.liveActivity.endCallCount, 1)
        XCTAssertEqual(self.provider.endBackgroundSustainCallCount, 1)
        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testStopForDeleteClearsPausedState() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await manager.pause()
        XCTAssertEqual(manager.sourceState, .paused)

        await manager.stopForDelete()

        XCTAssertEqual(manager.sourceState, .off)
    }

    @MainActor
    private func makeManager(
        watchdogThreshold: Duration = .seconds(600),
        liveActivity: (any LocationLiveActivitying)? = nil
    ) -> LocationManager {
        LocationManager(
            provider: self.provider,
            uploader: self.uploader,
            clock: self.clock,
            defaults: self.defaults,
            watchdogThreshold: watchdogThreshold,
            liveActivity: liveActivity ?? self.liveActivity
        )
    }

    @MainActor
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private enum LocationManagerTestError: Error {
    case restartFailed
}
