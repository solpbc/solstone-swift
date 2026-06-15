// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LocationEnrollmentCoordinatorTests: XCTestCase {
    @MainActor private lazy var provider = MockLocationProvider()
    @MainActor private lazy var clock = MockObserverClock()
    @MainActor private lazy var liveActivity = MockLocationLiveActivity()
    private lazy var uploader = RecordingLocationUploader()
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "LocationEnrollmentCoordinatorTests.\(UUID().uuidString)"
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
    func testInitDoesNotRequestAuthorizationOrEmitEvents() {
        let recorder = LocationEnrollmentEventRecorder()
        _ = self.makeCoordinator(recorder: recorder)

        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
        XCTAssertEqual(recorder.events(), [])
    }

    @MainActor
    func testDefaultTierIsBalanced() {
        let coordinator = self.makeCoordinator()

        XCTAssertEqual(coordinator.selectedTier, .balanced)
        XCTAssertNotEqual(coordinator.selectedTier, .full)
    }

    @MainActor
    func testSelectingTierEmitsTierSelected() {
        let recorder = LocationEnrollmentEventRecorder()
        let coordinator = self.makeCoordinator(recorder: recorder)

        coordinator.selectTier(.light)

        XCTAssertEqual(recorder.events(), [.tierSelected(.light)])
    }

    @MainActor
    func testLightConfirmStartsImmediatelyWithoutPrimer() async {
        let recorder = LocationEnrollmentEventRecorder()
        let coordinator = self.makeCoordinator(recorder: recorder)

        coordinator.selectTier(.light)
        await coordinator.confirm()

        XCTAssertEqual(recorder.events(), [
            .tierSelected(.light),
            .startRequested(.light)
        ])
        XCTAssertFalse(coordinator.showingPrimer)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
    }

    @MainActor
    func testBalancedConfirmOneTapsWhenAuthorizationAlreadySufficient() async {
        self.provider.capability = .always(accuracy: .reduced)
        let recorder = LocationEnrollmentEventRecorder()
        let manager = self.makeManager()
        let coordinator = self.makeCoordinator(manager: manager, recorder: recorder)

        await coordinator.confirm()

        XCTAssertEqual(recorder.events(), [.startRequested(.balanced)])
        XCTAssertFalse(coordinator.showingPrimer)
        XCTAssertEqual(manager.sourceState, .active)
        XCTAssertEqual(self.provider.startCallCount, 1)
        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
    }

    @MainActor
    func testLightConfirmOneTapsWhenAuthorizationAlreadySufficient() async {
        self.provider.capability = .whenInUse(accuracy: .full)
        let recorder = LocationEnrollmentEventRecorder()
        let manager = self.makeManager()
        let coordinator = self.makeCoordinator(manager: manager, recorder: recorder)

        coordinator.selectTier(.light)
        await coordinator.confirm()

        XCTAssertEqual(recorder.events(), [
            .tierSelected(.light),
            .startRequested(.light)
        ])
        XCTAssertFalse(coordinator.showingPrimer)
        XCTAssertEqual(manager.sourceState, .active)
        XCTAssertEqual(self.provider.startCallCount, 1)
        XCTAssertTrue(self.liveActivity.startCalls.isEmpty)
    }

    @MainActor
    func testRepeatedBalancedConfirmOnlyShowsPrimerOnce() async {
        let recorder = LocationEnrollmentEventRecorder()
        let coordinator = self.makeCoordinator(recorder: recorder)

        await coordinator.confirm()
        await coordinator.confirm()

        XCTAssertEqual(recorder.events(), [.primerShown])
        XCTAssertTrue(coordinator.showingPrimer)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
    }

    @MainActor
    func testDismissingAlwaysPrimerDoesNotStartLocation() async {
        let recorder = LocationEnrollmentEventRecorder()
        let manager = self.makeManager()
        let coordinator = self.makeCoordinator(manager: manager, recorder: recorder)

        await coordinator.confirm()
        XCTAssertTrue(coordinator.showingPrimer)
        coordinator.showingPrimer = false

        XCTAssertEqual(recorder.events(), [.primerShown])
        XCTAssertEqual(manager.sourceState, .off)
        XCTAssertEqual(self.provider.startCallCount, 0)
        XCTAssertTrue(self.liveActivity.startCalls.isEmpty)
    }

    @MainActor
    func testBalancedConfirmShowsPrimerAndDefersProviderUntilAcknowledged() async {
        let recorder = LocationEnrollmentEventRecorder()
        let coordinator = self.makeCoordinator(recorder: recorder)

        await coordinator.confirm()

        XCTAssertEqual(recorder.events(), [.primerShown])
        XCTAssertTrue(coordinator.showingPrimer)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)

        await coordinator.acknowledgePrimer()

        XCTAssertEqual(recorder.events(), [
            .primerShown,
            .startRequested(.balanced)
        ])
        XCTAssertFalse(coordinator.showingPrimer)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)
    }

    @MainActor
    func testFullConfirmShowsPrimerAndDefersProviderUntilAcknowledged() async {
        let recorder = LocationEnrollmentEventRecorder()
        let coordinator = self.makeCoordinator(recorder: recorder)

        coordinator.selectTier(.full)
        await coordinator.confirm()

        XCTAssertEqual(recorder.events(), [
            .tierSelected(.full),
            .primerShown
        ])
        XCTAssertTrue(coordinator.showingPrimer)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 0)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)

        await coordinator.acknowledgePrimer()

        XCTAssertEqual(recorder.events(), [
            .tierSelected(.full),
            .primerShown,
            .startRequested(.full)
        ])
        XCTAssertFalse(coordinator.showingPrimer)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 0)
    }

    @MainActor
    func testStateHandOffRendersActiveAfterAlwaysGrant() async {
        let manager = self.makeManager()
        let coordinator = self.makeCoordinator(manager: manager)

        await coordinator.confirm()
        await coordinator.acknowledgePrimer()
        XCTAssertEqual(manager.sourceState, .enrolling)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sourceState, .enrolling)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)

        self.provider.emitAuthorization(.always(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    func testStateHandOffRendersNeedsAttentionAfterLesserGrantForBalanced() async {
        let manager = self.makeManager()
        let coordinator = self.makeCoordinator(manager: manager)

        await coordinator.confirm()
        await coordinator.acknowledgePrimer()
        XCTAssertEqual(manager.sourceState, .enrolling)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()
        XCTAssertEqual(manager.sourceState, .enrolling)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)

        self.provider.emitAuthorization(.whenInUse(accuracy: .reduced))
        await self.yieldToMainActor()

        XCTAssertEqual(manager.sourceState, .needsAttention)
        XCTAssertEqual(self.provider.requestWhenInUseCallCount, 1)
        XCTAssertEqual(self.provider.requestAlwaysCallCount, 1)
    }

    @MainActor
    private func makeCoordinator(
        manager: LocationManager? = nil,
        recorder: LocationEnrollmentEventRecorder = LocationEnrollmentEventRecorder()
    ) -> LocationEnrollmentCoordinator {
        LocationEnrollmentCoordinator(manager: manager ?? self.makeManager()) { event in
            recorder.append(event)
        }
    }

    @MainActor
    private func makeManager() -> LocationManager {
        LocationManager(
            provider: self.provider,
            uploader: self.uploader,
            clock: self.clock,
            defaults: self.defaults,
            liveActivity: self.liveActivity
        )
    }

    @MainActor
    private func yieldToMainActor() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private final class LocationEnrollmentEventRecorder {
    private var storage: [LocationEnrollmentEvent] = []

    func append(_ event: LocationEnrollmentEvent) {
        self.storage.append(event)
    }

    func events() -> [LocationEnrollmentEvent] {
        self.storage
    }
}
