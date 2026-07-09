// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
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
        XCTAssertEqual(manager.sourceState, .off)
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

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(manager.sourceAttention?.actionHint, LocationVocabulary.openSettingsAction)
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
        await self.yieldToMainActor()

        self.provider.emitGap()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()

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

        await manager.stopForDelete()
        XCTAssertEqual(self.defaults.bool(forKey: "location.enabled"), false)
        XCTAssertEqual(self.defaults.bool(forKey: "location.paused"), false)
        XCTAssertEqual(manager.sourceState, .off)
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

    @MainActor
    func testResumeIfNeverEnabledStaysOffAndEndsOrphans() async {
        self.provider.capability = .always(accuracy: .full)
        let manager = self.makeManager()

        await manager.resumeIfEnabled()

        XCTAssertEqual(manager.sourceState, .off)
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
        for _ in 0..<20 {
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
