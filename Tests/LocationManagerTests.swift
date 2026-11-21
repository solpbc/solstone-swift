// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreLocation
import Foundation
import os
import XCTest

nonisolated final class LocationManagerTests: XCTestCase {
    @MainActor private lazy var provider = MockLocationProvider()
    @MainActor private lazy var clock = MockObserverClock()
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    @MainActor private lazy var mobileSegmentUploader = MobileSegmentUploader(
        store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)),
        clock: self.clock
    )
    @MainActor private lazy var mobileSegmentEngine = MobileSegmentEngine(
        uploader: self.mobileSegmentUploader,
        clock: self.clock
    )

    override func setUp() {
        super.setUp()
        self.suiteName = "LocationManagerTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocationManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testInitDoesNotRequestAuthorizationBeforeTierChoice() async {
        _ = self.makeManager()

        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
    }

    @MainActor
    func testSharingGrantReturnsInitialRawProviderCapabilityBeforeActive() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()

        XCTAssertEqual(manager.sharingGrant, .always(accuracy: .reduced))
        XCTAssertEqual(manager.sourceState, .readyToSetUp)
    }

    @MainActor
    func testSharingGrantTracksAuthorizationChangesWhileActive() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sharingGrant, .always(accuracy: .full))

        self.provider.emitAuthorization(.always(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sharingGrant, .always(accuracy: .reduced))
        XCTAssertEqual(manager.sourceState, .active)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sharingGrant, .whenInUse(accuracy: .reduced))
        XCTAssertEqual(manager.sourceState, .needsAttention)
    }

    @MainActor
    func testIsSustainingBackgroundFalseWhenAlwaysTierOnlyHasWhenInUse() async {
        self.provider.capability = .whenInUse(accuracy: .reduced)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertFalse(manager.isSustainingBackground)
        guard case .error = manager.state else {
            return XCTFail("Expected non-active state")
        }
    }

    @MainActor
    func testIsSustainingBackgroundTrueWhenAlwaysGrantedAndActive() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        XCTAssertTrue(manager.isSustainingBackground)
    }

    @MainActor
    func testSunArcPresentationCoordinateTracksOnlyActiveFixesAndClearsAtLifecycleBoundaries() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        let fix = MockLocationProvider.fix()
        let coordinate = SunArcCoordinate(latitude: fix.lat, longitude: fix.lon)

        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        XCTAssertNil(manager.sunArcPresentationCoordinate)

        await manager.start(tier: .balanced)
        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sunArcPresentationCoordinate, coordinate)

        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()
        XCTAssertNil(manager.sunArcPresentationCoordinate)

        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sunArcPresentationCoordinate, coordinate)

        await manager.stop()
        XCTAssertNil(manager.sunArcPresentationCoordinate)
    }

    @MainActor
    func testSunArcPresentationCoordinateClearsWhenActiveTierChangeBecomesUnsatisfied() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()
        let fix = MockLocationProvider.fix()
        let coordinate = SunArcCoordinate(latitude: fix.lat, longitude: fix.lon)

        await manager.start(tier: .balanced)
        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sunArcPresentationCoordinate, coordinate)

        await manager.changeTier(.full)

        XCTAssertNil(manager.sunArcPresentationCoordinate)
        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
    }

    @MainActor
    func testSunArcPresentationCoordinateClearsOnSatisfiedTierChangeRestart() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        let fix = MockLocationProvider.fix()
        let coordinate = SunArcCoordinate(latitude: fix.lat, longitude: fix.lon)

        await manager.start(tier: .balanced)
        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sunArcPresentationCoordinate, coordinate)

        // `.full` is satisfied by `.always(accuracy: .full)`, so this restarts the
        // provider for the new tier rather than marking a gap — the stale fix from
        // the old tier must not survive the restart.
        await manager.changeTier(.full)

        XCTAssertNil(manager.sunArcPresentationCoordinate)
        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
    }

    @MainActor
    func testIsSustainingBackgroundFalseWhenAlwaysRevokedWhileActive() async {
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()
        XCTAssertTrue(manager.isSustainingBackground)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertFalse(manager.isSustainingBackground)
        XCTAssertEqual(self.provider.endBackgroundSustainCallCount, 1)
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
    func testAlwaysTierDeclineResolvesAfterBoundedWait() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)
        await self.waitForPendingSleeperCount(1)

        self.clock.advance(by: 11)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(manager.recoveryActions, [.openSettings, .matchToAllowed(suggestedTier: .light)])
    }

    @MainActor
    func testAlwaysTierGrantBeforeBoundedWaitKeepsActive() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.waitForPendingSleeperCount(1)

        self.provider.emitAuthorization(.always(accuracy: .reduced))
        await self.yieldToMainActor()
        let startCallCount = self.provider.startCallCount
        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }

        self.clock.advance(by: 11)
        await self.yieldToMainActor()

        guard case .active = manager.state else {
            return XCTFail("Expected active state after bounded wait")
        }
        XCTAssertEqual(self.provider.startCallCount, startCallCount)
    }

    @MainActor
    func testAlwaysTierBoundedWaitCancelledOnStop() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.waitForPendingSleeperCount(1)

        await manager.stop()
        XCTAssertEqual(manager.state, .idle)

        self.clock.advance(by: 11)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(self.clock.pendingSleeperCount, 0)
    }

    @MainActor
    func testResumeIfEnabledRepollsStartingAndActivatesWithAlwaysGrant() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.waitForPendingSleeperCount(1)

        self.provider.capability = .always(accuracy: .reduced)
        await manager.resumeIfEnabled()
        let startCallCount = self.provider.startCallCount
        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }

        self.clock.advance(by: 11)
        await self.yieldToMainActor()

        guard case .active = manager.state else {
            return XCTFail("Expected active state after bounded wait")
        }
        XCTAssertEqual(self.provider.startCallCount, startCallCount)
    }

    @MainActor
    func testResumeIfEnabledRepollsStartingAndErrorsWhenStillWhenInUse() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.waitForPendingSleeperCount(1)

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        self.clock.advance(by: 11)
        await self.yieldToMainActor()
        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
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
        XCTAssertEqual(self.provider.currentStartedModes, [.liveUpdates, .significantChanges])
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

        // ⚠ The subject of this test is the RECOVERY, and it survives the state word: an
        // owner who declined still gets the ios-settings route, which ios itself will not
        // re-offer. The word is `ready to set up` because they declined rather than broke
        // something — covered directly by the two declined-permission tests above.
        XCTAssertEqual(manager.sourceState, .readyToSetUp)
        XCTAssertEqual(manager.recoveryActions, [.openSettings])
    }

    @MainActor
    func testSegmentationCreatesMobileSegmentBundleEvery300Seconds() async throws {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitFix(MockLocationProvider.fix())
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let summary = self.mobileSegmentUploader.summary(for: .location)
        XCTAssertEqual(summary.pendingCount, 1)
        let manifest = try self.pendingLocationManifest()
        XCTAssertEqual(manifest.location.fixCount, 1)
        XCTAssertEqual(manifest.location.durationS, 300)
    }

    @MainActor
    func testEmptySegmentSkippedOnTimer() async throws {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, 0)
        XCTAssertEqual(try self.emptyTombstoneCount(), 1)
        guard case .active(let session) = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.currentSegmentIndex, 0)
    }

    @MainActor
    func testGapOnlySegmentCreatesHeaderOnlyMobileSegmentBundle() async throws {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        self.provider.emitGap()
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, 1)
        XCTAssertEqual(try self.emptyTombstoneCount(), 0)
        let manifest = try self.pendingLocationManifest()
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.fixCount, 0)
        try self.assertHeaderOnlyGapPayload()
    }

    @MainActor
    func testSegmentWithFixCreatesMobileSegmentBundle() async throws {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        let fix = MockLocationProvider.fix()
        self.provider.emitFix(fix)
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let summary = self.mobileSegmentUploader.summary(for: .location)
        XCTAssertEqual(summary.pendingCount, 1)
        let payload = try self.pendingLocationPayload()
        XCTAssertTrue(payload.contains(#""lat""#))
        XCTAssertTrue(payload.contains(#""lon""#))
    }

    @MainActor
    func testCoveredSecondsNotInflatedAfterSkippedEmptyWindow() async throws {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.yieldToMainActor()

        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, 0)
        XCTAssertEqual(try self.emptyTombstoneCount(), 1)

        self.provider.emitFix(MockLocationProvider.fix())
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let manifest = try self.pendingLocationManifest()
        XCTAssertEqual(manifest.location.durationS, 300)
    }

    @MainActor
    func testStopFlushesFinalPartialSegment() async throws {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)

        self.provider.emitVisit(MockLocationProvider.visit())
        await self.yieldToMainActor()
        await manager.stop()

        let summary = self.mobileSegmentUploader.summary(for: .location)
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertTrue(try self.pendingLocationPayload().contains("solstone.location.visit"))
    }

    @MainActor
    func testProviderGapSetsBatchGapAndResetsAfterEnqueue() async throws {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .light)
        await self.waitForPendingSleeperCount(2)

        self.provider.emitGap()
        await self.yieldToMainActor()
        // A location segment arms two timers: rotation and liveness. An advance only
        // fires timers already armed, and the engine re-arms rotation only after it
        // finishes closing the window, so wait for both before each advance and
        // before asserting. A fixed sleep lost this race on a loaded host.
        self.clock.advance(by: 300)
        await self.waitForPendingSleeperCount(2)
        self.clock.advance(by: 300)
        await self.waitForPendingSleeperCount(2)

        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, 1)
        XCTAssertEqual(try self.emptyTombstoneCount(), 1)
        let manifest = try self.pendingLocationManifest()
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.fixCount, 0)
        try self.assertHeaderOnlyGapPayload()
    }

    @MainActor
    func testStationaryAlwaysStaysActiveWithoutGap() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.clock.advance(by: 3600)
        await self.yieldToMainActor()

        XCTAssertTrue(manager.isAuthorizationSufficient(for: .balanced))
        XCTAssertEqual(manager.sourceState, .active)
        XCTAssertNil(manager.sourceAttention)
        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, 0)
    }

    @MainActor
    func testTierChangePersistsRestartsModesAndDoesNotEnqueue() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        let pendingBefore = self.mobileSegmentUploader.summary(for: .location).pendingCount

        await manager.changeTier(.full)

        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, pendingBefore)
        XCTAssertEqual(manager.tier, .full)
        XCTAssertEqual(self.defaults.string(forKey: "location.tier"), "full")
        XCTAssertEqual(self.provider.currentStartedModes, [.liveUpdates, .significantChanges])
    }

    @MainActor
    func testTierPersistsAcrossReinitWithSameSuite() async {
        var manager: LocationManager? = self.makeManager()
        await manager?.changeTier(.full)
        manager = nil

        let nextProvider = MockLocationProvider()
        let nextManager = LocationManager(
            provider: nextProvider,
            mobileSegmentEngine: self.mobileSegmentEngine,
            clock: self.clock,
            defaults: self.defaults
        )

        XCTAssertEqual(nextManager.tier, .full)
    }

    @MainActor
    func testEnabledPausedPersistenceWritePoints() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        XCTAssertEqual(self.defaults.bool(forKey: "location.enabled"), true)
        XCTAssertEqual(self.defaults.bool(forKey: "location.paused"), false)

        await manager.pause()
        XCTAssertEqual(self.defaults.bool(forKey: "location.enabled"), true)
        XCTAssertEqual(self.defaults.bool(forKey: "location.paused"), true)
        XCTAssertEqual(manager.sourceState, .paused)

        await manager.resume()
        XCTAssertEqual(self.defaults.bool(forKey: "location.enabled"), true)
        XCTAssertEqual(self.defaults.bool(forKey: "location.paused"), false)
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testChangeTierDoesNotTouchEnabledPausedPersistence() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.defaults.set(false, forKey: "location.enabled")
        self.defaults.set(true, forKey: "location.paused")

        await manager.changeTier(.full)

        XCTAssertEqual(self.defaults.bool(forKey: "location.enabled"), false)
        XCTAssertEqual(self.defaults.bool(forKey: "location.paused"), true)
    }

    @MainActor
    func testResumeIfEnabledRearmsWithoutPromptAndStartsObservation() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .always(accuracy: .reduced)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .active)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 1)
    }

    @MainActor
    func testResumeIfEnabledPausedRestoresPausedWithoutStarting() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(true, forKey: "location.paused")
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .paused)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 0)
    }

    /// 🔴 Declining the ios dialog is not a fault. The owner was asked and said no, so
    /// there is no evidence the permission was ever held. ⚠ The reason line and the
    /// recovery survive the word — both are drawn from the capability, not the state — so
    /// an owner who declined by accident still has a route back via ios settings.
    @MainActor
    func testDeclinedPermissionReadsReadyToSetUpAndKeepsItsRecovery() async {
        self.provider.capability = .denied
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(manager.sourceState, .readyToSetUp)
        XCTAssertNotNil(manager.sourceAttention)
        XCTAssertEqual(manager.recoveryActions, [.openSettings])

        let source = makeLocationSource(
            state: manager.sourceState,
            attention: manager.sourceAttention,
            isJournalPaired: true,
            subtextOverride: manager.sourceAttentionLine
        )
        XCTAssertNil(source.subtextOverride)
        XCTAssertNil(source.rowSubtext)
        XCTAssertEqual(source.voiceOverText, SourceVocabulary.sourceStateReadyToSetUpLabel)
    }

    /// 🔴 ⛔ Only an OUTRIGHT DECLINE softens. These three are insufficient-capability faults
    /// that `ready to set up` must never swallow, and the first version of this rule did:
    /// a device restriction and disabled location services mean the owner did not decline
    /// and *cannot* set it up, and a partial grant means they said yes, just not enough.
    @MainActor
    func testOnlyAnOutrightDeclineSoftens() async {
        for capability in [LocationCapability.restricted, .servicesDisabled] {
            self.provider.capability = capability
            let manager = self.makeManager()
            await manager.start(tier: .balanced)
            XCTAssertEqual(manager.sourceState, .needsAttention, "\(capability)")
        }

        // A partial grant: the owner allowed `always` but only at reduced accuracy, under a
        // tier that needs full. ⚠ The grant has to actually ARRIVE — a manager still waiting
        // on the always-upgrade prompt is `enrolling`, not a fault, and an earlier draft of
        // this test asserted against that window instead of the outcome.
        self.provider.capability = .notDetermined
        let partial = self.makeManager()
        await partial.start(tier: .full)
        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()
        self.provider.emitAuthorization(.always(accuracy: .reduced))
        await self.yieldToMainActor()
        XCTAssertEqual(partial.sourceState, .needsAttention)
    }

    /// ⛔ Once the owner HAS set location up, a missing permission is a genuine fault:
    /// something they enabled stopped working.
    @MainActor
    func testDeclinedPermissionIsStillAFaultOnceEnabled() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.provider.capability = .denied
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sourceState, .needsAttention)
    }

    /// An enabled source that is idle and unpaused still reads `off` — the owner's own
    /// choice is reported as a choice. ⛔ Only the absence of a record reads as never set up.
    @MainActor
    func testEnabledButIdleStillReadsOff() async {
        self.defaults.set(true, forKey: "location.enabled")
        let manager = self.makeManager()

        XCTAssertEqual(manager.sourceState, .off)
    }

    @MainActor
    func testResumeIfNeverEnabledStaysReadyToSetUpAndEndsOrphans() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .readyToSetUp)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 0)
    }

    @MainActor
    func testResumeIfEnabledNotDeterminedDoesNotRequestPermission() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .notDetermined
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 0)
    }

    @MainActor
    func testResumeIfEnabledDeniedDoesNotRequestPermission() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .denied
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 0)
    }

    @MainActor
    func testResumeIfEnabledWhenInUseForBalancedDoesNotRequestAlways() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 0)
    }

    @MainActor
    func testResumeIfEnabledNoopsWhenAlreadyActive() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        let startCallCount = self.provider.startCallCount

        await manager.resumeIfEnabled()

        XCTAssertEqual(self.provider.startCallCount, startCallCount)
    }

    @MainActor
    func testGapOnRevokeMidRunHasOnlyProviderEmittedFixes() async throws {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitFix(MockLocationProvider.fix())
        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

        let summary = self.mobileSegmentUploader.summary(for: .location)
        XCTAssertEqual(summary.pendingCount, 1)
        let payload = try self.pendingLocationPayload()
        XCTAssertTrue(payload.contains("solstone.location.fix"))
    }

    @MainActor
    func testReadyToSetUpToEnrollingToActiveSourceState() async {
        let manager = self.makeManager()
        XCTAssertEqual(manager.sourceState, .readyToSetUp)

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
        XCTAssertEqual(self.mobileSegmentUploader.summary(for: .location).pendingCount, 0)
        XCTAssertEqual(manager.sourceState, .paused)
        XCTAssertNil(manager.sourceAttention)
        XCTAssertTrue(manager.recoveryActions.isEmpty)

        await manager.resume()

        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testStopAfterTierRestartFailure() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.provider.startError = LocationManagerTestError.restartFailed

        await manager.changeTier(.full)
        guard case .error = manager.state else {
            return XCTFail("Expected error state")
        }
        await manager.stop()

        XCTAssertEqual(self.provider.endBackgroundSustainCallCount, 1)
        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testActivateSessionEngineFailureStopsProviderAndLeavesErrorState() async throws {
        self.provider.capability = .always(accuracy: .full)
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        store.testCreateActiveError = NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "simulated engine store error"])
        self.mobileSegmentUploader = MobileSegmentUploader(store: store, clock: self.clock)
        self.mobileSegmentEngine = MobileSegmentEngine(uploader: self.mobileSegmentUploader, clock: self.clock)
        let failingManager = self.makeManager()

        await failingManager.start(tier: .balanced)
        await self.yieldToMainActor()

        guard case .error = failingManager.state else {
            return XCTFail("Expected error state on engine failure, got \(failingManager.state)")
        }
        XCTAssertEqual(self.provider.stopCallCount, 1)
        XCTAssertFalse(self.defaults.bool(forKey: "location.enabled"))
    }

    @MainActor
    func testAttentionLineBelowChosenWhileActiveBelowTier() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()

        guard case .active = manager.state else {
            return XCTFail("Expected state to remain active")
        }
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionBelowChosen)
    }

    @MainActor
    func testAttentionLineDeniedWhileActiveAfterRevoke() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        self.provider.emitAuthorization(.denied)
        await self.yieldToMainActor()

        guard case .active = manager.state else {
            return XCTFail("Expected state to remain active")
        }
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionDenied)
    }

    @MainActor
    func testAttentionLineBelowChosenOnInsufficientError() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionBelowChosen)
    }

    @MainActor
    func testAttentionLineRestrictedOnInsufficientError() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .restricted
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionRestricted)
    }

    @MainActor
    func testAttentionLineServicesOffOnInsufficientError() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .servicesDisabled
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionServicesOff)
    }

    @MainActor
    func testAttentionLineNotAllowedYetWhenEnabledAndNotDetermined() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .notDetermined
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionNotAllowedYet)
    }

    @MainActor
    func testAttentionLineDeniedWhenEnabledAndDenied() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .denied
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionDenied)
    }

    @MainActor
    func testAttentionLineNotRunningOnUnavailableError() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.provider.startError = LocationManagerTestError.restartFailed

        await manager.changeTier(.full)
        await self.yieldToMainActor()

        guard case .error(.unavailable) = manager.state else {
            return XCTFail("Expected .error(.unavailable) state")
        }
        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttentionLine, LocationVocabulary.locationAttentionNotRunning)
    }

    @MainActor
    func testChangeTierSatisfiedFromRelaunchErrorStartsSession() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.startCallCount, 0)

        let initialRequestAlways = self.provider.requestAlwaysCallCount
        let initialBeginBackgroundSustain = self.provider.beginBackgroundSustainCallCount

        await manager.changeTier(.light)

        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(self.provider.startCallCount, 1)
        XCTAssertEqual(self.provider.currentStartedModes, LocationTier.light.modes)
        XCTAssertEqual(self.provider.beginBackgroundSustainCallCount, initialBeginBackgroundSustain)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, initialRequestAlways)
    }

    @MainActor
    func testChangeTierSatisfiedFromDeclineWaitErrorStartsSession() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)
        await self.waitForPendingSleeperCount(1)

        self.clock.advance(by: 11)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.startCallCount, 0)

        let initialRequestAlways = self.provider.requestAlwaysCallCount
        let initialBeginBackgroundSustain = self.provider.beginBackgroundSustainCallCount

        await manager.changeTier(.light)

        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(self.provider.startCallCount, 1)
        XCTAssertEqual(self.provider.currentStartedModes, LocationTier.light.modes)
        XCTAssertEqual(self.provider.beginBackgroundSustainCallCount, initialBeginBackgroundSustain)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, initialRequestAlways)
    }

    @MainActor
    func testChangeTierUnsatisfiedFromDeclineWaitErrorStaysError() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.start(tier: .balanced)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)
        await self.waitForPendingSleeperCount(1)

        self.clock.advance(by: 11)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.startCallCount, 0)

        let initialRequestAlways = self.provider.requestAlwaysCallCount
        let initialStartCallCount = self.provider.startCallCount

        await manager.changeTier(.full)

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.requestAlwaysCallCount, initialRequestAlways)
        XCTAssertEqual(self.provider.startCallCount, initialStartCallCount)
    }

    @MainActor
    func testChangeTierUnsatisfiedFromRelaunchErrorStaysError() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.startCallCount, 0)

        await manager.changeTier(.full)

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.startCallCount, 0)
    }

    @MainActor
    func testChangeTierDoesNotStartWhenOffPausedOrStarting() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let offManager = self.makeManager()

        await offManager.changeTier(.light)

        XCTAssertEqual(offManager.state, .idle)
        XCTAssertEqual(self.provider.startCallCount, 0)

        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(true, forKey: "location.paused")
        self.provider.capability = .always(accuracy: .full)
        let pausedManager = self.makeManager()

        await pausedManager.resumeIfEnabled()

        XCTAssertEqual(pausedManager.state, .idle)
        XCTAssertEqual(pausedManager.sourceState, .paused)
        XCTAssertEqual(self.provider.startCallCount, 0)

        await pausedManager.changeTier(.light)

        XCTAssertEqual(pausedManager.state, .idle)
        XCTAssertEqual(pausedManager.sourceState, .paused)
        XCTAssertEqual(self.provider.startCallCount, 0)

        self.provider.capability = .notDetermined
        let startingManager = self.makeManager()

        await startingManager.start(tier: .light)
        XCTAssertEqual(startingManager.sourceState, .enrolling)

        await startingManager.changeTier(.balanced)

        XCTAssertEqual(startingManager.state, .starting)
        XCTAssertEqual(self.provider.startCallCount, 0)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
    }

    @MainActor
    func testMatchToAllowedFromRelaunchErrorStartsSessionOnce() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.startCallCount, 0)

        await manager.matchToAllowed()

        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(self.provider.startCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(self.provider.currentStartedModes, LocationTier.light.modes)
    }

    @MainActor
    func testMatchToAllowedFromRelaunchErrorDoesNotStartAgainWhenActivationThrows() async {
        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        self.provider.capability = .whenInUse(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.state, .error(.capabilityInsufficient))
        XCTAssertEqual(self.provider.startCallCount, 0)

        self.provider.startError = LocationManagerTestError.restartFailed

        await manager.matchToAllowed()

        XCTAssertEqual(self.provider.startCallCount, 1)
        guard case .error(.unavailable) = manager.state else {
            return XCTFail("Expected .error(.unavailable) state")
        }
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
    }

    @MainActor
    func testChangeTierSatisfiedRecoversFromUnavailableError() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        self.provider.startError = LocationManagerTestError.restartFailed

        await manager.changeTier(.full)

        guard case .error(.unavailable) = manager.state else {
            return XCTFail("Expected .error(.unavailable) state")
        }

        self.provider.startError = nil
        let startCallCountBefore = self.provider.startCallCount

        await manager.changeTier(.balanced)

        guard case .active = manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(self.provider.startCallCount, startCallCountBefore + 1)
        XCTAssertEqual(self.provider.currentStartedModes, LocationTier.balanced.modes)
    }

    @MainActor
    func testAttentionLineNilWhenSatisfiedOrPaused() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()
        await manager.start(tier: .balanced)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sourceState, .active)
        XCTAssertNil(manager.sourceAttentionLine)

        await manager.pause()

        XCTAssertEqual(manager.sourceState, .paused)
        XCTAssertNil(manager.sourceAttentionLine)
    }

    @MainActor
    func testMakeHomeSourceBundleNamesNeedsAttentionLines() async {
        let observerManager = ObserverManager(
            recorder: MockObserverRecorder(),
            mobileSegmentEngine: self.mobileSegmentEngine,
            journalEvents: self.mobileSegmentUploader.journalEvents,
            defaults: self.defaults
        )
        observerManager.state = .error(.diskFull)

        self.provider.capability = .always(accuracy: .full)
        let locationManager = self.makeManager()
        await locationManager.start(tier: .balanced)
        await self.yieldToMainActor()
        self.provider.emitAuthorization(.whenInUse(accuracy: .full))
        await self.yieldToMainActor()

        let screencastRoot = self.tempDirectory.appendingPathComponent("screencast-\(UUID().uuidString)", isDirectory: true)
        let screencastManager = ScreencastManager(rootURL: screencastRoot)
        screencastManager.state = .needsAttention(.storageLow)

        let pauseState = ObserverSourcePauseState()

        let bundle = makeHomeSourceBundle(
            isJournalPaired: true,
            observerManager: observerManager,
            observerSourcePauseState: pauseState,
            locationManager: locationManager,
            screencastManager: screencastManager,
            watchLane: .unsupported
        )

        XCTAssertEqual(bundle.audio.subtextOverride, SourceVocabulary.audioAttentionStorageFull)
        XCTAssertEqual(bundle.location.subtextOverride, LocationVocabulary.locationAttentionBelowChosen)
        XCTAssertEqual(bundle.screencast.subtextOverride, SourceVocabulary.screencastAttentionStorageLow)

        XCTAssertEqual(bundle.audio.voiceOverText, "\(SourceVocabulary.needsAttention). \(SourceVocabulary.audioAttentionStorageFull)")
        XCTAssertEqual(bundle.location.voiceOverText, "\(SourceVocabulary.needsAttention). \(LocationVocabulary.locationAttentionBelowChosen)")
        XCTAssertEqual(bundle.screencast.voiceOverText, "\(SourceVocabulary.needsAttention). \(SourceVocabulary.screencastAttentionStorageLow)")
        XCTAssertNil(bundle.watch)
    }

    // MARK: - Phase 1 Startup & Foreground Unblock Tests

    @MainActor
    func testLiveLocationProviderOffMainServicesEnabledGenerationOrderingAndDelegateEmission() async throws {
        // 1. currentCapability() never invokes servicesEnabled synchronously; refreshServicesEnabled() runs off-main
        //    and updates LocationManager.sharingGrant == .servicesDisabled + .error(.capabilityInsufficient)
        //    on both resumeIfEnabled() and start(tier:).
        let calls = OSAllocatedUnfairLock<(count: Int, offMain: [Bool])>(initialState: (0, []))
        let liveProvider = LiveLocationProvider(
            servicesEnabled: {
                calls.withLock {
                    $0.count += 1
                    $0.offMain.append(!Thread.isMainThread)
                }
                return false
            },
            refreshOnInit: false
        )

        _ = liveProvider.currentCapability()
        XCTAssertEqual(calls.withLock { $0.count }, 0, "currentCapability() must not call servicesEnabled synchronously")

        self.defaults.set(true, forKey: "location.enabled")
        self.defaults.set(false, forKey: "location.paused")
        let resumeManager = LocationManager(
            provider: liveProvider,
            mobileSegmentEngine: self.mobileSegmentEngine,
            clock: self.clock,
            defaults: self.defaults
        )
        XCTAssertEqual(calls.withLock { $0.count }, 0)
        await resumeManager.resumeIfEnabled()
        XCTAssertEqual(resumeManager.sharingGrant, .servicesDisabled)
        XCTAssertEqual(resumeManager.state, .error(.capabilityInsufficient))
        XCTAssertGreaterThanOrEqual(calls.withLock { $0.count }, 1)
        XCTAssertTrue(calls.withLock { $0.offMain.allSatisfy { $0 } })

        let callsBeforeStart = calls.withLock { $0.count }
        let startManager = LocationManager(
            provider: liveProvider,
            mobileSegmentEngine: self.mobileSegmentEngine,
            clock: self.clock,
            defaults: self.defaults
        )
        await startManager.start(tier: .balanced)
        XCTAssertEqual(startManager.sharingGrant, .servicesDisabled)
        XCTAssertEqual(startManager.state, .error(.capabilityInsufficient))
        XCTAssertGreaterThan(calls.withLock { $0.count }, callsBeforeStart)
        XCTAssertTrue(calls.withLock { $0.offMain.allSatisfy { $0 } })

        // 2. Drops stale out-of-order refreshServicesEnabled() results.
        let slowEntered = DispatchSemaphore(value: 0)
        let slowRelease = DispatchSemaphore(value: 0)
        let orderIndex = OSAllocatedUnfairLock<Int>(initialState: 0)
        let orderedProvider = LiveLocationProvider(
            servicesEnabled: {
                let n = orderIndex.withLock { v -> Int in v += 1; return v }
                if n == 1 {
                    slowEntered.signal()
                    slowRelease.wait()
                    return false
                }
                return true
            },
            refreshOnInit: false
        )
        let slowRefresh = Task { await orderedProvider.refreshServicesEnabled() }
        let entered = await TestSemaphore.wait(slowEntered, timeout: .now() + 5)
        XCTAssertEqual(entered, .success)
        let newerCapability = await orderedProvider.refreshServicesEnabled()
        XCTAssertNotEqual(newerCapability, .servicesDisabled)
        slowRelease.signal()
        _ = await slowRefresh.value
        XCTAssertNotEqual(orderedProvider.currentCapability(), .servicesDisabled, "stale false must not overwrite newer true")

        // 3. locationManagerDidChangeAuthorization still emits onAuthorizationChanged even when servicesEnabled stays true.
        let emitted = OSAllocatedUnfairLock<[LocationCapability]>(initialState: [])
        let delegateProvider = LiveLocationProvider(
            servicesEnabled: { true },
            refreshOnInit: false
        )
        // Drain CLLocationManager's automatic initial delegate callback before installing the test observer.
        await self.yieldToMainActor()
        _ = await delegateProvider.refreshServicesEnabled()
        delegateProvider.onAuthorizationChanged = { cap in
            emitted.withLock { $0.append(cap) }
        }
        delegateProvider.locationManagerDidChangeAuthorization(CLLocationManager())
        for _ in 0..<50 where emitted.withLock({ $0.isEmpty }) {
            await self.yieldToMainActor()
        }
        XCTAssertEqual(emitted.withLock { $0.count }, 1)
    }

    @MainActor
    func testLocationManagerLifecycleGenerationGuardsMidAwaitInterruptions() async {
        // Negative twin: uninterrupted resumeIfEnabled() starts observation once.
        do {
            self.defaults.set(true, forKey: "location.enabled")
            self.defaults.set(false, forKey: "location.paused")
            let provider = SuspendingLocationProvider(capability: .always(accuracy: .full))
            let manager = LocationManager(
                provider: provider,
                mobileSegmentEngine: self.mobileSegmentEngine,
                clock: self.clock,
                defaults: self.defaults
            )
            await manager.resumeIfEnabled()
            XCTAssertEqual(provider.startCallCount, 1)
            guard case .active = manager.state else { return XCTFail("expected active state") }
            await manager.stop()
        }

        // Interrupting resumeIfEnabled() mid-refresh with stop() or pause() prevents observation from starting.
        for action in ["stop", "pause"] {
            self.defaults.set(true, forKey: "location.enabled")
            self.defaults.set(false, forKey: "location.paused")
            let provider = SuspendingLocationProvider(capability: .always(accuracy: .full))
            let manager = LocationManager(
                provider: provider,
                mobileSegmentEngine: self.mobileSegmentEngine,
                clock: self.clock,
                defaults: self.defaults
            )
            let entered = LocationAsyncGate()
            let release = LocationAsyncGate()
            provider.onRefresh = {
                entered.open()
                await release.wait()
                return .always(accuracy: .full)
            }

            let resumeTask = Task { await manager.resumeIfEnabled() }
            await entered.wait()
            if action == "stop" {
                await manager.stop()
            } else {
                await manager.pause()
            }
            release.open()
            await resumeTask.value
            XCTAssertEqual(provider.startCallCount, 0, "\(action) during resumeIfEnabled() must prevent observation start")
            XCTAssertEqual(manager.state, .idle)
        }

        // Concurrent start(tier:) arriving mid-resumeIfEnabled() supersedes resumeIfEnabled() cleanly (starts once, not twice).
        do {
            self.defaults.set(true, forKey: "location.enabled")
            self.defaults.set(false, forKey: "location.paused")
            let provider = SuspendingLocationProvider(capability: .always(accuracy: .full))
            let manager = LocationManager(
                provider: provider,
                mobileSegmentEngine: self.mobileSegmentEngine,
                clock: self.clock,
                defaults: self.defaults
            )
            let entered = LocationAsyncGate()
            let release = LocationAsyncGate()
            let callIndex = OSAllocatedUnfairLock<Int>(initialState: 0)
            provider.onRefresh = {
                let n = callIndex.withLock { c -> Int in c += 1; return c }
                if n == 1 {
                    entered.open()
                    await release.wait()
                }
                return .always(accuracy: .full)
            }

            let resumeTask = Task { await manager.resumeIfEnabled() }
            await entered.wait()
            // Concurrent start(tier: .light) bumps lifecycleGeneration and activates immediately.
            await manager.start(tier: .light)
            XCTAssertEqual(provider.startCallCount, 1)
            XCTAssertEqual(manager.tier, .light)
            release.open()
            await resumeTask.value
            XCTAssertEqual(provider.startCallCount, 1, "superseded resumeIfEnabled() must not double-start observation")
            await manager.stop()
        }

        // Interrupting start(tier:) mid-refresh with stop() or pause() prevents observation from starting.
        for action in ["stop", "pause"] {
            let provider = SuspendingLocationProvider(capability: .always(accuracy: .full))
            let manager = LocationManager(
                provider: provider,
                mobileSegmentEngine: self.mobileSegmentEngine,
                clock: self.clock,
                defaults: self.defaults
            )
            let entered = LocationAsyncGate()
            let release = LocationAsyncGate()
            provider.onRefresh = {
                entered.open()
                await release.wait()
                return .always(accuracy: .full)
            }

            let startTask = Task { await manager.start(tier: .balanced) }
            await entered.wait()
            if action == "stop" {
                await manager.stop()
            } else {
                await manager.pause()
            }
            release.open()
            await startTask.value
            XCTAssertEqual(provider.startCallCount, 0, "\(action) during start(tier:) must prevent observation start")
            XCTAssertEqual(manager.state, .idle)
        }
    }

    @MainActor
    private func makeManager() -> LocationManager {
        LocationManager(
            provider: self.provider,
            mobileSegmentEngine: self.mobileSegmentEngine,
            clock: self.clock,
            defaults: self.defaults
        )
    }

    @MainActor
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    private func waitForPendingSleeperCount(
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Returns as soon as the count matches; the bound only matters on a loaded host.
        for _ in 0..<100 {
            if self.clock.pendingSleeperCount == count { return }
            await self.yieldToMainActor()
        }
        XCTAssertEqual(self.clock.pendingSleeperCount, count, file: file, line: line)
    }

    @MainActor
    private func pendingLocationManifest() throws -> MobileSegmentManifest {
        let directory = try XCTUnwrap(try self.mobileSegmentDirectories(lifecycle: "pending").first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            MobileSegmentManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
    }

    @MainActor
    private func pendingLocationPayload() throws -> String {
        let directory = try XCTUnwrap(try self.mobileSegmentDirectories(lifecycle: "pending").first)
        return String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("location.jsonl")),
            as: UTF8.self
        )
    }

    @MainActor
    private func assertHeaderOnlyGapPayload(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let payload = try self.pendingLocationPayload()
        XCTAssertEqual(payload.split(separator: "\n").count, 1, file: file, line: line)
        XCTAssertTrue(payload.contains("solstone.location.segment"), file: file, line: line)
        XCTAssertTrue(payload.contains(#""gap":true"#), file: file, line: line)
        XCTAssertTrue(payload.contains(#""fix_count":0"#), file: file, line: line)
        XCTAssertFalse(payload.contains("solstone.location.fix"), file: file, line: line)
        XCTAssertFalse(payload.contains("solstone.location.visit"), file: file, line: line)
    }

    @MainActor
    private func emptyTombstoneCount() throws -> Int {
        let directory = self.tempDirectory
            .appendingPathComponent("MobileSegment", isDirectory: true)
            .appendingPathComponent("tombstones", isDirectory: true)
            .appendingPathComponent("empty", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .count
    }

    @MainActor
    private func mobileSegmentDirectories(lifecycle: String) throws -> [URL] {
        let directory = self.tempDirectory
            .appendingPathComponent("MobileSegment", isDirectory: true)
            .appendingPathComponent(lifecycle, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

private enum LocationManagerTestError: Error {
    case restartFailed
}

private nonisolated final class LocationAsyncGate: @unchecked Sendable {
    private struct State {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func open() {
        let waiters = self.state.withLock { s -> [CheckedContinuation<Void, Never>] in
            guard !s.opened else { return [] }
            s.opened = true
            let copy = s.waiters
            s.waiters.removeAll()
            return copy
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = self.state.withLock { s -> Bool in
                if s.opened { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

@MainActor
private final class SuspendingLocationProvider: LocationProviding {
    var onAuthorizationChanged: (@Sendable (LocationCapability) -> Void)?
    var onFix: (@Sendable (LocationFix) -> Void)?
    var onVisit: (@Sendable (LocationVisit) -> Void)?
    var onGap: (@Sendable (LocationGapReason) -> Void)?

    var capability: LocationCapability
    var startCallCount = 0
    var onRefresh: (@Sendable () async -> LocationCapability)?

    init(capability: LocationCapability) {
        self.capability = capability
    }

    func currentCapability() -> LocationCapability { self.capability }

    func refreshServicesEnabled() async -> LocationCapability {
        if let onRefresh = self.onRefresh {
            let cap = await onRefresh()
            self.capability = cap
            return cap
        }
        return self.capability
    }

    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startObservation(modes: Set<LocationObservationMode>) async throws { self.startCallCount += 1 }
    func stopObservation() async {}
    func beginBackgroundSustain() async {}
    func endBackgroundSustain() async {}
}
