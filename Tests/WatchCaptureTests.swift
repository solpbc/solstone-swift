// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import os
import XCTest

@MainActor
final class WatchCaptureTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testRolloverKeepsAudioSessionActiveUntilOwnerStop() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })

        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        XCTAssertFalse(harness.audioSession.setActiveCalls.contains(false))

        harness.engine.stop(); await harness.engine.settled()

        XCTAssertEqual(harness.audioSession.setActiveCalls, [true, false])
    }

    func testClockRolloverFinalizesCurrentSegmentAndOpensNext() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.clock.advance(by: 300)
        await self.drain(until: {
            guard let manifests = try? harness.storage.scanManifests().map(\.manifest) else {
                return false
            }
            return harness.recorder.startURLs.count == 2
                && manifests.contains { $0.state == .queued }
                && manifests.contains { $0.state == .persisted }
        })

        let manifests = try harness.storage.scanManifests().map(\.manifest)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        XCTAssertTrue(manifests.contains { $0.state == .queued })
        XCTAssertTrue(manifests.contains { $0.state == .persisted })
    }

    func testStatusHeartbeatPublishesIncreasingSequenceWhileStationary() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } && self.pendingSleeperCount(in: harness.clock) >= 2 })
        let initial = try XCTUnwrap(statuses.last)
        harness.clock.advance(by: 15)
        await self.drain(until: { statuses.count >= 2 && statuses.last?.seq == initial.seq + 1 })

        let heartbeat = try XCTUnwrap(statuses.last)
        XCTAssertEqual(initial.phase, .observing)
        XCTAssertEqual(heartbeat.phase, .observing)
        XCTAssertEqual(heartbeat.seq, initial.seq + 1)
        XCTAssertEqual(heartbeat.sessionID, initial.sessionID)
        XCTAssertEqual(heartbeat.startedAt, initial.startedAt)
    }

    func testRepublishCurrentStatusEmitsCurrentPhaseImmediately() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } && self.pendingSleeperCount(in: harness.clock) >= 2 })
        let initial = try XCTUnwrap(statuses.last)
        statuses.removeAll()
        harness.clock.advance(by: 1)
        let republishAt = harness.clock.now()

        harness.engine.republishCurrentStatus()

        let republished = try XCTUnwrap(statuses.last)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(republished.phase, .observing)
        XCTAssertEqual(republished.asOf, republishAt)
        XCTAssertEqual(republished.seq, initial.seq + 1)
        XCTAssertEqual(republished.sessionID, initial.sessionID)
        XCTAssertEqual(republished.startedAt, initial.startedAt)
    }

    func testRefreshRelayCountsFromDiskPublishesOnceWhenQueuedAndTransferringCountsChange() throws {
        let harness = try self.makeHarness()
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt,
            state: .queued,
            sensors: [.audio]
        )
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt.addingTimeInterval(60),
            state: .transferring,
            sensors: [.audio]
        )

        harness.engine.refreshRelayCountsFromDisk()

        let published = try XCTUnwrap(statuses.last)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(published.phase, .idle)
        XCTAssertEqual(published.queuedCount, 1)
        XCTAssertEqual(published.transferringCount, 1)

        statuses.removeAll()
        harness.engine.refreshRelayCountsFromDisk()

        XCTAssertTrue(statuses.isEmpty)
    }

    func testDeliveredSegmentsCountAsConfirmingAndTerminalStatesAsHandedOff() throws {
        let harness = try self.makeHarness()
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt,
            state: .delivered,
            sensors: [.audio]
        )
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt.addingTimeInterval(60),
            state: .acked,
            sensors: [.audio]
        )
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt.addingTimeInterval(120),
            state: .safeToDelete,
            sensors: [.audio]
        )

        harness.engine.refreshRelayCountsFromDisk()

        XCTAssertEqual(harness.engine.ownerPresentation.confirmingCount, 1)
        XCTAssertEqual(harness.engine.ownerPresentation.handedOffCount, 2)
    }

    func testStartStopPublishObservingStoppingAndIdle() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        harness.engine.stop(); await harness.engine.settled()

        XCTAssertEqual(statuses.first?.phase, .observing)
        XCTAssertEqual(statuses.suffix(2).map(\.phase), [.stopping, .idle])
        XCTAssertNotNil(statuses.last?.sessionID)
        XCTAssertNotNil(statuses.last?.startedAt)
        XCTAssertEqual(statuses.last?.audioTerminalReason, .ownerStopped)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .ownerStopped)
    }

    func testRolloverPublishesObservingForContinuedSession() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        statuses.removeAll()
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 && statuses.contains { $0.phase == .observing } })

        XCTAssertEqual(statuses.last?.phase, .observing)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testInterruptionBeganTerminatesWithDetectedReason() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        statuses.removeAll()
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        XCTAssertEqual(statuses.last?.phase, .idle)
        XCTAssertEqual(statuses.last?.audioTerminalReason, .audioInterrupted)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .detectedStoppedItself)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testReconcileOnLaunchPublishesInitialBacklogOnce() async throws {
        let harness = try self.makeHarness()
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt,
            state: .queued,
            sensors: [.audio]
        )
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt.addingTimeInterval(60),
            state: .transferring,
            sensors: [.audio]
        )

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let published = try XCTUnwrap(statuses.last)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(published.phase, .idle)
        XCTAssertEqual(published.queuedCount, 1)
        XCTAssertEqual(published.transferringCount, 1)
    }

    func testReconcileOnLaunchPublishesInitialBacklogFromFinalizedManifests() async throws {
        let harness = try self.makeHarness()
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt,
            state: .finalized,
            sensors: [.audio]
        )
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt.addingTimeInterval(60),
            state: .finalized,
            sensors: [.audio]
        )
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt.addingTimeInterval(120),
            state: .transferring,
            sensors: [.audio]
        )

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let published = try XCTUnwrap(statuses.last)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(published.phase, .idle)
        XCTAssertEqual(published.queuedCount, 2)
        XCTAssertEqual(published.transferringCount, 1)
    }

    func testReconcileOnLaunchEmptyDiskPublishesOneBaseline() async throws {
        let harness = try self.makeHarness()
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let published = try XCTUnwrap(statuses.last)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(published.phase, .idle)
        XCTAssertEqual(published.queuedCount, 0)
        XCTAssertEqual(published.transferringCount, 0)
    }

    func testManifestScanFailureProducesRelayAdvisoryNotCaptureAttention() async throws {
        let harness = try self.makeHarness(fileWriter: FailingWatchFileWriter(failAppend: false, failContents: true))
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { status in
            statuses.append(status)
        }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let published = try XCTUnwrap(statuses.last)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(published.phase, .idle)
        XCTAssertEqual(published.queuedCount, 0)
        XCTAssertEqual(published.transferringCount, 0)
        XCTAssertEqual(harness.engine.ownerPresentation.status, .off)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .manifestScanFailed)
    }

    func testStartRefusesWhenMicrophoneDeniedWithoutWritingSegmentAndPresentationRoutesToSettings() async throws {
        let harness = try self.makeHarness(audioPermission: false, locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()

        XCTAssertTrue(try harness.storage.scanManifests().isEmpty)
        XCTAssertEqual(harness.engine.ownerPresentation.queuedCount, 0)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
        XCTAssertEqual(harness.engine.ownerPresentation.settingsRoute, .microphone)
        XCTAssertEqual(harness.engine.ownerPresentation.startRefusalReason, .microphonePermissionDenied)
        let stateWord = watchFaceModel(for: harness.engine.ownerPresentation, isReachable: true).stateWord
        XCTAssertTrue(stateWord.contains("microphone"))
    }

    func testDeniedMicrophoneDoesNotRequestPermissionPrompt() async throws {
        let harness = try self.makeHarness(audioPermission: false, locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()

        XCTAssertEqual(harness.recorder.requestPermissionCallCount, 0)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
    }

    func testMicrophonePermissionAndAudioArmFailuresHaveDistinctOutcomes() async throws {
        let notDetermined = try self.makeHarness(
            microphonePermission: .notDetermined,
            locationAuthorization: .authorized
        )
        notDetermined.recorder.requestPermissionResult = .denied
        notDetermined.engine.start(); await notDetermined.engine.settled()

        let denied = try self.makeHarness(audioPermission: false, locationAuthorization: .authorized)
        denied.engine.start(); await denied.engine.settled()

        let armFailure = try self.makeHarness(locationAuthorization: .authorized)
        armFailure.recorder.startError = ObserverError.unavailable(reason: "audio unavailable")
        armFailure.engine.start(); await armFailure.engine.settled()

        XCTAssertEqual(notDetermined.engine.ownerPresentation.startRefusalReason, .microphonePermissionNotDetermined)
        XCTAssertEqual(denied.engine.ownerPresentation.startRefusalReason, .microphonePermissionDenied)
        XCTAssertEqual(armFailure.engine.ownerPresentation.startRefusalReason, .audioArmFailed)
        XCTAssertFalse(armFailure.engine.ownerPresentation.isSessionRunning)
        XCTAssertTrue(try armFailure.storage.scanManifests().isEmpty)
    }

    func testAuthorizedWristNoticeSubmitsWithoutRequestingAuthorization() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        XCTAssertEqual(harness.notificationScheduler.calls.filter { $0 == .requestAuthorization }.count, 0)
        let notice = try XCTUnwrap(harness.notificationScheduler.submittedRequests.first {
            $0.identifier == WatchNoticeIdentifiers.notice
        })
        XCTAssertEqual(notice.title, WatchNoticeCopy.audioStoppedItself.title)
        XCTAssertEqual(notice.body, WatchNoticeCopy.audioStoppedItself.body)
    }

    func testUndeterminedWristAuthorizationRequestsOnlyFromOwnerStart() async throws {
        let started = try self.makeHarness(
            locationAuthorization: .denied,
            notificationAuthorizationStatus: .notDetermined
        )
        started.notificationScheduler.requestAuthorizationResult = .authorized

        started.engine.start(); await started.engine.settled()

        XCTAssertEqual(started.notificationScheduler.calls.filter { $0 == .requestAuthorization }.count, 1)

        let detected = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        detected.engine.onPublishStatus = { statuses.append($0) }
        detected.engine.start(); await detected.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        detected.notificationScheduler.calls.removeAll()
        detected.notificationScheduler.authorizationStatusValue = .notDetermined

        detected.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        XCTAssertEqual(detected.notificationScheduler.calls.filter { $0 == .requestAuthorization }.count, 0)

        let reconciled = try self.makeHarness(notificationAuthorizationStatus: .notDetermined)
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try reconciled.storage.writeSessionRecord(record)

        reconciled.engine.reconcileOnLaunch(); await reconciled.engine.settled()

        XCTAssertEqual(reconciled.notificationScheduler.calls.filter { $0 == .requestAuthorization }.count, 0)
    }

    func testDeniedWristAuthorizationDoesNotSubmitNoticeAndSurfacesAlertsOff() async throws {
        let harness = try self.makeHarness(
            locationAuthorization: .denied,
            notificationAuthorizationStatus: .denied
        )
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        XCTAssertEqual(harness.notificationScheduler.calls.filter { $0 == .requestAuthorization }.count, 0)
        XCTAssertTrue(harness.notificationScheduler.submittedRequests.filter {
            $0.identifier == WatchNoticeIdentifiers.notice
        }.isEmpty)
        XCTAssertEqual(harness.engine.ownerPresentation.wristAlertAssurance, .alertsOff)
    }

    func testAlertSettingControlsWristAssuranceSurface() async throws {
        XCTAssertEqual(
            watchWristAlertAssurance(authorization: .authorized, alertSetting: .enabled),
            .willTap
        )
        XCTAssertEqual(
            watchWristAlertAssurance(authorization: .authorized, alertSetting: .disabled),
            .alertsOff
        )

        let enabled = try self.makeHarness(locationAuthorization: .denied)
        enabled.engine.start(); await enabled.engine.settled()
        XCTAssertEqual(enabled.engine.ownerPresentation.wristAlertAssurance, .willTap)

        let disabled = try self.makeHarness(
            locationAuthorization: .denied,
            notificationAlertSetting: .disabled
        )
        disabled.engine.start(); await disabled.engine.settled()
        XCTAssertEqual(disabled.engine.ownerPresentation.wristAlertAssurance, .alertsOff)
    }

    func testCleanOwnerStopRemovesLeaseWithoutSubmittingNotice() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        harness.engine.start(); await harness.engine.settled()
        let callsBeforeStop = harness.notificationScheduler.calls
        harness.engine.stop(); await harness.engine.settled()

        XCTAssertTrue(callsBeforeStop.allSatisfy { call in
            call != .removePending(identifier: WatchNoticeIdentifiers.lease)
        })
        XCTAssertTrue(harness.notificationScheduler.submittedRequests.filter {
            $0.identifier == WatchNoticeIdentifiers.notice
        }.isEmpty)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
    }

    func testStopRemovesLeaseBeforeSubmittingDetectedNotice() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        harness.notificationScheduler.calls.removeAll()
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        let removeIndex = try XCTUnwrap(harness.notificationScheduler.calls.firstIndex(
            of: .removePending(identifier: WatchNoticeIdentifiers.lease)
        ))
        let addIndex = try XCTUnwrap(harness.notificationScheduler.calls.firstIndex { call in
            guard case let .add(identifier, _, _, _) = call else { return false }
            return identifier == WatchNoticeIdentifiers.notice
        })
        XCTAssertLessThan(removeIndex, addIndex)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
    }

    func testNewSessionReplacesPendingLeaseWithNewDeadline() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        let oldDeadline = Date(timeIntervalSince1970: 1_713_624_123)
        harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease] = .init(
            identifier: WatchNoticeIdentifiers.lease,
            title: WatchNoticeCopy.audioCouldNotBeConfirmed.title,
            body: WatchNoticeCopy.audioCouldNotBeConfirmed.body,
            triggerDate: oldDeadline
        )

        harness.engine.start(); await harness.engine.settled()

        let lease = try XCTUnwrap(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertEqual(harness.notificationScheduler.pendingRequests.filter {
            $0.key == WatchNoticeIdentifiers.lease
        }.count, 1)
        XCTAssertEqual(lease.title, WatchNoticeCopy.audioCouldNotBeConfirmed.title)
        XCTAssertEqual(lease.body, WatchNoticeCopy.audioCouldNotBeConfirmed.body)
        XCTAssertEqual(
            lease.triggerDate,
            Date(timeIntervalSince1970: 1_713_624_000 + WatchCaptureTiming.segmentDurationSeconds * 2)
        )
    }

    func testNewSessionRemovesPriorLeaseWhenAlertsAreDisabled() async throws {
        let harness = try self.makeHarness(
            locationAuthorization: .denied,
            notificationAlertSetting: .disabled
        )
        harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease] = .init(
            identifier: WatchNoticeIdentifiers.lease,
            title: WatchNoticeCopy.audioCouldNotBeConfirmed.title,
            body: WatchNoticeCopy.audioCouldNotBeConfirmed.body,
            triggerDate: Date(timeIntervalSince1970: 1_713_624_123)
        )

        harness.engine.start(); await harness.engine.settled()

        XCTAssertNotNil(harness.notificationScheduler.calls.firstIndex(
            of: .removePending(identifier: WatchNoticeIdentifiers.lease)
        ))
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.lease).count, 0)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
    }

    func testOwnerStopWithFailingTerminalWriteStillRemovesLease() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)

        harness.engine.start(); await harness.engine.settled()
        fileWriter.failAtomicReplace = true
        harness.engine.stop(); await harness.engine.settled()

        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
    }

    func testStartStopsWhenLifetimeCounterIsUnreadable() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        let counterURL = harness.storage.rootURL.appendingPathComponent(WatchCaptureSessionHistoryStore.counterFileName)
        try harness.storage.fileWriter.atomicReplaceFile(at: counterURL, with: Data("bad counter".utf8))

        harness.engine.start(); await harness.engine.settled()

        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        XCTAssertEqual(history.read(asOf: harness.clock.now()), .available([]))
    }

    func testRouteChangeWithoutSuitableInputTerminatesWithDetectedReason() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        statuses.removeAll()
        harness.audioSession.hasSuitableInput = false
        harness.notificationCenter.post(name: AVAudioSession.routeChangeNotification, object: nil)
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioRouteUnavailable } })

        XCTAssertEqual(statuses.last?.audioTerminalReason, .audioRouteUnavailable)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .detectedStoppedItself)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testMediaServicesLostAndResetTerminateWithDistinctReasons() async throws {
        let lost = try self.makeHarness(locationAuthorization: .denied)
        var lostStatuses: [WatchStatusContext] = []
        lost.engine.onPublishStatus = { lostStatuses.append($0) }
        lost.engine.start(); await lost.engine.settled()
        await self.drain(until: { lostStatuses.contains { $0.phase == .observing } })
        lostStatuses.removeAll()
        lost.notificationCenter.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
        await self.drain(until: { lostStatuses.contains { $0.audioTerminalReason == .audioMediaServicesLost } })

        let reset = try self.makeHarness(locationAuthorization: .denied)
        var resetStatuses: [WatchStatusContext] = []
        reset.engine.onPublishStatus = { resetStatuses.append($0) }
        reset.engine.start(); await reset.engine.settled()
        await self.drain(until: { resetStatuses.contains { $0.phase == .observing } })
        resetStatuses.removeAll()
        reset.notificationCenter.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await self.drain(until: { resetStatuses.contains { $0.audioTerminalReason == .audioMediaServicesReset } })

        XCTAssertEqual(lostStatuses.last?.audioTerminalReason, .audioMediaServicesLost)
        XCTAssertEqual(resetStatuses.last?.audioTerminalReason, .audioMediaServicesReset)
    }

    func testDelayedAudioSessionNotificationsRemainBoundToFormerSession() async throws {
        for notification in self.audioSessionNotificationCases {
            let handoffs = AudioSessionNotificationHandoffProbe()
            let harness = try self.makeHarness(
                locationAuthorization: .denied,
                audioSessionNotificationHandoff: { operation in
                    handoffs.capture(operation)
                }
            )

            harness.engine.start()
            await self.settleCaptureEngine(harness.engine)
            let formerSource = try XCTUnwrap(harness.recorder.startSources.last)
            harness.notificationCenter.post(
                name: notification.name,
                object: nil,
                userInfo: notification.userInfo
            )
            XCTAssertEqual(handoffs.pendingCount, 1)

            harness.engine.stop()
            await self.settleCaptureEngine(harness.engine)
            harness.clock.advance(by: 1)
            harness.engine.start()
            await self.settleCaptureEngine(harness.engine)
            let currentSource = try XCTUnwrap(harness.recorder.startSources.last)
            XCTAssertNotEqual(formerSource.sessionID, currentSource.sessionID)

            let recordBefore = try XCTUnwrap(try harness.storage.readSessionRecord())
            XCTAssertEqual(recordBefore.sessionID, currentSource.sessionID)
            XCTAssertEqual(recordBefore.state, .active)
            let storageBefore = try self.storageInventory(in: harness.storage)
            let presentationBefore = harness.engine.ownerPresentation
            let recorderStopsBefore = harness.recorder.stopCallCount
            let recorderIsRecordingBefore = harness.recorder.isRecording
            let audioSessionCallsBefore = harness.audioSession.setActiveCalls
            let locationStartsBefore = harness.locationProvider.startCallCount
            let locationStopsBefore = harness.locationProvider.stopCallCount
            let schedulerCallsBefore = harness.notificationScheduler.calls
            let pendingRequestsBefore = harness.notificationScheduler.pendingRequests
            let publications = self.capturePublications(in: harness)

            if notification.makesInputUnsuitable {
                harness.audioSession.hasSuitableInput = false
            }
            handoffs.releaseAll()
            XCTAssertEqual(handoffs.pendingCount, 0)
            await self.settleCaptureEngine(harness.engine)

            XCTAssertEqual(try harness.storage.readSessionRecord(), recordBefore)
            XCTAssertEqual(try self.storageInventory(in: harness.storage), storageBefore)
            XCTAssertEqual(harness.engine.ownerPresentation, presentationBefore)
            XCTAssertEqual(harness.recorder.stopCallCount, recorderStopsBefore)
            XCTAssertEqual(harness.recorder.isRecording, recorderIsRecordingBefore)
            XCTAssertEqual(harness.audioSession.setActiveCalls, audioSessionCallsBefore)
            XCTAssertEqual(harness.locationProvider.startCallCount, locationStartsBefore)
            XCTAssertEqual(harness.locationProvider.stopCallCount, locationStopsBefore)
            XCTAssertEqual(harness.notificationScheduler.calls, schedulerCallsBefore)
            XCTAssertEqual(harness.notificationScheduler.pendingRequests, pendingRequestsBefore)
            XCTAssertTrue(publications.statuses.isEmpty)
            XCTAssertTrue(publications.presentations.isEmpty)
        }
    }

    func testBoundAudioSessionNotificationsTerminateNewCurrentSessionAfterRestart() async throws {
        for notification in self.audioSessionNotificationCases {
            let handoffs = AudioSessionNotificationHandoffProbe()
            let harness = try self.makeHarness(
                locationAuthorization: .denied,
                audioSessionNotificationHandoff: { operation in
                    handoffs.capture(operation)
                }
            )

            harness.engine.start()
            await self.settleCaptureEngine(harness.engine)
            let formerSource = try XCTUnwrap(harness.recorder.startSources.last)
            harness.engine.stop()
            await self.settleCaptureEngine(harness.engine)
            harness.clock.advance(by: 1)
            harness.engine.start()
            await self.settleCaptureEngine(harness.engine)
            let currentSource = try XCTUnwrap(harness.recorder.startSources.last)
            XCTAssertNotEqual(formerSource.sessionID, currentSource.sessionID)

            let publications = self.capturePublications(in: harness)
            let recorderStopsBefore = harness.recorder.stopCallCount
            let noticesBefore = harness.notificationScheduler.addCalls(
                identifier: WatchNoticeIdentifiers.notice
            ).count
            if notification.makesInputUnsuitable {
                harness.audioSession.hasSuitableInput = false
            }
            harness.notificationCenter.post(
                name: notification.name,
                object: nil,
                userInfo: notification.userInfo
            )
            XCTAssertEqual(handoffs.pendingCount, 1)
            handoffs.releaseAll()
            XCTAssertEqual(handoffs.pendingCount, 0)
            await self.settleCaptureEngine(harness.engine)

            let record = try XCTUnwrap(try harness.storage.readSessionRecord())
            XCTAssertEqual(record.sessionID, currentSource.sessionID)
            XCTAssertEqual(record.state, .terminal)
            XCTAssertEqual(record.terminalReason, notification.reason)
            XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
            XCTAssertEqual(harness.engine.ownerPresentation.terminalReason, notification.reason)
            XCTAssertEqual(harness.engine.ownerPresentation.terminalDisposition, .detectedStoppedItself)
            XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
            XCTAssertEqual(harness.recorder.stopCallCount, recorderStopsBefore + 1)
            XCTAssertEqual(
                harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count,
                noticesBefore + 1
            )
            XCTAssertEqual(
                publications.statuses.filter { $0.audioTerminalReason == notification.reason }.count,
                1
            )
        }
    }

    func testRecorderDelegateFailuresTerminateWithDistinctReasons() async throws {
        let finished = try self.makeHarness(locationAuthorization: .denied)
        var finishedStatuses: [WatchStatusContext] = []
        finished.engine.onPublishStatus = { finishedStatuses.append($0) }
        finished.engine.start(); await finished.engine.settled()
        await self.drain(until: { finishedStatuses.contains { $0.phase == .observing } })
        finishedStatuses.removeAll()
        let finishedSource = try XCTUnwrap(finished.recorder.startSources.last)
        finished.recorder.eventSink?.audioRecorderDidFinish(successfully: false, source: finishedSource)
        await self.drain(until: { finishedStatuses.contains { $0.audioTerminalReason == .audioFinishUnsuccessful } })

        let encoded = try self.makeHarness(locationAuthorization: .denied)
        var encodedStatuses: [WatchStatusContext] = []
        encoded.engine.onPublishStatus = { encodedStatuses.append($0) }
        encoded.engine.start(); await encoded.engine.settled()
        await self.drain(until: { encodedStatuses.contains { $0.phase == .observing } })
        encodedStatuses.removeAll()
        let encodedSource = try XCTUnwrap(encoded.recorder.startSources.last)
        encoded.recorder.eventSink?.audioRecorderEncodeError(nil, source: encodedSource)
        await self.drain(until: { encodedStatuses.contains { $0.audioTerminalReason == .audioEncodeError } })

        XCTAssertEqual(finishedStatuses.last?.audioTerminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(encodedStatuses.last?.audioTerminalReason, .audioEncodeError)
    }

    func testLivenessPollFailuresTerminateWithDistinctReasons() async throws {
        let stopped = try self.makeHarness(locationAuthorization: .denied)
        var stoppedStatuses: [WatchStatusContext] = []
        stopped.engine.onPublishStatus = { stoppedStatuses.append($0) }
        stopped.engine.start(); await stopped.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: stopped.clock) >= 2 })
        stopped.recorder.isRecording = false
        stopped.clock.advance(by: 15)
        await self.drain(until: { stoppedStatuses.contains { $0.audioTerminalReason == .audioRecorderStopped } })

        let stalled = try self.makeHarness(locationAuthorization: .denied)
        var stalledStatuses: [WatchStatusContext] = []
        stalled.engine.onPublishStatus = { stalledStatuses.append($0) }
        stalled.engine.start(); await stalled.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: stalled.clock) >= 2 })
        stalled.recorder.currentTime = 5
        stalled.clock.advance(by: 15)
        await self.drain(until: { stalledStatuses.contains { $0.seq >= 2 } })
        stalledStatuses.removeAll()
        stalled.clock.advance(by: 15)
        await self.drain(until: { stalledStatuses.contains { $0.audioTerminalReason == .audioClockStalled } })

        XCTAssertEqual(stoppedStatuses.last?.audioTerminalReason, .audioRecorderStopped)
        XCTAssertEqual(stalledStatuses.last?.audioTerminalReason, .audioClockStalled)
        XCTAssertEqual(stopped.notificationScheduler.submittedRequests.filter { $0.identifier == WatchNoticeIdentifiers.notice }.count, 1)
        XCTAssertEqual(stalled.notificationScheduler.submittedRequests.filter { $0.identifier == WatchNoticeIdentifiers.notice }.count, 1)
    }

    func testZeroClockTerminatesOnlyAfterBoundedRepeatedObservations() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        statuses.removeAll()
        harness.notificationScheduler.calls.removeAll()

        harness.clock.advance(by: 15)
        await self.drain(until: { statuses.count >= 1 })
        harness.clock.advance(by: 15)
        await self.drain(until: { statuses.count >= 2 })

        XCTAssertFalse(statuses.contains { $0.audioTerminalReason == .audioClockStalled })
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.lease).count, 0)

        harness.clock.advance(by: 15)
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioClockStalled } })

        XCTAssertEqual(statuses.last?.audioTerminalReason, .audioClockStalled)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else { return XCTFail("history unreadable") }
        XCTAssertGreaterThan(try XCTUnwrap(entries.first?.zeroAudioCurrentTimeObservationCount), 0)
    }

    func testTerminalHistorySurvivesRelaunchAndReconcileWritesProcessDeathEntry() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.engine.stop(); await harness.engine.settled()
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        guard case let .available(stopped) = history.read(asOf: harness.clock.now()) else { return XCTFail("history unreadable") }
        XCTAssertEqual(stopped.count, 1)
        XCTAssertTrue(try XCTUnwrap(stopped.first).isComplete)

        let active = WatchCaptureSessionRecord(
            sessionID: "process-death", startedAt: harness.clock.now(), state: .active,
            terminalReason: nil, terminalDisposition: nil, terminalAt: nil, noticeOwed: false
        )
        try harness.storage.writeSessionRecord(active)
        let residueDirectory = try self.writeManifest(
            storage: harness.storage,
            startedAt: harness.clock.now(),
            state: .captured,
            sensors: [.audio]
        )
        try Data("aac".utf8).write(to: harness.storage.audioURL(directory: residueDirectory))
        let relaunchProbe = MockWatchAudioProbe()
        relaunchProbe.durations[harness.storage.audioURL(directory: residueDirectory).path] = 12.3
        let relaunch = WatchCaptureEngine(
            audioRecorder: MockWatchAudioRecorder(microphonePermission: .granted), audioSession: MockWatchAudioSession(),
            locationProvider: MockWatchLocationProvider(authorizationStatus: .denied), storage: harness.storage,
            clock: harness.clock, audioProbe: relaunchProbe,
            notificationScheduler: MockWatchNotificationScheduler(authorizationStatus: .authorized, alertSetting: .enabled),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider(), notificationCenter: NotificationCenter()
        )
        relaunch.reconcileOnLaunch(); await relaunch.settled()
        guard case let .available(reconciled) = history.read(asOf: harness.clock.now()) else { return XCTFail("history unreadable") }
        let entry = try XCTUnwrap(reconciled.first { $0.sessionID == "process-death" })
        XCTAssertEqual(entry.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(entry.terminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(entry.segmentsProduced, 1)
    }

    func testDeniedTerminalHistoryRecordsNoticeAttemptFacts() async throws {
        let harness = try self.makeHarness(
            locationAuthorization: .denied, notificationAuthorizationStatus: .denied, notificationAlertSetting: .disabled
        )
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.notificationCenter.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await self.drain(until: { harness.engine.ownerPresentation.terminalReason == .audioInterrupted })
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else { return XCTFail("history unreadable") }
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.noticeDecision, "cannot-schedule")
        XCTAssertEqual(entry.noticeDelivered, false)
        XCTAssertEqual(entry.notificationAuthorizationStatus, .denied)
        XCTAssertEqual(entry.notificationAlertSetting, .disabled)
        XCTAssertEqual(entry.settingsRoute, .notificationSettings)
    }

    func testLeaseRenewsOnlyForPositiveDecodableFinalizedAudio() async throws {
        let decodable = try self.makeHarness(locationAuthorization: .denied)
        decodable.engine.start(); await decodable.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: decodable.clock) >= 2 })
        decodable.notificationScheduler.calls.removeAll()
        decodable.clock.advance(by: 300)
        await self.drain(until: { decodable.recorder.startURLs.count == 2 })
        XCTAssertEqual(decodable.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.lease).count, 1)

        let zeroLength = try self.makeHarness(locationAuthorization: .denied)
        zeroLength.engine.start(); await zeroLength.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: zeroLength.clock) >= 2 })
        let zeroAudioURL = try XCTUnwrap(zeroLength.recorder.url)
        zeroLength.audioProbe.durations[zeroAudioURL.path] = 0
        zeroLength.notificationScheduler.calls.removeAll()
        zeroLength.clock.advance(by: 300)
        await self.drain(until: { zeroLength.recorder.startURLs.count == 2 })
        XCTAssertEqual(zeroLength.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.lease).count, 0)

        let undecodable = try self.makeHarness(locationAuthorization: .denied)
        undecodable.engine.start(); await undecodable.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: undecodable.clock) >= 2 })
        let undecodableAudioURL = try XCTUnwrap(undecodable.recorder.url)
        undecodable.audioProbe.durations[undecodableAudioURL.path] = .some(nil)
        undecodable.notificationScheduler.calls.removeAll()
        undecodable.clock.advance(by: 300)
        await self.drain(until: { undecodable.recorder.startURLs.count == 2 })
        XCTAssertEqual(undecodable.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.lease).count, 0)
    }

    func testAppendFixInCallbackDurablyWritesBeforeFinalize() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        let first = Self.fix(time: Date(timeIntervalSince1970: 1_713_624_010))
        let second = Self.fix(time: Date(timeIntervalSince1970: 1_713_624_020), lat: 39.8)
        harness.locationProvider.emitFix(first)
        harness.locationProvider.emitFix(second)

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        let locationURL = harness.storage.locationURL(directory: entry.directoryURL)
        let lines = try self.jsonLines(at: locationURL)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1]["schema"] as? String, "solstone.location.fix/1")
        XCTAssertEqual(lines[2]["lat"] as? Double, 39.8)
    }

    func testFinalizeRewritesHeaderFromDurableFixLog() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix())
        harness.locationProvider.emitFix(Self.fix(lat: 39.8))
        harness.engine.stop(); await harness.engine.settled()

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        let header = try XCTUnwrap(self.jsonLines(at: harness.storage.locationURL(directory: entry.directoryURL)).first)
        XCTAssertEqual(header["schema"] as? String, "solstone.location.segment/1")
        XCTAssertEqual(header["platform"] as? String, "watchos")
        XCTAssertEqual(header["tier"] as? String, "light")
        XCTAssertEqual(header["accuracy"] as? String, "reduced")
        XCTAssertEqual(header["fix_count"] as? Int, 2)
        XCTAssertEqual(header["gap"] as? Bool, false)
    }

    func testNotArmedStationaryCarryForwardAndStalledGapAreDistinct() async throws {
        let notArmed = try self.makeHarness(audioPermission: true, locationAuthorization: .denied)
        notArmed.engine.start(); await notArmed.engine.settled()
        notArmed.engine.stop(); await notArmed.engine.settled()
        let notArmedEntry = try XCTUnwrap(notArmed.storage.scanManifests().first)
        XCTAssertFalse(notArmedEntry.manifest.sensors.contains(.location))
        XCTAssertFalse(notArmed.storage.fileWriter.fileExists(at: notArmed.storage.locationURL(directory: notArmedEntry.directoryURL)))

        let stalled = try self.makeHarness(locationAuthorization: .authorized)
        stalled.engine.start(); await stalled.engine.settled()
        stalled.engine.stop(); await stalled.engine.settled()
        let stalledManifest = try XCTUnwrap(stalled.storage.scanManifests().first?.manifest)
        XCTAssertEqual(stalledManifest.fixCount, 0)
        XCTAssertTrue(stalledManifest.gap)

        let stationary = try self.makeHarness(locationAuthorization: .authorized)
        stationary.engine.start(); await stationary.engine.settled()
        stationary.locationProvider.emitFix(Self.fix())
        await self.drain(until: { self.pendingSleeperCount(in: stationary.clock) >= 2 })
        stationary.clock.advance(by: 300)
        await self.drain(until: {
            (try? stationary.storage.scanManifests().count) == 2
        })
        stationary.engine.stop(); await stationary.engine.settled()
        let entries = try stationary.storage.scanManifests()
        let locationLines = try entries.flatMap { entry in
            try self.jsonLines(at: stationary.storage.locationURL(directory: entry.directoryURL))
        }
        let stationaryFix = locationLines.first { ($0["stationary"] as? Bool) == true }
        XCTAssertNotNil(stationaryFix)
        XCTAssertTrue(entries.map(\.manifest).contains { $0.fixCount >= 1 && !$0.gap })
    }

    func testPreFinalReadableAudioRecoversPartialQueued() async throws {
        let harness = try self.makeHarness()
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let directory = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt,
            state: .persisted,
            sensors: [.audio]
        )
        let audioURL = harness.storage.audioURL(directory: directory)
        try Data("aac".utf8).write(to: audioURL)
        harness.audioProbe.durations[audioURL.path] = 12.3

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let manifest = try XCTUnwrap(harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.state, .queued)
        XCTAssertTrue(manifest.partial)
        XCTAssertFalse(manifest.lost)
        XCTAssertEqual(manifest.duration, 12.3, accuracy: 0.001)
    }

    func testPreFinalUndecodableAudioMarksPartialLost() async throws {
        let harness = try self.makeHarness()
        let directory = try self.writeManifest(
            storage: harness.storage,
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .persisted,
            sensors: [.audio]
        )
        let audioURL = harness.storage.audioURL(directory: directory)
        try Data().write(to: audioURL)
        harness.audioProbe.durations[audioURL.path] = .some(nil)

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        XCTAssertEqual(entry.manifest.state, .queued)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertTrue(entry.manifest.lost)
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: harness.storage.audioURL(directory: entry.directoryURL)))
    }

    func testFinalizeProbeMarksUndecodableAudioLost() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix())
        let audioURL = try XCTUnwrap(harness.recorder.url)
        harness.audioProbe.durations[audioURL.path] = .some(nil)
        harness.engine.stop(); await harness.engine.settled()

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        XCTAssertEqual(entry.manifest.state, .queued)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertTrue(entry.manifest.lost)
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: harness.storage.audioURL(directory: entry.directoryURL)))
        XCTAssertTrue(harness.storage.fileWriter.fileExists(at: harness.storage.locationURL(directory: entry.directoryURL)))
    }

    func testDecodableNonZeroAudioFinalizesHealthyWithoutLostPartial() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        harness.engine.start(); await harness.engine.settled()
        let audioURL = try XCTUnwrap(harness.recorder.url)
        harness.audioProbe.durations[audioURL.path] = 123
        harness.engine.stop(); await harness.engine.settled()

        let manifest = try XCTUnwrap(harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.state, .queued)
        XCTAssertFalse(manifest.partial)
        XCTAssertFalse(manifest.lost)
        XCTAssertEqual(manifest.duration, 123, accuracy: 0.001)
    }

    func testZeroElapsedAudioStartFailureDiscardsOnlyCarryForwardSegment() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix())
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.recorder.startError = ObserverError.unavailable(reason: "audio unavailable")
        harness.clock.advance(by: 300)
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioStartFailed } })

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.manifest.state, .queued)
        XCTAssertEqual(entries.first?.manifest.fixCount, 1)
        XCTAssertEqual(statuses.last?.audioTerminalReason, .audioStartFailed)
        XCTAssertEqual(harness.notificationScheduler.submittedRequests.filter {
            $0.identifier == WatchNoticeIdentifiers.notice
        }.count, 1)
    }

    func testRolloverReopenDeniedMicrophoneUsesGrantCopyAndRoute() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix())
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.recorder.microphonePermission = .denied
        harness.recorder.startError = ObserverError.unavailable(reason: "platform denied microphone")
        harness.clock.advance(by: 300)
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .microphonePermissionRevoked } })

        XCTAssertEqual(statuses.last?.audioTerminalReason, .microphonePermissionRevoked)
        XCTAssertEqual(harness.engine.ownerPresentation.settingsRoute, .microphone)
        let notice = try XCTUnwrap(harness.notificationScheduler.submittedRequests.first {
            $0.identifier == WatchNoticeIdentifiers.notice
        })
        XCTAssertEqual(notice.title, WatchNoticeCopy.microphoneAccessNeeded.title)
        XCTAssertEqual(notice.body, WatchNoticeCopy.microphoneAccessNeeded.body)
        XCTAssertFalse(notice.title.contains("platform"))
        XCTAssertFalse(notice.body.contains("platform"))
    }

    func testElapsedLocationCoverageSegmentIsNeverDiscarded() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix())
        harness.engine.stop(); await harness.engine.settled()

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.manifest.state, .queued)
        XCTAssertEqual(entries.first?.manifest.fixCount, 1)
    }

    func testLocationWriteFailureFinalizesPartialAndFlagsLocationCoverage() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: true)
        let harness = try self.makeHarness(
            locationAuthorization: .authorized,
            fileWriter: fileWriter
        )

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix())
        let degraded = harness.engine.ownerPresentation
        XCTAssertEqual(degraded.status, .active)
        XCTAssertEqual(degraded.locationAdvisory, .writeFailed)
        XCTAssertTrue(degraded.isSessionRunning)
        harness.engine.stop(); await harness.engine.settled()

        let presentation = harness.engine.ownerPresentation
        XCTAssertEqual(presentation.status, .off)
        XCTAssertEqual(presentation.locationAdvisory, .writeFailed)
        XCTAssertFalse(presentation.isSessionRunning)
        let manifest = try XCTUnwrap(harness.storage.scanManifests().first?.manifest)
        XCTAssertTrue(manifest.partial)
        XCTAssertNotNil(manifest.failureReason)
    }

    func testAudioStartObserverErrorPassesThroughToWatchFace() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.recorder.startError = ObserverError.unavailable(reason: "audio unavailable")

        harness.engine.start(); await harness.engine.settled()

        XCTAssertEqual(
            harness.engine.ownerPresentation.status,
            .needsAttention(.unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable))
        )
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        let stateWord = watchFaceModel(for: harness.engine.ownerPresentation, isReachable: true).stateWord
        XCTAssertEqual(stateWord, SourceVocabulary.watchMicrophoneUnavailable)
        XCTAssertFalse(stateWord.contains("unavailable("))
        XCTAssertFalse(stateWord.contains("\""))
    }

    func testFailureMapperKeepsDiskFullChecksAndGenericFallback() {
        let posixDiskFull = WatchCaptureFailureMapper.observerError(
            for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        )
        let cocoaDiskFull = WatchCaptureFailureMapper.observerError(
            for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        )
        let genericError = NSError(domain: "WatchCaptureTests.generic", code: 7)

        XCTAssertEqual(posixDiskFull, .diskFull)
        XCTAssertEqual(posixDiskFull.message, "storage is full")
        XCTAssertEqual(cocoaDiskFull, .diskFull)
        XCTAssertEqual(cocoaDiskFull.message, "storage is full")
        XCTAssertEqual(
            WatchCaptureFailureMapper.observerError(for: genericError),
            .unavailable(reason: SourceVocabulary.watchGenericUnavailable)
        )
    }

    func testSensorFailureDoesNotCrashAndAudioKeepsRollingWithLocationCoverageFlag() async throws {
        let harness = try self.makeHarness(
            audioPermission: true,
            locationAuthorization: .authorized,
            fileWriter: FailingWatchFileWriter(failAppend: true)
        )

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.locationProvider.emitFix(Self.fix())
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })

        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        let presentation = harness.engine.ownerPresentation
        XCTAssertTrue(presentation.isSessionRunning)
        XCTAssertEqual(presentation.status, .active)
        XCTAssertEqual(presentation.locationAdvisory, .writeFailed)
    }

    func testLocationAuthorizationLossKeepsAudioRunningAndFlagsLocationCoverage() async throws {
        let harness = try self.makeHarness(audioPermission: true, locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.locationProvider.emitAuthorization(.denied)
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })

        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        let presentation = harness.engine.ownerPresentation
        XCTAssertTrue(presentation.isSessionRunning)
        XCTAssertEqual(presentation.status, .active)
        XCTAssertEqual(presentation.locationAdvisory, .authorizationLost)
    }

    func testLocationCoverageClearsOnlyAfterSuccessfulFixAppend() async throws {
        let harness = try self.makeHarness(audioPermission: true, locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFailure(NSError(domain: "WatchCaptureTests.location", code: 1))
        XCTAssertEqual(harness.engine.ownerPresentation.locationAdvisory, .providerFailed)
        harness.engine.stop(); await harness.engine.settled()
        XCTAssertEqual(harness.engine.ownerPresentation.locationAdvisory, .providerFailed)
        harness.engine.start(); await harness.engine.settled()
        XCTAssertEqual(harness.engine.ownerPresentation.locationAdvisory, .providerFailed)
        harness.locationProvider.emitFix(Self.fix())
        XCTAssertNil(harness.engine.ownerPresentation.locationAdvisory)
    }

    func testLocationCoverageFailuresDoNotChangeCaptureState() async throws {
        let writeFailure = try self.makeHarness(
            audioPermission: true,
            locationAuthorization: .authorized,
            fileWriter: FailingWatchFileWriter(failAppend: true)
        )
        writeFailure.engine.start(); await writeFailure.engine.settled()
        writeFailure.locationProvider.emitFix(Self.fix())

        let authorization = try self.makeHarness(audioPermission: true, locationAuthorization: .authorized)
        authorization.engine.start(); await authorization.engine.settled()
        authorization.locationProvider.emitAuthorization(.denied)

        let provider = try self.makeHarness(audioPermission: true, locationAuthorization: .authorized)
        provider.engine.start(); await provider.engine.settled()
        provider.locationProvider.emitFailure(NSError(domain: "WatchCaptureTests.location", code: 1))

        XCTAssertEqual(writeFailure.engine.ownerPresentation.status, .active)
        XCTAssertEqual(writeFailure.engine.ownerPresentation.locationAdvisory, .writeFailed)
        XCTAssertEqual(authorization.engine.ownerPresentation.status, .active)
        XCTAssertEqual(authorization.engine.ownerPresentation.locationAdvisory, .authorizationLost)
        XCTAssertEqual(provider.engine.ownerPresentation.status, .active)
        XCTAssertEqual(provider.engine.ownerPresentation.locationAdvisory, .providerFailed)
    }

    func testOwnerStopFinalizesCurrentSegmentAndDeactivatesSessionOnce() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        harness.engine.start(); await harness.engine.settled()
        harness.engine.stop(); await harness.engine.settled()

        XCTAssertEqual(harness.audioSession.setActiveCalls, [true, false])
        let manifest = try XCTUnwrap(harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.state, .queued)
    }

    func testRelaunchReconciliationDoesNotResumeSession() async throws {
        let harness = try self.makeHarness()
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let directory = try self.writeManifest(
            storage: harness.storage,
            startedAt: startedAt,
            state: .persisted,
            sensors: [.audio]
        )
        let audioURL = harness.storage.audioURL(directory: directory)
        try Data("aac".utf8).write(to: audioURL)
        harness.audioProbe.durations[audioURL.path] = 42

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertTrue(harness.recorder.startURLs.isEmpty)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
        XCTAssertEqual(harness.engine.ownerPresentation.queuedCount, 1)
    }

    func testSessionRecordWriteUsesAtomicReplaceFile() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)

        harness.engine.start(); await harness.engine.settled()

        let recordURL = harness.storage.sessionRecordURL()
        XCTAssertTrue(fileWriter.atomicReplaceURLs.contains(recordURL))
        XCTAssertFalse(fileWriter.writeDataURLs.contains(recordURL))
        XCTAssertFalse(fileWriter.readDataURLs.contains(recordURL))
    }

    func testSessionRecordWriteFailureTerminatesAndPublishesPersistenceAdvisory() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)

        harness.engine.start(); await harness.engine.settled()
        fileWriter.failAtomicReplace = true
        harness.engine.stop(); await harness.engine.settled()

        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        XCTAssertTrue(fileWriter.atomicReplaceURLs.contains(harness.storage.sessionRecordURL()))
    }

    func testReconcileActiveRecordWriteFailurePublishesPersistenceAdvisory() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(fileWriter: fileWriter)
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try harness.storage.writeSessionRecord(record)
        fileWriter.failAtomicReplace = true
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertEqual(statuses.last?.audioTerminalReason, .processExitedWhileActive)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
    }

    func testTerminalStorageFailureStillPublishesAndPreservesTerminalFact() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)
        var statuses: [WatchStatusContext] = []
        var presentations: [WatchCaptureOwnerPresentation] = []
        harness.engine.onPublishStatus = { statuses.append($0) }
        harness.engine.onPresentationChanged = { presentations.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        statuses.removeAll()
        presentations.removeAll()
        fileWriter.failWriteData = true
        harness.engine.stop(); await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(record.terminalAt)
        XCTAssertFalse(record.noticeOwed)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(statuses.last?.phase, .idle)
        XCTAssertEqual(statuses.last?.audioTerminalReason, .ownerStopped)
        XCTAssertTrue(presentations.contains { !$0.isSessionRunning && $0.status == .off })
        XCTAssertEqual(harness.audioSession.setActiveCalls.last, false)
    }

    func testDetectedStopWithFailingTerminalWriteStillAttemptsNotice() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        fileWriter.failAtomicReplace = true
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        XCTAssertEqual(statuses.last?.audioTerminalReason, .audioInterrupted)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .detectedStoppedItself)
    }

    func testDetectedNoticeSubmissionFailureKeepsDurableTerminalFactOwed() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        harness.notificationScheduler.addError = NSError(domain: "WatchCaptureTests.notification", code: 1)
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, .audioInterrupted)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertTrue(record.noticeOwed)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
    }

    func testDetectedNoticeSubmissionClearsOwedAndRelaunchDoesNotSubmitAgain() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        harness.notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await self.drain(until: { statuses.contains { $0.audioTerminalReason == .audioInterrupted } })

        XCTAssertEqual(try harness.storage.readSessionRecord()?.noticeOwed, false)

        let relaunchScheduler = MockWatchNotificationScheduler(
            authorizationStatus: .authorized,
            alertSetting: .enabled
        )
        let relaunchEngine = WatchCaptureEngine(
            audioRecorder: MockWatchAudioRecorder(microphonePermission: .granted),
            audioSession: MockWatchAudioSession(),
            locationProvider: MockWatchLocationProvider(authorizationStatus: .denied),
            storage: harness.storage,
            clock: MockObserverClock(now: Date(timeIntervalSince1970: 1_713_624_100)),
            audioProbe: MockWatchAudioProbe(),
            notificationScheduler: relaunchScheduler,
            notificationCenter: NotificationCenter()
        )

        relaunchEngine.reconcileOnLaunch(); await relaunchEngine.settled()

        XCTAssertEqual(relaunchScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 0)
    }

    func testUndecodableSessionRecordResolvesUncleanWithNoticeOwed() async throws {
        let harness = try self.makeHarness()
        try harness.storage.fileWriter.atomicReplaceFile(
            at: harness.storage.sessionRecordURL(),
            with: Data("{".utf8)
        )
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertEqual(statuses.last?.audioTerminalReason, .processExitedWhileActive)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordUnreadable)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        let notice = try XCTUnwrap(harness.notificationScheduler.submittedRequests.first {
            $0.identifier == WatchNoticeIdentifiers.notice
        })
        XCTAssertEqual(notice.title, WatchNoticeCopy.audioCouldNotBeConfirmed.title)
        XCTAssertEqual(notice.body, WatchNoticeCopy.audioCouldNotBeConfirmed.body)
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(record.terminalDisposition, .inferredStoppedItself)
        XCTAssertFalse(record.noticeOwed)
    }

    func testReconcileActiveRecordReportsInferredStoppedItselfOnce() async throws {
        let harness = try self.makeHarness()
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try harness.storage.writeSessionRecord(record)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertEqual(statuses.last?.sessionID, "session-1")
        XCTAssertEqual(statuses.last?.audioTerminalReason, .processExitedWhileActive)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
        let notice = try XCTUnwrap(harness.notificationScheduler.submittedRequests.first {
            $0.identifier == WatchNoticeIdentifiers.notice
        })
        XCTAssertEqual(notice.title, WatchNoticeCopy.audioCouldNotBeConfirmed.title)
        XCTAssertEqual(notice.body, WatchNoticeCopy.audioCouldNotBeConfirmed.body)
        XCTAssertEqual(try harness.storage.readSessionRecord()?.noticeOwed, false)
    }

    func testReconcileActiveRecordRemovesPendingLease() async throws {
        let harness = try self.makeHarness()
        harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease] = .init(
            identifier: WatchNoticeIdentifiers.lease,
            title: WatchNoticeCopy.audioCouldNotBeConfirmed.title,
            body: WatchNoticeCopy.audioCouldNotBeConfirmed.body,
            triggerDate: Date(timeIntervalSince1970: 1_713_624_600)
        )
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try harness.storage.writeSessionRecord(record)

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
    }

    func testReconcileCleanOwnerStopDoesNotReportStoppedItselfOrNoticeOwed() async throws {
        let harness = try self.makeHarness()
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .terminal,
            terminalReason: .ownerStopped,
            terminalDisposition: .ownerStopped,
            terminalAt: Date(timeIntervalSince1970: 1_713_624_030),
            noticeOwed: false
        )
        try harness.storage.writeSessionRecord(record)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertNotEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(try harness.storage.readSessionRecord()?.noticeOwed, false)
    }

    func testReconcileAbsentSessionRecordDoesNotReportStoppedItselfOrNoticeOwed() async throws {
        let harness = try self.makeHarness()
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        XCTAssertNil(statuses.last?.audioTerminalReason)
        XCTAssertNil(statuses.last?.audioTerminalDisposition)
        XCTAssertNil(try harness.storage.readSessionRecord())
    }

    func testReconcilingSameTerminalRecordTwiceKeepsSingleNoticeAndStableFact() async throws {
        let harness = try self.makeHarness()
        let terminalAt = Date(timeIntervalSince1970: 1_713_624_030)
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .terminal,
            terminalReason: .processExitedWhileActive,
            terminalDisposition: .inferredStoppedItself,
            terminalAt: terminalAt,
            noticeOwed: true
        )
        try harness.storage.writeSessionRecord(record)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()
        let afterFirst = try XCTUnwrap(try harness.storage.readSessionRecord())
        let noticeCountAfterFirst = harness.notificationScheduler.submittedRequests.filter {
            $0.identifier == WatchNoticeIdentifiers.notice
        }.count
        harness.engine.reconcileOnLaunch(); await harness.engine.settled()
        let afterSecond = try XCTUnwrap(try harness.storage.readSessionRecord())
        let noticeCountAfterSecond = harness.notificationScheduler.submittedRequests.filter {
            $0.identifier == WatchNoticeIdentifiers.notice
        }.count

        XCTAssertEqual(statuses.filter { $0.audioTerminalDisposition == .inferredStoppedItself }.count, 1)
        XCTAssertEqual(afterFirst.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(afterSecond.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(afterFirst.terminalAt, terminalAt)
        XCTAssertEqual(afterSecond.terminalAt, terminalAt)
        XCTAssertFalse(afterFirst.noticeOwed)
        XCTAssertFalse(afterSecond.noticeOwed)
        XCTAssertEqual(noticeCountAfterFirst, 1)
        XCTAssertEqual(noticeCountAfterSecond, noticeCountAfterFirst)
    }

    func testReconcileKeepsNoticeOwedWhenSubmissionFails() async throws {
        let harness = try self.makeHarness()
        harness.notificationScheduler.addError = NSError(domain: "WatchCaptureTests.notification", code: 1)
        let terminalAt = Date(timeIntervalSince1970: 1_713_624_030)
        let record = WatchCaptureSessionRecord(
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .terminal,
            terminalReason: .processExitedWhileActive,
            terminalDisposition: .inferredStoppedItself,
            terminalAt: terminalAt,
            noticeOwed: true
        )
        try harness.storage.writeSessionRecord(record)

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let afterReconcile = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(afterReconcile.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(afterReconcile.terminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(afterReconcile.terminalAt, terminalAt)
        XCTAssertTrue(afterReconcile.noticeOwed)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
    }

    func testOwedClearKeepsTerminalFactsWithConcurrentStartDuringNoticeSubmission() async throws {
        let harness = try self.makeHarness()
        let terminalAt = harness.clock.now()
        let record = WatchCaptureSessionRecord(
            sessionID: "intended", startedAt: terminalAt.addingTimeInterval(-30), state: .active,
            terminalReason: nil, terminalDisposition: nil, terminalAt: nil, noticeOwed: false
        )
        try harness.storage.writeSessionRecord(record)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        harness.notificationScheduler.onAddCallback = {
            harness.engine.start()
        }

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        guard case let .available(entries) = history.read(asOf: terminalAt) else { return XCTFail("history unreadable") }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.sessionID, $0) })
        let concurrentID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID
        XCTAssertEqual(Set(byID.keys), Set(["intended", concurrentID]))
        XCTAssertFalse(try XCTUnwrap(byID["intended"]).noticeOwed)
        XCTAssertEqual(try XCTUnwrap(byID["intended"]).noticeDecision, "schedule")
        XCTAssertEqual(try XCTUnwrap(byID["intended"]).noticeDelivered, true)
        XCTAssertEqual(try XCTUnwrap(byID["intended"]).notificationAuthorizationStatus, .authorized)
        XCTAssertEqual(try XCTUnwrap(byID["intended"]).notificationAlertSetting, .enabled)
        let concurrent = try XCTUnwrap(byID[concurrentID])
        XCTAssertNil(concurrent.noticeDecision)
        XCTAssertNil(concurrent.noticeDelivered)
    }

    func testStartThenStopBeforePumpHasNoStartEffects() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        harness.engine.start()
        harness.engine.stop()
        await harness.engine.settled()

        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        XCTAssertTrue(harness.recorder.startURLs.isEmpty)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
        XCTAssertEqual(harness.locationProvider.startCallCount, 0)
        XCTAssertNil(try harness.storage.readSessionRecord())
        XCTAssertTrue(try harness.storage.scanManifests().isEmpty)
        XCTAssertEqual(history.read(asOf: harness.clock.now()), .available([]))
        XCTAssertNil(history.readCounter())
        XCTAssertEqual(self.pendingSleeperCount(in: harness.clock), 0)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)

    }

    func testRunningStartThenStopBeforePumpTerminalizesLiveSessionOnce() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        let sessionID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID

        harness.engine.start()
        harness.engine.stop()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.sessionID, sessionID)
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertFalse(harness.recorder.isRecording)
        XCTAssertEqual(harness.audioSession.setActiveCalls.filter { !$0 }.count, 1)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)

        harness.notificationCenter.post(name: AVAudioSession.interruptionNotification, object: nil)
        harness.clock.advance(by: 300)
        await Task.yield()
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
    }

    func testFinalStopDropsLaterStartWhileSuspendedStartIsReleased() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.authorizationStatusGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        harness.engine.stop()
        harness.engine.start()
        harness.engine.stop()
        await self.advanceNotificationGate(
            gate,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.authorizationStatusGate
        )
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertEqual(harness.recorder.startURLs.count, 0)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testFinalStopRemovesSuccessorAcrossOldBoundRecorderTerminal() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        let source = try XCTUnwrap(harness.recorder.startSources.last)
        harness.engine.stop()
        harness.engine.start()
        harness.recorder.eventSink?.audioRecorderDidFinish(successfully: false, source: source)
        harness.engine.stop()
        await self.advanceNotificationGate(
            gate,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.addGate
        )
        await harness.engine.settled()

        try self.assertOwnerStoppedTerminal(in: harness, recorderStops: 1)
        XCTAssertEqual(harness.recorder.startURLs.count, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 0)
    }

    func testOldBoundRecorderTerminalDoesNotStopSuccessor() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        let firstID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID
        let source = try XCTUnwrap(harness.recorder.startSources.last)
        harness.engine.stop()
        harness.engine.start()
        harness.recorder.eventSink?.audioRecorderEncodeError(nil, source: source)
        await self.advanceNotificationGate(
            gate,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.addGate
        )
        await harness.engine.settled()

        let successor = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertNotEqual(successor.sessionID, firstID)
        XCTAssertEqual(successor.state, .active)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testRecorderTerminalSourcesIgnorePriorSessionAndClaimCurrentExactlyOnce() async throws {
        let cases: [(WatchCaptureTerminalReason, @MainActor (Harness, WatchCaptureSourceToken) -> Void)] = [
            (.audioFinishUnsuccessful, { harness, source in
                harness.recorder.eventSink?.audioRecorderDidFinish(successfully: false, source: source)
            }),
            (.audioEncodeError, { harness, source in
                harness.recorder.eventSink?.audioRecorderEncodeError(nil, source: source)
            }),
        ]

        for (reason, deliver) in cases {
            let harness = try self.makeHarness(locationAuthorization: .denied)
            harness.engine.start(); await harness.engine.settled()
            let priorSource = try XCTUnwrap(harness.recorder.startSources.last)
            harness.engine.stop(); await harness.engine.settled()
            harness.engine.start(); await harness.engine.settled()
            let currentSource = try XCTUnwrap(harness.recorder.startSources.last)
            let stopsBeforeOldTerminal = harness.recorder.stopCallCount

            deliver(harness, priorSource)
            await harness.engine.settled()
            XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning, "\(reason)")
            XCTAssertEqual(harness.recorder.stopCallCount, stopsBeforeOldTerminal, "\(reason)")

            deliver(harness, currentSource)
            deliver(harness, currentSource)
            await harness.engine.settled()

            let record = try XCTUnwrap(try harness.storage.readSessionRecord())
            XCTAssertEqual(record.terminalReason, reason)
            XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
            XCTAssertEqual(harness.recorder.stopCallCount, stopsBeforeOldTerminal + 1)
            XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        }
    }

    func testCurrentProductionRecorderFinishTerminalizesAndClosesOnce() async throws {
        let harness = try self.makeProductionAudioHarness()
        harness.engine.start()
        await harness.engine.settled()
        let handle = try XCTUnwrap(harness.recorders.latest)
        handle.telemetry.reportedCurrentTime = 42
        let audioURL = try XCTUnwrap(handle.recorder?.url)
        harness.audioProbe.durations[audioURL.path] = .some(nil)
        handle.recorder?.stopCallback = .unsuccessfulFinish
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        let deliveriesBefore = harness.deliveries.count

        handle.recorder?.fireFinish(successfully: false)
        await self.drain(until: { harness.deliveries.count >= deliveriesBefore + 2 })
        await harness.engine.settled()
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertEqual(handle.telemetry.stopCallCount, 1)
        XCTAssertEqual(publications.statuses.filter { $0.audioTerminalReason == .audioFinishUnsuccessful }.count, 1)
        let manifest = try XCTUnwrap(try harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.duration, 42)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        await self.drain(until: { handle.isReleased })
    }

    func testCurrentProductionRecorderEncodeErrorTerminalizesAndClosesOnce() async throws {
        let harness = try self.makeProductionAudioHarness()
        harness.engine.start()
        await harness.engine.settled()
        let handle = try XCTUnwrap(harness.recorders.latest)
        handle.telemetry.reportedCurrentTime = 42
        let audioURL = try XCTUnwrap(handle.recorder?.url)
        harness.audioProbe.durations[audioURL.path] = .some(nil)
        handle.recorder?.stopCallback = .unsuccessfulFinish
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        let deliveriesBefore = harness.deliveries.count

        handle.recorder?.fireEncodeError()
        await self.drain(until: { harness.deliveries.count >= deliveriesBefore + 2 })
        await harness.engine.settled()
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioEncodeError)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertEqual(handle.telemetry.stopCallCount, 1)
        XCTAssertEqual(publications.statuses.filter { $0.audioTerminalReason == .audioEncodeError }.count, 1)
        let manifest = try XCTUnwrap(try harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.duration, 42)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        await self.drain(until: { handle.isReleased })
    }

    func testGatedProductionEncodeErrorKeepsPendingPairUntilCleanupThenUsesFreshDeadline() async throws {
        let gate = WatchCaptureHoldGate()
        let harness = try self.makeProductionAudioHarness(terminalHandoffGate: gate)
        harness.engine.start(); await harness.engine.settled()
        let handle = try XCTUnwrap(harness.recorders.latest)
        handle.telemetry.reportedCurrentTime = 42
        let audioURL = try XCTUnwrap(handle.recorder?.url)
        harness.audioProbe.durations[audioURL.path] = .some(nil)

        handle.recorder?.fireEncodeError()
        await self.waitForGate(gate)
        await harness.retentionClock.advance(by: .seconds(60))
        XCTAssertNotNil(handle.recorder)
        XCTAssertNotNil(handle.forwarder)
        XCTAssertEqual(handle.telemetry.stopCallCount, 0)

        await gate.open()
        await self.drain(until: { harness.deliveries.count >= 1 })
        await harness.engine.settled()
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioEncodeError)
        XCTAssertEqual(handle.telemetry.stopCallCount, 1)
        XCTAssertEqual(handle.telemetry.reportedCurrentTime, 42)
        let manifest = try XCTUnwrap(try harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.duration, 42)
        await self.drain(until: { harness.retentionClock.pendingSleeperCount == 1 })
        await harness.retentionClock.advance(by: .milliseconds(4_999))
        XCTAssertFalse(handle.isReleased)
        await harness.retentionClock.advance(by: .milliseconds(1))
        await self.drain(until: { handle.isReleased })
    }

    func testDelayedFormerSessionFinishDoesNotAffectNewOwnerSession() async throws {
        let harness = try self.makeProductionAudioHarness()
        harness.engine.start(); await harness.engine.settled()
        let former = try XCTUnwrap(harness.recorders.latest)
        harness.engine.stop(); await harness.engine.settled()
        harness.engine.start(); await harness.engine.settled()
        let successor = try XCTUnwrap(harness.recorders.latest)
        try await self.assertDelayedFormerSessionCallbackIsInert(
            in: harness,
            former: former,
            successor: successor,
            deliver: { $0.recorder?.fireFinish(successfully: false) }
        )
    }

    func testDelayedFormerSessionEncodeErrorDoesNotAffectNewOwnerSession() async throws {
        let harness = try self.makeProductionAudioHarness()
        harness.engine.start(); await harness.engine.settled()
        let former = try XCTUnwrap(harness.recorders.latest)
        harness.engine.stop(); await harness.engine.settled()
        harness.engine.start(); await harness.engine.settled()
        let successor = try XCTUnwrap(harness.recorders.latest)
        try await self.assertDelayedFormerSessionCallbackIsInert(
            in: harness,
            former: former,
            successor: successor,
            deliver: { $0.recorder?.fireEncodeError() }
        )
    }

    func testSynchronousDuplicateFinishDuringTerminalStopIsIdempotent() async throws {
        let harness = try self.makeProductionAudioHarness()
        harness.engine.start(); await harness.engine.settled()
        let handle = try XCTUnwrap(harness.recorders.latest)
        handle.recorder?.stopCallback = .unsuccessfulFinish
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        let deliveriesBefore = harness.deliveries.count

        handle.recorder?.fireFinish(successfully: false)
        await self.drain(until: { harness.deliveries.count >= deliveriesBefore + 2 })
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(handle.telemetry.stopCallCount, 1)
        XCTAssertEqual(publications.statuses.filter { $0.audioTerminalReason == .audioFinishUnsuccessful }.count, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        await self.drain(until: { handle.isReleased })
    }

    func testDelayedRolloverPredecessorFinishCannotTerminalizeSuccessor() async throws {
        let harness = try self.makeProductionAudioHarness()
        let pair = try await self.rolloverProductionRecorderPair(in: harness)
        try await self.assertDelayedRolloverPredecessorCallbackIsInert(
            in: harness,
            pair: pair,
            deliver: { $0.recorder?.fireFinish(successfully: false) }
        )
    }

    func testDelayedRolloverPredecessorEncodeErrorCannotTerminalizeSuccessor() async throws {
        let harness = try self.makeProductionAudioHarness()
        let pair = try await self.rolloverProductionRecorderPair(in: harness)
        try await self.assertDelayedRolloverPredecessorCallbackIsInert(
            in: harness,
            pair: pair,
            deliver: { $0.recorder?.fireEncodeError() }
        )
    }

    func testAdmittedPreRolloverTerminalIsRejectedAtExecutionForSuccessorEnrollment() async throws {
        let harness = try self.makeProductionAudioHarness(synchronousTerminalHandoff: true)
        harness.engine.start()
        await harness.engine.settled()
        let predecessor = try XCTUnwrap(harness.recorders.latest)
        let predecessorSource = try XCTUnwrap(predecessor.forwarder).source
        let snapshot = ProductionRolloverSnapshotProbe()

        harness.engine.onPresentationChanged = { _ in
            guard harness.recorders.count == 2, snapshot.value == nil else { return }
            do {
                let successor = try XCTUnwrap(harness.recorders.latest)
                snapshot.value = ProductionRolloverSnapshot(
                    record: try XCTUnwrap(try harness.storage.readSessionRecord()),
                    storageInventory: try self.storageInventory(in: harness.storage),
                    presentation: harness.engine.ownerPresentation,
                    notices: harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count,
                    successor: successor,
                    successorSource: try XCTUnwrap(successor.forwarder).source,
                    successorTelemetry: successor.telemetry.snapshot,
                    predecessorTelemetry: predecessor.telemetry.snapshot
                )
                harness.engine.onPublishStatus = { snapshot.publications.statuses.append($0) }
                harness.engine.onPresentationChanged = { snapshot.publications.presentations.append($0) }
            } catch {
                snapshot.error = error
            }
        }

        // Both submissions happen in one MainActor turn. The synchronous adapter
        // handoff admits B's terminal while B is current, but the serializer pump
        // executes the already-queued rollover first.
        harness.clock.advance(by: 1)
        harness.engine.lifecycleSerializer.submit(.rollover)
        predecessor.recorder?.fireFinish(successfully: false)
        await self.drain(until: { snapshot.value != nil || snapshot.error != nil })
        await harness.engine.settled()

        XCTAssertNil(snapshot.error)
        let before = try XCTUnwrap(snapshot.value)
        XCTAssertEqual(predecessorSource.sessionID, before.successorSource.sessionID)
        XCTAssertNotNil(predecessorSource.enrollment)
        XCTAssertNotNil(before.successorSource.enrollment)
        XCTAssertNotEqual(predecessorSource.enrollment, before.successorSource.enrollment)
        XCTAssertEqual(predecessor.telemetry.stopCallCount, 1)
        XCTAssertEqual(harness.deliveries.count, 1)

        // A duplicate releases B from retired ownership. It has the same stale
        // enrollment and therefore remains inert at execution time.
        predecessor.recorder?.fireFinish(successfully: false)
        await self.drain(until: { predecessor.isReleased })
        await harness.engine.settled()

        let after = try XCTUnwrap(try harness.storage.readSessionRecord())
        let storageInventoryAfter = try self.storageInventory(in: harness.storage)
        XCTAssertEqual(after, before.record)
        XCTAssertEqual(storageInventoryAfter, before.storageInventory)
        XCTAssertEqual(harness.engine.ownerPresentation, before.presentation)
        XCTAssertTrue(snapshot.publications.statuses.isEmpty)
        XCTAssertTrue(snapshot.publications.presentations.isEmpty)
        XCTAssertEqual(
            harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count,
            before.notices
        )
        XCTAssertEqual(before.successor.telemetry.snapshot, before.successorTelemetry)
        XCTAssertTrue(before.successor.telemetry.isRecording)
        XCTAssertEqual(before.successor.telemetry.stopCallCount, 0)
        XCTAssertEqual(predecessor.telemetry.stopCallCount, before.predecessorTelemetry.stopCallCount)
        XCTAssertEqual(predecessor.telemetry.recordCallCount, before.predecessorTelemetry.recordCallCount)
        XCTAssertEqual(predecessor.telemetry.reportedCurrentTime, before.predecessorTelemetry.reportedCurrentTime)
        XCTAssertEqual(predecessor.telemetry.isRecording, before.predecessorTelemetry.isRecording)
        XCTAssertEqual(
            predecessor.telemetry.deliveredCallbackCount,
            before.predecessorTelemetry.deliveredCallbackCount + 1
        )
    }

    func testCurrentRolloverSuccessorFinishIsAuthoritativeOnce() async throws {
        let harness = try self.makeProductionAudioHarness()
        let pair = try await self.rolloverProductionRecorderPair(in: harness)
        pair.successor.recorder?.stopCallback = .unsuccessfulFinish
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        let deliveriesBefore = harness.deliveries.count
        pair.successor.recorder?.fireFinish(successfully: false)
        await self.drain(until: { harness.deliveries.count >= deliveriesBefore + 2 })
        await harness.engine.settled()
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(pair.successor.telemetry.stopCallCount, 1)
        XCTAssertEqual(publications.statuses.filter { $0.audioTerminalReason == .audioFinishUnsuccessful }.count, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        await self.drain(until: { pair.successor.isReleased })
    }

    func testCurrentRolloverSuccessorEncodeErrorIsAuthoritativeOnce() async throws {
        let harness = try self.makeProductionAudioHarness()
        let pair = try await self.rolloverProductionRecorderPair(in: harness)
        pair.successor.recorder?.stopCallback = .unsuccessfulFinish
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        let deliveriesBefore = harness.deliveries.count
        pair.successor.recorder?.fireEncodeError()
        await self.drain(until: { harness.deliveries.count >= deliveriesBefore + 2 })
        await harness.engine.settled()
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioEncodeError)
        XCTAssertEqual(pair.successor.telemetry.stopCallCount, 1)
        XCTAssertEqual(publications.statuses.filter { $0.audioTerminalReason == .audioEncodeError }.count, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        await self.drain(until: { pair.successor.isReleased })
    }

    func testClaimedCurrentCallbackIsCleanedBeforeGatedDeliveryWithoutAffectingSuccessor() async throws {
        let gate = WatchCaptureHoldGate()
        let harness = try self.makeProductionAudioHarness(terminalHandoffGate: gate)
        harness.engine.start(); await harness.engine.settled()
        let predecessor = try XCTUnwrap(harness.recorders.latest)
        predecessor.recorder?.fireFinish(successfully: false)
        await self.waitForGate(gate)
        harness.clock.advance(by: 1)
        harness.engine.lifecycleSerializer.submit(.rollover)
        await self.drain(until: { harness.recorders.count == 2 })
        await harness.engine.settled()
        let successor = try XCTUnwrap(harness.recorders.latest)
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        harness.engine.onPresentationChanged = { publications.presentations.append($0) }
        let notices = harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count
        await gate.open()
        await self.drain(until: { harness.deliveries.count >= 1 })
        await harness.engine.settled()
        predecessor.recorder?.fireFinish(successfully: false)
        await self.drain(until: { harness.deliveries.count >= 2 })
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(predecessor.telemetry.stopCallCount, 1)
        XCTAssertEqual(successor.telemetry.stopCallCount, 0)
        XCTAssertEqual(record.state, .active)
        XCTAssertNil(record.terminalReason)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertTrue(publications.statuses.isEmpty)
        XCTAssertTrue(publications.presentations.isEmpty)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, notices)
        await self.drain(until: { predecessor.isReleased })
    }

    func testCurrentSuccessorCallbackRemainsServiceableAfterPriorPendingDrain() async throws {
        let gate = WatchCaptureHoldGate()
        let harness = try self.makeProductionAudioHarness(terminalHandoffGate: gate)
        harness.engine.start(); await harness.engine.settled()
        let predecessor = try XCTUnwrap(harness.recorders.latest)
        predecessor.recorder?.fireFinish(successfully: false)
        await self.waitForGate(gate)
        harness.clock.advance(by: 1)
        harness.engine.lifecycleSerializer.submit(.rollover)
        await self.drain(until: { harness.recorders.count == 2 })
        await harness.engine.settled()
        let successor = try XCTUnwrap(harness.recorders.latest)
        await gate.open()
        await self.drain(until: { harness.deliveries.count >= 1 })
        await harness.engine.settled()
        predecessor.recorder?.fireFinish(successfully: false)
        await self.drain(until: { harness.deliveries.count >= 2 })
        await harness.engine.settled()
        await self.drain(until: { predecessor.isReleased })

        successor.recorder?.stopCallback = .unsuccessfulFinish
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        let deliveriesBefore = harness.deliveries.count
        successor.recorder?.fireFinish(successfully: false)
        await self.drain(until: { harness.deliveries.count >= deliveriesBefore + 2 })
        await harness.engine.settled()
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(successor.telemetry.stopCallCount, 1)
        XCTAssertEqual(record.terminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(publications.statuses.filter { $0.audioTerminalReason == .audioFinishUnsuccessful }.count, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
        await self.drain(until: { successor.isReleased })
    }

    func testTerminalWithNoRunningOrMismatchedSourceIsNoOp() async throws {
        let idle = try self.makeHarness(locationAuthorization: .denied)
        idle.recorder.eventSink?.audioRecorderEncodeError(
            nil,
            source: WatchCaptureSourceToken(sessionID: "missing")
        )
        await idle.engine.settled()
        XCTAssertNil(try idle.storage.readSessionRecord())
        XCTAssertFalse(idle.engine.ownerPresentation.isSessionRunning)

        let active = try self.makeHarness(locationAuthorization: .denied)
        active.engine.start(); await active.engine.settled()
        active.recorder.eventSink?.audioRecorderEncodeError(
            nil,
            source: WatchCaptureSourceToken(sessionID: "mismatched")
        )
        await active.engine.settled()

        XCTAssertTrue(active.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(active.recorder.stopCallCount, 0)
    }

    func testReentrantStopAtStoppingRemovesQueuedSuccessorStart() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        let firstID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID
        harness.engine.onPublishStatus = self.oneShotStatusAction(phase: .stopping, occurrence: 1) {
            harness.engine.stop()
        }

        harness.engine.stop()
        harness.engine.start()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.sessionID, firstID)
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(harness.recorder.startURLs.count, 1)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testReentrantStartAtStoppingBeginsOneFreshSession() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        let firstID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID
        harness.engine.onPublishStatus = self.oneShotStatusAction(phase: .stopping, occurrence: 1) {
            harness.engine.start()
        }

        harness.engine.stop()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertNotEqual(record.sessionID, firstID)
        XCTAssertEqual(record.state, .active)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
    }

    func testDetectedTerminalClaimSurvivesStaleRolloverConvergence() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        let sessionID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.recorder.startError = NSError(domain: "WatchCaptureTests.recorder", code: 4)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        harness.clock.advance(by: 300)
        await self.waitForGate(gate)
        let terminalNoticeIsHeld = await gate.waiting()
        XCTAssertTrue(terminalNoticeIsHeld)

        let firstTerminal = try XCTUnwrap(try harness.storage.readSessionRecord())
        let firstTerminalAt = try XCTUnwrap(firstTerminal.terminalAt)
        XCTAssertEqual(firstTerminal.sessionID, sessionID)
        XCTAssertEqual(firstTerminal.terminalReason, .audioStartFailed)
        XCTAssertEqual(firstTerminal.terminalDisposition, .detectedStoppedItself)

        // While rollover is still executing, this Stop supersedes its generation.
        // Its stale continuation must hit the existing terminal claim, not rewrite it.
        harness.engine.stop()
        await self.advanceNotificationGate(
            gate,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.addGate
        )
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.sessionID, sessionID)
        XCTAssertEqual(record.terminalReason, .audioStartFailed)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertEqual(record.terminalAt, firstTerminalAt)
        XCTAssertEqual(harness.recorder.stopCallCount, 2)
        XCTAssertEqual(harness.audioSession.setActiveCalls.filter { !$0 }.count, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
    }

    func testRolloverKeepsSessionIdentityAcrossSuccessor() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        harness.engine.start(); await harness.engine.settled()
        let sessionID = try XCTUnwrap(try harness.storage.readSessionRecord()).sessionID
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })

        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.sessionID, sessionID)
        XCTAssertEqual(record.state, .active)
        let manifests = try harness.storage.scanManifests().map(\.manifest)
        XCTAssertEqual(Set(manifests.map(\.id)).count, 2)
    }

    func testPriorSegmentBoundTerminalDoesNotClaimRolloverSuccessor() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        harness.engine.start(); await harness.engine.settled()
        let priorSource = try XCTUnwrap(harness.recorder.startSources.first)
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })

        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })
        await harness.engine.settled()
        let successorSource = try XCTUnwrap(harness.recorder.startSources.last)
        XCTAssertEqual(priorSource.sessionID, successorSource.sessionID)
        XCTAssertNotNil(priorSource.enrollment)
        XCTAssertNotNil(successorSource.enrollment)
        XCTAssertNotEqual(priorSource.enrollment, successorSource.enrollment)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
        let stopsBeforeTerminal = harness.recorder.stopCallCount

        harness.recorder.eventSink?.audioRecorderEncodeError(nil, source: priorSource)
        harness.recorder.eventSink?.audioRecorderEncodeError(nil, source: priorSource)
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .active)
        XCTAssertNil(record.terminalReason)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.recorder.stopCallCount, stopsBeforeTerminal)
    }

    func testOnceRecorderStopFailureStillCompletesOwnerStopCleanup() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.recorder.stopErrorOnce = NSError(domain: "WatchCaptureTests.recorder", code: 2)
        harness.engine.onPublishStatus = self.oneShotStatusAction(
            phase: .observing,
            occurrence: 1,
            when: { harness.recorder.startURLs.count == 1 }
        ) {
            harness.engine.stop()
        }

        harness.engine.start(); await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(harness.audioSession.setActiveCalls.filter { !$0 }.count, 1)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)

        harness.notificationCenter.post(name: AVAudioSession.interruptionNotification, object: nil)
        harness.clock.advance(by: 300)
        await Task.yield()
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(harness.recorder.startURLs.count, 1)
    }

    func testStopAtFinalStartStatusPublicationConvergesLiveResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.onPublishStatus = self.oneShotStatusAction(
            phase: .observing,
            occurrence: 1,
            when: { harness.recorder.startURLs.count == 1 }
        ) {
            harness.engine.stop()
        }

        harness.engine.start(); await harness.engine.settled()

        try self.assertOwnerStoppedTerminal(in: harness, recorderStops: 1)
    }

    func testStopAtFinalStartPresentationConvergesLiveResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        // The first active presentation is emitted only after the start tail has
        // installed observers and scheduled its tasks; enrollment is not active.
        harness.engine.onPresentationChanged = self.oneShotPresentationAction(
            occurrence: 1,
            when: { $0.status == .active && $0.isSessionRunning && harness.recorder.startURLs.count == 1 }
        ) {
            harness.engine.stop()
        }

        harness.engine.start(); await harness.engine.settled()

        try self.assertOwnerStoppedTerminal(in: harness, recorderStops: 1)
    }

    func testStopAtSuccessorStatusPublicationConvergesLiveResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        harness.engine.onPublishStatus = self.oneShotStatusAction(
            phase: .observing,
            occurrence: 1,
            when: { harness.recorder.startURLs.count == 2 }
        ) {
            harness.engine.stop()
        }

        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })
        await harness.engine.settled()

        try self.assertOwnerStoppedTerminal(in: harness, recorderStops: 2)
    }

    func testStopAtSuccessorPresentationConvergesLiveResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        harness.engine.onPresentationChanged = self.oneShotPresentationAction(
            occurrence: 1,
            when: { $0.status == .active && $0.isSessionRunning && harness.recorder.startURLs.count == 2 }
        ) {
            harness.engine.stop()
        }

        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })
        await harness.engine.settled()

        try self.assertOwnerStoppedTerminal(in: harness, recorderStops: 2)
    }

    func testNewStartAfterStopBeginsFreshSession() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        let first = try XCTUnwrap(try harness.storage.readSessionRecord())

        harness.engine.stop()
        harness.engine.start()
        await harness.engine.settled()

        let current = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertNotEqual(current.sessionID, first.sessionID)
        XCTAssertEqual(current.state, .active)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else {
            return XCTFail("history unreadable")
        }
        XCTAssertEqual(entries.first { $0.sessionID == first.sessionID }?.terminalReason, .ownerStopped)
        XCTAssertEqual(entries.filter { $0.sessionID == current.sessionID }.count, 1)
    }

    func testOverlappingStartsAtPermissionGateBeginExactlyOneCapture() async throws {
        let harness = try self.makeHarness(
            microphonePermission: .notDetermined,
            locationAuthorization: .authorized
        )
        let gate = WatchCaptureHoldGate()
        harness.recorder.requestPermissionGate = gate
        harness.recorder.requestPermissionResult = .granted

        harness.engine.start()
        await self.waitForGate(gate)
        harness.engine.start()
        harness.recorder.requestPermissionGate = nil
        await gate.release()
        await harness.engine.settled()

        let current = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(current.state, .active)
        XCTAssertEqual(harness.recorder.startURLs.count, 1)
        XCTAssertEqual(harness.locationProvider.startCallCount, 1)
        XCTAssertEqual(try harness.storage.scanManifests().count, 1)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        XCTAssertEqual(history.readCounter()?.lifetimeSessionsStarted, 1)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else {
            return XCTFail("history unreadable")
        }
        XCTAssertEqual(entries.filter { $0.sessionID == current.sessionID }.count, 1)
    }

    func testOverlappingStartsAtNotificationGateBeginExactlyOneCapture() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.authorizationStatusGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        let waiting = await gate.waiting()
        XCTAssertTrue(waiting)
        harness.engine.start()
        harness.notificationScheduler.authorizationStatusGate = nil
        await gate.release()
        await harness.engine.settled()

        let current = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(current.state, .active)
        XCTAssertEqual(harness.recorder.startURLs.count, 1)
        XCTAssertEqual(harness.locationProvider.startCallCount, 1)
        XCTAssertEqual(try harness.storage.scanManifests().count, 1)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        XCTAssertEqual(history.readCounter()?.lifetimeSessionsStarted, 1)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else {
            return XCTFail("history unreadable")
        }
        XCTAssertEqual(entries.filter { $0.sessionID == current.sessionID }.count, 1)
    }

    func testPermissionGateSuspendsAndSupersededStartTerminalizesMintedSession() async throws {
        let harness = try self.makeHarness(
            microphonePermission: .notDetermined,
            locationAuthorization: .authorized
        )
        let gate = WatchCaptureHoldGate()
        harness.recorder.requestPermissionGate = gate
        harness.recorder.requestPermissionResult = .granted

        harness.engine.start()
        await self.waitForGate(gate)
        let permissionWaiting = await gate.waiting()
        XCTAssertTrue(permissionWaiting)

        harness.engine.stop()
        await gate.release()
        await harness.engine.settled()

        let abandoned = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(abandoned.terminalReason, .ownerStopped)
        XCTAssertEqual(abandoned.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(abandoned.terminalAt)
        XCTAssertFalse(abandoned.noticeOwed)
        XCTAssertEqual(harness.recorder.startURLs.count, 0)
        XCTAssertFalse(harness.audioSession.setActiveCalls.contains(true))
        XCTAssertEqual(harness.locationProvider.startCallCount, 0)
        XCTAssertNil(harness.engine.ownerPresentation.startRefusalReason)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)

        harness.recorder.requestPermissionGate = nil
        harness.engine.start()
        await harness.engine.settled()
        let fresh = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertNotEqual(fresh.sessionID, abandoned.sessionID)
        XCTAssertEqual(fresh.state, .active)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testNotificationGatesSuspendAtEveryOwnerStartAwait() async throws {
        let harness = try self.makeHarness(
            locationAuthorization: .denied,
            notificationAuthorizationStatus: .notDetermined
        )
        harness.notificationScheduler.requestAuthorizationResult = .authorized
        let authorization = WatchCaptureHoldGate()
        let request = WatchCaptureHoldGate()
        let alert = WatchCaptureHoldGate()
        let postRecorderAuthorization = WatchCaptureHoldGate()
        let postRecorderAlert = WatchCaptureHoldGate()
        let add = WatchCaptureHoldGate()
        harness.notificationScheduler.authorizationStatusGate = authorization
        harness.notificationScheduler.requestAuthorizationGate = request
        harness.notificationScheduler.alertSettingGate = alert
        harness.notificationScheduler.addGate = add

        harness.engine.start()
        await self.advanceNotificationGate(
            authorization,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.authorizationStatusGate
        )

        await self.advanceNotificationGate(
            request,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.requestAuthorizationGate
        )

        harness.notificationScheduler.authorizationStatusGate = postRecorderAuthorization
        await self.advanceNotificationGate(
            alert,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.alertSettingGate,
            rearmWith: postRecorderAlert
        )

        await self.advanceNotificationGate(
            postRecorderAuthorization,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.authorizationStatusGate
        )
        await self.advanceNotificationGate(
            postRecorderAlert,
            scheduler: harness.notificationScheduler,
            keyPath: \MockWatchNotificationScheduler.alertSettingGate
        )

        await self.waitForGate(add)
        let addWaiting = await add.waiting()
        XCTAssertTrue(addWaiting)
        await add.release()
        await harness.engine.settled()

        XCTAssertEqual(harness.notificationScheduler.calls.filter { $0 == .authorizationStatus }.count, 2)
        XCTAssertEqual(harness.notificationScheduler.calls.filter { $0 == .alertSetting }.count, 2)
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
    }

    func testNotificationGateSupersededStartCannotArmResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.authorizationStatusGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        let waiting = await gate.waiting()
        XCTAssertTrue(waiting)
        harness.engine.stop()
        await gate.release()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(record.terminalAt)
        XCTAssertFalse(record.noticeOwed)
        XCTAssertTrue(harness.recorder.startURLs.isEmpty)
        XCTAssertFalse(harness.audioSession.setActiveCalls.contains(true))
        XCTAssertEqual(harness.locationProvider.startCallCount, 0)
        XCTAssertNil(harness.engine.ownerPresentation.startRefusalReason)
    }

    func testThrowingAuthorizationGateSupersededStartTerminalizesBeforeAlertSetting() async throws {
        let harness = try self.makeHarness(
            locationAuthorization: .authorized,
            notificationAuthorizationStatus: .notDetermined
        )
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.requestAuthorizationGate = gate
        harness.notificationScheduler.requestAuthorizationError = NSError(
            domain: "WatchCaptureTests.notification",
            code: 1
        )

        harness.engine.start()
        await self.waitForGate(gate)
        let waiting = await gate.waiting()
        XCTAssertTrue(waiting)
        harness.engine.stop()
        await gate.release()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(record.terminalAt)
        XCTAssertFalse(record.noticeOwed)
        XCTAssertFalse(harness.notificationScheduler.calls.contains(.alertSetting))
        XCTAssertTrue(harness.recorder.startURLs.isEmpty)
        XCTAssertFalse(harness.audioSession.setActiveCalls.contains(true))
        XCTAssertEqual(harness.locationProvider.startCallCount, 0)
    }

    func testSuccessfulAuthorizationGateSupersededStartTerminalizesBeforeAlertSetting() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized, notificationAuthorizationStatus: .notDetermined)
        let publications = self.capturePublications(in: harness)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.requestAuthorizationGate = gate
        harness.notificationScheduler.requestAuthorizationResult = .authorized

        harness.engine.start()
        await self.waitForGate(gate)
        harness.engine.stop()
        await self.advanceNotificationGate(gate, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.requestAuthorizationGate)
        await harness.engine.settled()

        try self.assertSupersededStartTerminal(
            in: harness,
            publications: publications,
            recorderStops: 0,
            audioWasActivated: false
        )
        XCTAssertFalse(harness.notificationScheduler.calls.contains(.alertSetting))
    }

    func testFirstAlertSettingGateSupersededStartTerminalizesBeforeResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let publications = self.capturePublications(in: harness)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.alertSettingGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        harness.engine.stop()
        await self.advanceNotificationGate(gate, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.alertSettingGate)
        await harness.engine.settled()

        try self.assertSupersededStartTerminal(
            in: harness,
            publications: publications,
            recorderStops: 0,
            audioWasActivated: false
        )
    }

    func testPostRecorderAuthorizationGateSupersededStartTerminalizesResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let publications = self.capturePublications(in: harness)
        let firstAuthorization = WatchCaptureHoldGate()
        let firstAlert = WatchCaptureHoldGate()
        let postAuthorization = WatchCaptureHoldGate()
        harness.notificationScheduler.authorizationStatusGate = firstAuthorization
        harness.notificationScheduler.alertSettingGate = firstAlert

        harness.engine.start()
        await self.advanceNotificationGate(firstAuthorization, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.authorizationStatusGate)
        await self.waitForGate(firstAlert)
        harness.notificationScheduler.authorizationStatusGate = postAuthorization
        await self.advanceNotificationGate(firstAlert, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.alertSettingGate)
        await self.waitForGate(postAuthorization)
        XCTAssertEqual(harness.notificationScheduler.calls.filter { $0 == .authorizationStatus }.count, 2)
        harness.engine.stop()
        await self.advanceNotificationGate(postAuthorization, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.authorizationStatusGate)
        await harness.engine.settled()

        try self.assertSupersededStartTerminal(
            in: harness,
            publications: publications,
            recorderStops: 1,
            audioWasActivated: true
        )
    }

    func testPostRecorderAlertSettingGateSupersededStartTerminalizesResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let publications = self.capturePublications(in: harness)
        let firstAuthorization = WatchCaptureHoldGate()
        let firstAlert = WatchCaptureHoldGate()
        let postAlert = WatchCaptureHoldGate()
        harness.notificationScheduler.authorizationStatusGate = firstAuthorization
        harness.notificationScheduler.alertSettingGate = firstAlert

        harness.engine.start()
        await self.advanceNotificationGate(firstAuthorization, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.authorizationStatusGate)
        await self.advanceNotificationGate(firstAlert, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.alertSettingGate, rearmWith: postAlert)
        await self.waitForGate(postAlert)
        XCTAssertEqual(harness.notificationScheduler.calls.filter { $0 == .alertSetting }.count, 2)
        harness.engine.stop()
        await self.advanceNotificationGate(postAlert, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.alertSettingGate)
        await harness.engine.settled()

        try self.assertSupersededStartTerminal(
            in: harness,
            publications: publications,
            recorderStops: 1,
            audioWasActivated: true
        )
    }

    func testLeaseAddSuccessGateSupersededStartTerminalizesResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let publications = self.capturePublications(in: harness)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        harness.engine.start()
        await self.waitForGate(gate)
        harness.engine.stop()
        await self.advanceNotificationGate(gate, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.addGate)
        await harness.engine.settled()

        try self.assertSupersededStartTerminal(
            in: harness,
            publications: publications,
            recorderStops: 1,
            audioWasActivated: true
        )
    }

    func testLeaseAddFailureGateSupersededStartTerminalizesResources() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let publications = self.capturePublications(in: harness)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate
        harness.notificationScheduler.addError = NSError(domain: "WatchCaptureTests.notification", code: 2)

        harness.engine.start()
        await self.waitForGate(gate)
        harness.engine.stop()
        await self.advanceNotificationGate(gate, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.addGate)
        await harness.engine.settled()

        try self.assertSupersededStartTerminal(
            in: harness,
            publications: publications,
            recorderStops: 1,
            audioWasActivated: true
        )
    }

    func testReconcileNoticeGateDefersStartUntilTerminalFactsSettle() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        let prior = WatchCaptureSessionRecord(
            sessionID: "reconcile-prior",
            startedAt: harness.clock.now().addingTimeInterval(-30),
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try harness.storage.writeSessionRecord(prior)
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        harness.engine.reconcileOnLaunch()
        await self.waitForGate(gate)
        let waiting = await gate.waiting()
        XCTAssertTrue(waiting)
        harness.engine.start()
        XCTAssertTrue(harness.recorder.startURLs.isEmpty)

        harness.notificationScheduler.addGate = nil
        await gate.release()
        await harness.engine.settled()

        let current = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertNotEqual(current.sessionID, prior.sessionID)
        XCTAssertEqual(current.state, .active)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else {
            return XCTFail("history unreadable")
        }
        XCTAssertEqual(entries.first { $0.sessionID == prior.sessionID }?.terminalReason, .processExitedWhileActive)
        XCTAssertFalse(try harness.storage.scanManifests().contains {
            $0.manifest.failureReason == WatchCaptureTerminalReason.processExitedWhileActive.observerError.message
        })
    }

    func testReconcileNoticeGateHoldsStartBeforeManifestScan() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let prior = WatchCaptureSessionRecord(
            sessionID: "reconcile-prior",
            startedAt: harness.clock.now().addingTimeInterval(-30),
            state: .active,
            terminalReason: nil,
            terminalDisposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try harness.storage.writeSessionRecord(prior)
        let residueDirectory = try self.writeManifest(
            storage: harness.storage,
            startedAt: harness.clock.now().addingTimeInterval(-60),
            state: .captured,
            sensors: [.audio]
        )
        try Data("aac".utf8).write(to: harness.storage.audioURL(directory: residueDirectory))
        let gate = WatchCaptureHoldGate()
        var presentations: [WatchCaptureOwnerPresentation] = []
        harness.engine.onPresentationChanged = { presentations.append($0) }
        harness.notificationScheduler.addGate = gate

        harness.engine.reconcileOnLaunch()
        await self.waitForGate(gate)
        let reconciliationNoticeIsHeld = await gate.waiting()
        XCTAssertTrue(reconciliationNoticeIsHeld)
        harness.engine.start()

        // The reconciliation notice is suspended before the manifest scan, so
        // crash residue must remain captured throughout this hold.
        XCTAssertTrue(presentations.isEmpty)
        XCTAssertEqual(try harness.storage.readSessionRecord()?.sessionID, prior.sessionID)
        XCTAssertEqual(try harness.storage.readSessionRecord()?.state, .terminal)
        let history = WatchCaptureSessionHistoryStore(storage: harness.storage)
        XCTAssertNil(history.readCounter())
        guard case let .available(heldHistory) = history.read(asOf: harness.clock.now()) else {
            return XCTFail("history unreadable")
        }
        XCTAssertEqual(heldHistory.map(\.sessionID), [prior.sessionID])
        XCTAssertTrue(harness.recorder.startURLs.isEmpty)
        XCTAssertEqual(harness.locationProvider.startCallCount, 0)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
        XCTAssertEqual(self.pendingSleeperCount(in: harness.clock), 0)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        let heldManifests = try harness.storage.scanManifests()
        XCTAssertEqual(Set(heldManifests.map(\.directoryURL)), Set([residueDirectory]))
        XCTAssertEqual(try XCTUnwrap(heldManifests.first).manifest.state, .captured)

        await self.advanceNotificationGate(gate, scheduler: harness.notificationScheduler, keyPath: \MockWatchNotificationScheduler.addGate)
        await harness.engine.settled()

        let current = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertNotEqual(current.sessionID, prior.sessionID)
        XCTAssertEqual(current.state, .active)
        XCTAssertEqual(harness.recorder.startURLs.count, 1)
        XCTAssertEqual(harness.locationProvider.startCallCount, 1)
        XCTAssertEqual(history.readCounter()?.lifetimeSessionsStarted, 1)
        XCTAssertEqual(try harness.storage.scanManifests().filter { $0.manifest.state == .persisted }.count, 1)
        guard case let .available(entries) = history.read(asOf: harness.clock.now()) else {
            return XCTFail("history unreadable")
        }
        XCTAssertEqual(entries.first { $0.sessionID == prior.sessionID }?.terminalReason, .processExitedWhileActive)
        XCTAssertNil(entries.first { $0.sessionID == current.sessionID }?.terminalReason)
        XCTAssertNil(entries.first { $0.sessionID == current.sessionID }?.terminalDisposition)
    }

    func testTerminalizeTearsDownBeforeNoticeGateAndFirstClaimWins() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        let source = try XCTUnwrap(harness.recorder.startSources.last)
        harness.recorder.eventSink?.audioRecorderDidFinish(successfully: false, source: source)
        await self.waitForGate(gate)
        let noticeWaiting = await gate.waiting()
        XCTAssertTrue(noticeWaiting)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(harness.audioSession.setActiveCalls.last, false)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)

        harness.recorder.eventSink?.audioRecorderEncodeError(nil, source: source)
        await gate.release()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
    }

    func testReverseDetectedClaimAndOwnerStopKeepTheirFirstTerminalFacts() async throws {
        let detected = try self.makeHarness(locationAuthorization: .authorized)
        detected.engine.start(); await detected.engine.settled()
        let detectedSource = try XCTUnwrap(detected.recorder.startSources.last)
        detected.recorder.eventSink?.audioRecorderEncodeError(nil, source: detectedSource)
        detected.recorder.eventSink?.audioRecorderDidFinish(successfully: false, source: detectedSource)
        await detected.engine.settled()

        let detectedRecord = try XCTUnwrap(try detected.storage.readSessionRecord())
        XCTAssertEqual(detectedRecord.terminalReason, .audioEncodeError)
        XCTAssertEqual(detectedRecord.terminalDisposition, .detectedStoppedItself)
        XCTAssertNotNil(detectedRecord.terminalAt)
        XCTAssertEqual(detected.recorder.stopCallCount, 1)
        XCTAssertEqual(detected.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)

        let owner = try self.makeHarness(locationAuthorization: .authorized)
        owner.engine.start(); await owner.engine.settled()
        owner.engine.stop()
        let ownerSource = try XCTUnwrap(owner.recorder.startSources.last)
        owner.recorder.eventSink?.audioRecorderDidFinish(successfully: false, source: ownerSource)
        await owner.engine.settled()

        let ownerRecord = try XCTUnwrap(try owner.storage.readSessionRecord())
        XCTAssertEqual(ownerRecord.terminalReason, .ownerStopped)
        XCTAssertEqual(ownerRecord.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(ownerRecord.terminalAt)
        XCTAssertEqual(owner.recorder.stopCallCount, 1)
        XCTAssertEqual(owner.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 0)
    }

    func testTerminalizeContinuesCleanupWhenRecorderStopThrows() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        harness.engine.start(); await harness.engine.settled()
        harness.recorder.stopError = NSError(domain: "WatchCaptureTests.recorder", code: 1)

        harness.engine.stop()
        await harness.engine.settled()

        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(harness.audioSession.setActiveCalls.last, false)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
    }

    func testTerminalDurabilityAttemptsBothStoresIndependently() async throws {
        let sessionOnly = FailingWatchFileWriter(failAppend: false)
        let first = try self.makeHarness(locationAuthorization: .denied, fileWriter: sessionOnly)
        first.engine.start(); await first.engine.settled()
        sessionOnly.failNextAtomicReplace(at: first.storage.sessionRecordURL())
        first.engine.stop(); await first.engine.settled()

        let firstHistoryURL = first.storage.rootURL.appendingPathComponent(
            WatchCaptureSessionHistoryStore.historyFileName,
            isDirectory: false
        )
        XCTAssertTrue(sessionOnly.atomicReplaceURLs.contains(firstHistoryURL))
        XCTAssertEqual(first.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        let sessionOnlyNotices = first.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count
        let repairedEngine = WatchCaptureEngine(
            audioRecorder: first.recorder,
            audioSession: first.audioSession,
            locationProvider: first.locationProvider,
            storage: first.storage,
            clock: first.clock,
            audioProbe: first.audioProbe,
            notificationScheduler: first.notificationScheduler,
            notificationCenter: first.notificationCenter
        )
        repairedEngine.reconcileOnLaunch(); await repairedEngine.settled()
        let repaired = try XCTUnwrap(try first.storage.readSessionRecord())
        XCTAssertEqual(repaired.state, .terminal)
        XCTAssertEqual(repaired.terminalReason, .ownerStopped)
        XCTAssertEqual(first.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, sessionOnlyNotices)

        let historyMerge = FailingWatchFileWriter(failAppend: false)
        let merged = try self.makeHarness(locationAuthorization: .denied, fileWriter: historyMerge)
        merged.engine.start(); await merged.engine.settled()
        let mergedHistoryURL = merged.storage.rootURL.appendingPathComponent(
            WatchCaptureSessionHistoryStore.historyFileName,
            isDirectory: false
        )
        historyMerge.failAtomicReplace(at: mergedHistoryURL, ordinal: 2)
        merged.engine.stop(); await merged.engine.settled()
        let mergedTerminal = try XCTUnwrap(try merged.storage.readSessionRecord())
        let mergedHistory = WatchCaptureSessionHistoryStore(storage: merged.storage)
        let mergedEntry = try XCTUnwrap(mergedHistory.entry(sessionID: mergedTerminal.sessionID, asOf: merged.clock.now()))
        XCTAssertEqual(mergedEntry.terminalReason, mergedTerminal.terminalReason)
        XCTAssertEqual(mergedEntry.terminalDisposition, mergedTerminal.terminalDisposition)
        XCTAssertEqual(mergedEntry.terminalAt, mergedTerminal.terminalAt)

        let historyOnly = FailingWatchFileWriter(failAppend: false)
        let second = try self.makeHarness(locationAuthorization: .denied, fileWriter: historyOnly)
        second.engine.start(); await second.engine.settled()
        let secondHistoryURL = second.storage.rootURL.appendingPathComponent(
            WatchCaptureSessionHistoryStore.historyFileName,
            isDirectory: false
        )
        historyOnly.failAtomicReplace(at: secondHistoryURL, ordinal: 2)
        historyOnly.failAtomicReplace(at: secondHistoryURL, ordinal: 3)
        second.engine.stop(); await second.engine.settled()

        let terminal = try XCTUnwrap(try second.storage.readSessionRecord())
        XCTAssertEqual(terminal.terminalReason, .ownerStopped)
        XCTAssertEqual(terminal.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(terminal.terminalAt)
        XCTAssertEqual(second.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        let historyOnlyNotices = second.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count
        let historyRepairedEngine = WatchCaptureEngine(
            audioRecorder: second.recorder,
            audioSession: second.audioSession,
            locationProvider: second.locationProvider,
            storage: second.storage,
            clock: second.clock,
            audioProbe: second.audioProbe,
            notificationScheduler: second.notificationScheduler,
            notificationCenter: second.notificationCenter
        )
        historyRepairedEngine.reconcileOnLaunch(); await historyRepairedEngine.settled()
        XCTAssertEqual(second.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, historyOnlyNotices)
        let repairedHistory = WatchCaptureSessionHistoryStore(storage: second.storage)
        let repairedEntry = try XCTUnwrap(repairedHistory.entry(sessionID: terminal.sessionID, asOf: second.clock.now()))
        XCTAssertEqual(repairedEntry.terminalReason, terminal.terminalReason)
        XCTAssertEqual(repairedEntry.terminalDisposition, terminal.terminalDisposition)
        XCTAssertEqual(repairedEntry.terminalAt, terminal.terminalAt)
        XCTAssertEqual(repairedEntry.noticeOwed, terminal.noticeOwed)

        historyRepairedEngine.reconcileOnLaunch(); await historyRepairedEngine.settled()
        let repairedAgain = try XCTUnwrap(repairedHistory.entry(sessionID: terminal.sessionID, asOf: second.clock.now()))
        XCTAssertEqual(repairedAgain, repairedEntry)
        XCTAssertEqual(second.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, historyOnlyNotices)

        let both = FailingWatchFileWriter(failAppend: false)
        let third = try self.makeHarness(locationAuthorization: .denied, fileWriter: both)
        third.engine.start(); await third.engine.settled()
        both.failNextAtomicReplace(at: third.storage.sessionRecordURL())
        let thirdHistoryURL = third.storage.rootURL.appendingPathComponent(
            WatchCaptureSessionHistoryStore.historyFileName,
            isDirectory: false
        )
        both.failNextAtomicReplace(at: thirdHistoryURL)
        third.engine.stop(); await third.engine.settled()

        XCTAssertFalse(third.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(third.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        XCTAssertEqual(third.engine.ownerPresentation.terminalReason, .ownerStopped)
        XCTAssertEqual(third.engine.ownerPresentation.terminalDisposition, .ownerStopped)
    }

    func testRolloverEnsureDirectoryFailureTerminalizesWithoutSuccessor() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        let successor = self.successorDirectory(in: harness)
        try harness.storage.fileWriter.createDirectory(at: successor)

        harness.clock.advance(by: 300)
        await self.drain(until: { !harness.engine.ownerPresentation.isSessionRunning })
        await harness.engine.settled()

        try self.assertTerminalRolloverFailure(in: harness, successorStarts: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: successor.path))
        XCTAssertEqual(try harness.storage.scanManifests().filter { $0.manifest.state == .queued }.count, 1)
    }

    func testRolloverFirstManifestFailureDeletesProvenEmptySuccessor() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: writer)
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        let successor = self.successorDirectory(in: harness)
        writer.failWriteData(at: harness.storage.manifestURL(directory: successor), ordinal: 1)

        harness.clock.advance(by: 300)
        await self.drain(until: { !harness.engine.ownerPresentation.isSessionRunning })
        await harness.engine.settled()

        try self.assertTerminalRolloverFailure(in: harness, successorStarts: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: successor.path))
        XCTAssertTrue(writer.removeItemURLs.contains(successor))
    }

    func testRolloverRecorderStartFailureRetainsOnlyMediaThatCannotBeProvenEmpty() async throws {
        let zeroWriter = FailingWatchFileWriter(failAppend: false)
        let zero = try self.makeHarness(locationAuthorization: .denied, fileWriter: zeroWriter)
        zero.engine.start(); await zero.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: zero.clock) >= 2 })
        let zeroSuccessor = self.successorDirectory(in: zero)
        zero.recorder.startError = NSError(domain: "WatchCaptureTests.recorder", code: 1)
        zero.clock.advance(by: 300)
        await self.drain(until: { !zero.engine.ownerPresentation.isSessionRunning })
        await zero.engine.settled()

        try self.assertTerminalRolloverFailure(in: zero, successorStarts: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zeroSuccessor.path))
        XCTAssertTrue(zeroWriter.removeItemURLs.contains(zeroSuccessor))

        let bytesWriter = FailingWatchFileWriter(failAppend: false)
        let bytes = try self.makeHarness(locationAuthorization: .denied, fileWriter: bytesWriter)
        bytes.engine.start(); await bytes.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: bytes.clock) >= 2 })
        let bytesSuccessor = self.successorDirectory(in: bytes)
        let bytesAudioURL = bytes.storage.audioURL(directory: bytesSuccessor)
        bytes.recorder.startError = NSError(domain: "WatchCaptureTests.recorder", code: 2)
        bytes.recorder.writesBeforeStartError = true
        bytes.clock.advance(by: 300)
        await self.drain(until: { !bytes.engine.ownerPresentation.isSessionRunning })
        await bytes.engine.settled()

        try self.assertTerminalRolloverFailure(in: bytes, successorStarts: 1)
        XCTAssertFalse(bytesWriter.removeItemURLs.contains(bytesSuccessor))
        let retainedBytes = try XCTUnwrap(try bytes.storage.scanManifests().first {
            $0.manifest.startedAt == bytes.clock.now()
        })
        XCTAssertEqual(try bytesWriter.fileSize(at: bytes.storage.audioURL(directory: retainedBytes.directoryURL)), 5)
        XCTAssertTrue(retainedBytes.manifest.sensors.contains(.audio))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bytesAudioURL.path))

        let unknownWriter = FailingWatchFileWriter(failAppend: false)
        let unknown = try self.makeHarness(locationAuthorization: .denied, fileWriter: unknownWriter)
        unknown.engine.start(); await unknown.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: unknown.clock) >= 2 })
        let unknownSuccessor = self.successorDirectory(in: unknown)
        unknown.recorder.startError = NSError(domain: "WatchCaptureTests.recorder", code: 3)
        unknownWriter.failFileSize(at: unknown.storage.audioURL(directory: unknownSuccessor))
        unknown.clock.advance(by: 300)
        await self.drain(until: { !unknown.engine.ownerPresentation.isSessionRunning })
        await unknown.engine.settled()

        try self.assertTerminalRolloverFailure(in: unknown, successorStarts: 1)
        XCTAssertFalse(unknownWriter.removeItemURLs.contains(unknownSuccessor))
        let unknownManifestCount = try unknown.storage.scanManifests().count
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownSuccessor.path) || unknownManifestCount == 2)
    }

    func testRolloverPersistedManifestFailureStopsAndRetainsSuccessorMedia() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: writer)
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        let successor = self.successorDirectory(in: harness)
        writer.failWriteData(at: harness.storage.manifestURL(directory: successor), ordinal: 2)

        harness.clock.advance(by: 300)
        await self.drain(until: { !harness.engine.ownerPresentation.isSessionRunning })
        await harness.engine.settled()

        try self.assertTerminalRolloverFailure(in: harness, successorStarts: 2)
        XCTAssertFalse(writer.removeItemURLs.contains(successor))
        let retained = try XCTUnwrap(try harness.storage.scanManifests().first {
            $0.manifest.startedAt == harness.clock.now()
        })
        XCTAssertEqual(try writer.fileSize(at: harness.storage.audioURL(directory: retained.directoryURL)), 5)
        XCTAssertTrue(retained.manifest.sensors.contains(.audio))
    }

    func testInitialStartPersistedManifestFailureStopsRecorderAndRetainsMedia() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: writer)
        let initialDirectory = self.initialDirectory(in: harness)
        writer.failWriteData(at: harness.storage.manifestURL(directory: initialDirectory), ordinal: 2)

        harness.engine.start()
        await harness.engine.settled()

        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertFalse(harness.recorder.isRecording)
        XCTAssertEqual(harness.audioSession.setActiveCalls.last, false)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.engine.ownerPresentation.startRefusalReason, .audioArmFailed)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordWriteFailed)
        XCTAssertNil(try harness.storage.readSessionRecord())
        let retained = try XCTUnwrap(try harness.storage.scanManifests().first)
        XCTAssertEqual(try writer.fileSize(at: harness.storage.audioURL(directory: retained.directoryURL)), 5)
    }

    func testStopSupersedesSuspendedRolloverWithoutLeaseOrObservingPublication() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        harness.clock.advance(by: 300)
        await self.waitForGate(gate)
        let waiting = await gate.waiting()
        XCTAssertTrue(waiting)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        harness.engine.stop()
        statuses.removeAll()
        await gate.release()
        await harness.engine.settled()

        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertEqual(harness.recorder.stopCallCount, 2)
        XCTAssertEqual(harness.audioSession.setActiveCalls.last, false)
        XCTAssertFalse(statuses.contains { $0.phase == .observing })
        XCTAssertEqual(try harness.storage.scanManifests().filter { $0.manifest.state == .queued }.count, 2)
    }

    func testQueuedRolloverDoesNotConsumeItsNextCadenceWake() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        harness.engine.start(); await harness.engine.settled()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        let gate = WatchCaptureHoldGate()
        harness.notificationScheduler.addGate = gate

        harness.clock.advance(by: 300)
        await self.waitForGate(gate)
        XCTAssertEqual(harness.recorder.startURLs.count, 2)

        harness.clock.advance(by: 300)
        await Task.yield()
        XCTAssertEqual(harness.recorder.startURLs.count, 2)

        await gate.release()
        await harness.engine.settled()
        XCTAssertEqual(harness.recorder.startURLs.count, 2)
    }

    func testFinalizedUnsentSegmentsBecomeQueuedOnRelaunch() async throws {
        let harness = try self.makeHarness()
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .finalized,
            sensors: [.audio]
        )

        harness.engine.reconcileOnLaunch(); await harness.engine.settled()

        let manifest = try XCTUnwrap(harness.storage.scanManifests().first?.manifest)
        XCTAssertEqual(manifest.state, .queued)
    }

    func testOwnerStateMappingSeparatesPendingFromAttention() {
        XCTAssertEqual(watchSourceState(for: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0)).0, .off)
        XCTAssertEqual(watchSourceState(for: WatchCaptureOwnerPresentation(status: .enrolling, queuedCount: 0)).0, .enrolling)
        XCTAssertEqual(watchSourceState(for: WatchCaptureOwnerPresentation(status: .active, queuedCount: 0)).0, .active)
        let pending = WatchCaptureOwnerPresentation(status: .off, queuedCount: 1)
        XCTAssertEqual(watchSourceState(for: pending).0, .off)
        XCTAssertNil(watchSourceState(for: pending).1)
        XCTAssertEqual(pending.headline, "saved on your watch")
        XCTAssertEqual(pending.countsLine, "1 saved on your watch")
        XCTAssertNil(pending.attentionLine)

        let attention = watchSourceState(for: WatchCaptureOwnerPresentation(status: .needsAttention(.diskFull), queuedCount: 0))
        XCTAssertEqual(attention.0, .needsAttention)
        XCTAssertEqual(attention.1, SourceAttention(message: "storage is full"))

        let attentionWithQueue = WatchCaptureOwnerPresentation(status: .needsAttention(.diskFull), queuedCount: 1)
        XCTAssertEqual(attentionWithQueue.headline, "storage is full")
        XCTAssertEqual(attentionWithQueue.countsLine, "1 saved on your watch")
        XCTAssertEqual(attentionWithQueue.attentionLine, "storage is full")
        XCTAssertEqual(watchSourceState(for: attentionWithQueue).0, .needsAttention)
    }

    func testOwnerPresentationHeadlineCountsAndLink() {
        let active = WatchCaptureOwnerPresentation(status: .active, queuedCount: 0, isSessionRunning: true)
        XCTAssertEqual(active.headline, "on")
        XCTAssertNil(active.countsLine)
        XCTAssertNil(active.attentionLine)

        let queued = WatchCaptureOwnerPresentation(status: .off, queuedCount: 2)
        XCTAssertEqual(queued.headline, "saved on your watch")
        XCTAssertEqual(queued.countsLine, "2 saved on your watch")

        let transferring = WatchCaptureOwnerPresentation(status: .off, queuedCount: 2, transferringCount: 1)
        XCTAssertEqual(transferring.headline, "sending")
        XCTAssertEqual(transferring.countsLine, "1 sending · 2 saved on your watch")

        let confirming = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, confirmingCount: 1)
        XCTAssertEqual(confirming.headline, "confirming with your iphone")
        XCTAssertEqual(confirming.countsLine, "1 confirming with your iphone")

        let handedOff = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, handedOffCount: 1)
        XCTAssertEqual(handedOff.headline, "handed to your iphone")
        XCTAssertEqual(handedOff.countsLine, "1 handed to your iphone")

        let attention = WatchCaptureOwnerPresentation(
            status: .needsAttention(.diskFull),
            queuedCount: 1,
            transferringCount: 1,
            confirmingCount: 1,
            handedOffCount: 1
        )
        XCTAssertEqual(attention.headline, "storage is full")
        XCTAssertEqual(attention.countsLine, "1 sending · 1 saved on your watch · 1 confirming with your iphone · 1 handed to your iphone")
        XCTAssertEqual(attention.attentionLine, "storage is full")

        let off = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, isSessionRunning: false)
        XCTAssertEqual(off.headline, "off")

        XCTAssertEqual(watchLinkLine(isReachable: true), "phone link: in range")
        XCTAssertEqual(watchLinkLine(isReachable: false), "phone link: out of range")

        let renderedStrings = [
            active.headline, active.countsLine, active.attentionLine,
            queued.headline, queued.countsLine, queued.attentionLine,
            transferring.headline, transferring.countsLine, transferring.attentionLine,
            confirming.headline, confirming.countsLine, confirming.attentionLine,
            handedOff.headline, handedOff.countsLine, handedOff.attentionLine,
            attention.headline, attention.countsLine, attention.attentionLine,
            off.headline, off.countsLine, off.attentionLine,
        ].compactMap(\.self)
        for rendered in renderedStrings {
            XCTAssertFalse(rendered.contains("waiting"))
            XCTAssertFalse(rendered.contains("in your journal"))
        }
    }

    func testManifestAndLocationSchemas() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        harness.engine.start(); await harness.engine.settled()
        harness.locationProvider.emitFix(Self.fix(alt: nil, vAcc: nil, speed: nil, course: nil))
        harness.engine.stop(); await harness.engine.settled()

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        XCTAssertNotNil(entry.manifest.segment.range(of: #"^\d{6}_\d+$"#, options: .regularExpression))
        let manifestString = String(decoding: try Data(contentsOf: entry.manifestURL), as: UTF8.self)
        XCTAssertTrue(manifestString.contains(#""started_at":"#))
        XCTAssertTrue(manifestString.contains(#""fix_count":"#))

        let lines = try self.jsonLines(at: harness.storage.locationURL(directory: entry.directoryURL))
        let header = try XCTUnwrap(lines.first)
        XCTAssertEqual(Set(header.keys), ["schema", "kind", "source", "platform", "tier", "accuracy", "fix_count", "gap"])
        let fix = try XCTUnwrap(lines.dropFirst().first)
        XCTAssertEqual(Set(fix.keys), ["schema", "t", "lat", "lon", "h_acc", "alt", "v_acc", "speed", "course", "stationary"])
        XCTAssertEqual(fix["schema"] as? String, "solstone.location.fix/1")
        XCTAssertTrue(fix["alt"] is NSNull)
        XCTAssertTrue(fix["v_acc"] is NSNull)
        XCTAssertTrue(fix["speed"] is NSNull)
        XCTAssertTrue(fix["course"] is NSNull)
    }

    func testConservativeDeclarationsPersistAtAudioAndLocationSeams() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .authorized, fileWriter: writer)
        let directory = self.initialDirectory(in: harness)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = 12.3
        var audioStartManifest: WatchSegmentManifest?
        var locationCreateManifest: WatchSegmentManifest?
        harness.recorder.startObservation = { _, _ in
            audioStartManifest = try? harness.storage.scanManifests().first?.manifest
        }
        writer.writeDataObservations[locationURL.path] = {
            locationCreateManifest = try? harness.storage.scanManifests().first?.manifest
        }

        harness.engine.start(); await harness.engine.settled()

        let persisted = try XCTUnwrap(try harness.storage.scanManifests().first?.manifest)
        for manifest in [try XCTUnwrap(audioStartManifest), try XCTUnwrap(locationCreateManifest)] {
            XCTAssertEqual(manifest.state, .captured)
            XCTAssertEqual(manifest.id, persisted.id)
            XCTAssertEqual(manifest.sensors, [.audio, .location])
            XCTAssertEqual(manifest.sensors.count, 2)
        }
        harness.engine.stop(); await harness.engine.settled()
    }

    func testSecondManifestFailureRetainsOneConservativeResidueAcrossRelaunch() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .authorized, fileWriter: writer)
        let directory = self.initialDirectory(in: harness)
        let manifestURL = harness.storage.manifestURL(directory: directory)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = 12.3
        writer.failWriteData(at: manifestURL, ordinal: 2)
        var firstManifest: WatchSegmentManifest?
        harness.recorder.startObservation = { _, _ in
            firstManifest = try? harness.storage.scanManifests().first?.manifest
        }

        harness.engine.start(); await harness.engine.settled()

        let originalID = try XCTUnwrap(firstManifest?.id)
        let originalAudio = try Data(contentsOf: audioURL)
        let originalLocation = try Data(contentsOf: locationURL)
        XCTAssertEqual(harness.recorder.stopCallCount, 1)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertEqual(try harness.storage.scanManifests().count, 1)

        let relaunch = WatchCaptureEngine(
            audioRecorder: MockWatchAudioRecorder(microphonePermission: .granted),
            audioSession: MockWatchAudioSession(),
            locationProvider: MockWatchLocationProvider(authorizationStatus: .authorized),
            storage: harness.storage,
            clock: harness.clock,
            audioProbe: harness.audioProbe,
            notificationScheduler: MockWatchNotificationScheduler(authorizationStatus: .authorized, alertSetting: .enabled),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider(),
            notificationCenter: NotificationCenter()
        )
        relaunch.reconcileOnLaunch(); await relaunch.settled()

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.manifest.id, originalID)
        XCTAssertEqual(entry.manifest.state, .queued)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertEqual(entry.manifest.sensors, [.audio, .location])
        XCTAssertEqual(entry.manifest.sensors.count, 2)
        XCTAssertEqual(entry.manifest.duration, 12.3, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: harness.storage.audioURL(directory: entry.directoryURL)), originalAudio)
        XCTAssertEqual(try Data(contentsOf: harness.storage.locationURL(directory: entry.directoryURL)), originalLocation)
        XCTAssertTrue(writer.atomicReplaceURLs.contains(locationURL))
    }

    func testConservativeDeclarationsPreserveOrdinarySuccess() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let audioURL = harness.storage.audioURL(directory: self.initialDirectory(in: harness))
        harness.audioProbe.durations[audioURL.path] = 12.3

        harness.engine.start(); await harness.engine.settled()
        let openedID = try XCTUnwrap(try harness.storage.scanManifests().first?.manifest.id)
        harness.locationProvider.emitFix(Self.fix())
        harness.engine.stop(); await harness.engine.settled()

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.manifest.id, openedID)
        XCTAssertEqual(Set(entry.manifest.sensors), [.audio, .location])
        XCTAssertEqual(entry.manifest.sensors.count, 2)
        XCTAssertNotNil(entry.manifest.segment.range(of: #"^\d{6}_\d+$"#, options: .regularExpression))
        XCTAssertEqual(try self.jsonLines(at: harness.storage.locationURL(directory: entry.directoryURL)).first?["schema"] as? String, "solstone.location.segment/1")
    }

    func testProvenAbsentLocationDropsOnlyLocationDeclaration() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .authorized, fileWriter: writer)
        let directory = self.initialDirectory(in: harness)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = 12.3
        writer.failWriteData(at: locationURL, ordinal: 1)

        harness.engine.start(); await harness.engine.settled()
        XCTAssertTrue(harness.engine.ownerPresentation.isSessionRunning)
        let originalAudio = try Data(contentsOf: audioURL)
        harness.engine.stop(); await harness.engine.settled()

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertEqual(entry.manifest.sensors, [.audio])
        XCTAssertEqual(try Data(contentsOf: harness.storage.audioURL(directory: entry.directoryURL)), originalAudio)
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: harness.storage.locationURL(directory: entry.directoryURL)))
    }

    func testProvisionalLocationHeaderSurvivesCarryForwardAppendFailure() async throws {
        let writer = FailingWatchFileWriter(failAppend: true)
        let harness = try self.makeHarness(locationAuthorization: .authorized, fileWriter: writer)
        let directory = self.initialDirectory(in: harness)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = 12.3
        harness.recorder.startObservation = { _, _ in
            harness.locationProvider.emitFix(Self.fix())
        }

        harness.engine.start(); await harness.engine.settled()

        let openingID = try XCTUnwrap(try harness.storage.scanManifests().first?.manifest.id)
        XCTAssertTrue(harness.storage.fileWriter.fileExists(at: locationURL))
        let originalAudio = try Data(contentsOf: audioURL)

        harness.engine.stop(); await harness.engine.settled()

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        let retainedAudioURL = harness.storage.audioURL(directory: entry.directoryURL)
        let retainedLocationURL = harness.storage.locationURL(directory: entry.directoryURL)
        XCTAssertEqual(entry.manifest.id, openingID)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertEqual(Set(entry.manifest.sensors), [.audio, .location])
        XCTAssertEqual(entry.manifest.sensors.count, 2)
        XCTAssertEqual(entry.manifest.fixCount, 0)
        XCTAssertTrue(entry.manifest.gap)
        XCTAssertEqual(try Data(contentsOf: retainedAudioURL), originalAudio)
        XCTAssertTrue(harness.storage.fileWriter.fileExists(at: retainedLocationURL))
        let header = try XCTUnwrap(self.jsonLines(at: retainedLocationURL).first)
        XCTAssertEqual(header["fix_count"] as? Int, 0)
        XCTAssertEqual(header["gap"] as? Bool, true)
        XCTAssertTrue(writer.atomicReplaceURLs.contains(locationURL))
    }

    func testProvenAbsentAudioDropsWholeResidueWithoutLocationSideEffects() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .authorized, fileWriter: writer)
        let directory = self.initialDirectory(in: harness)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = .some(nil)
        harness.recorder.startError = NSError(domain: "WatchCaptureTests.recorder", code: 1)
        var startCalls = 0
        var originalID: UUID?
        harness.recorder.startObservation = { _, _ in
            startCalls += 1
            originalID = try? harness.storage.scanManifests().first?.manifest.id
        }

        harness.engine.start(); await harness.engine.settled()
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertFalse(writer.writeDataURLs.contains(locationURL))
        XCTAssertFalse(writer.appendLineURLs.contains(locationURL))
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: audioURL))
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: locationURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let relaunch = WatchCaptureEngine(
            audioRecorder: MockWatchAudioRecorder(microphonePermission: .granted), audioSession: MockWatchAudioSession(),
            locationProvider: MockWatchLocationProvider(authorizationStatus: .authorized), storage: harness.storage,
            clock: harness.clock, audioProbe: harness.audioProbe,
            notificationScheduler: MockWatchNotificationScheduler(authorizationStatus: .authorized, alertSetting: .enabled),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider(), notificationCenter: NotificationCenter()
        )
        relaunch.reconcileOnLaunch(); await relaunch.settled()

        XCTAssertTrue(try harness.storage.scanManifests().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(originalID)
    }

    func testCrashAtDeclarationBoundaryRemovesFullyAbsentResidue() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .authorized, fileWriter: writer)
        let directory = self.initialDirectory(in: harness)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = .some(nil)
        let imageURL = self.tempDirectory.appendingPathComponent("declaration-boundary", isDirectory: true)
        var capturedID: UUID?
        harness.recorder.startObservation = { _, _ in
            capturedID = try? harness.storage.scanManifests().first?.manifest.id
            XCTAssertTrue(harness.recorder.startURLs.isEmpty)
            XCTAssertFalse(writer.writeDataURLs.contains(locationURL))
            XCTAssertFalse(writer.appendLineURLs.contains(locationURL))
            try? FileManager.default.copyItem(at: harness.storage.rootURL, to: imageURL)
        }

        harness.engine.start(); await harness.engine.settled()

        let imageStorage = try WatchCaptureStorage(rootURL: imageURL)
        let imageEntries = try imageStorage.scanManifests()
        XCTAssertEqual(imageEntries.count, 1)
        let imageEntry = try XCTUnwrap(imageEntries.first)
        XCTAssertEqual(imageEntry.manifest.id, capturedID)
        XCTAssertEqual(imageEntry.manifest.state, .captured)
        XCTAssertEqual(imageEntry.manifest.sensors, [.audio, .location])
        XCTAssertEqual(imageEntry.manifest.sensors.count, 2)
        XCTAssertFalse(imageStorage.fileWriter.fileExists(at: imageStorage.audioURL(directory: imageEntry.directoryURL)))
        XCTAssertFalse(imageStorage.fileWriter.fileExists(at: imageStorage.locationURL(directory: imageEntry.directoryURL)))

        let imageProbe = MockWatchAudioProbe()
        imageProbe.durations[imageStorage.audioURL(directory: imageEntry.directoryURL).path] = .some(nil)
        let relaunch = WatchCaptureEngine(
            audioRecorder: MockWatchAudioRecorder(microphonePermission: .granted), audioSession: MockWatchAudioSession(),
            locationProvider: MockWatchLocationProvider(authorizationStatus: .authorized), storage: imageStorage,
            clock: harness.clock, audioProbe: imageProbe,
            notificationScheduler: MockWatchNotificationScheduler(authorizationStatus: .authorized, alertSetting: .enabled),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider(), notificationCenter: NotificationCenter()
        )
        relaunch.reconcileOnLaunch(); await relaunch.settled()

        XCTAssertTrue(try imageStorage.scanManifests().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageEntry.directoryURL.path))
        XCTAssertFalse(imageStorage.fileWriter.fileExists(at: imageStorage.locationURL(directory: imageEntry.directoryURL)))
    }

    func testAudioWrittenBeforeStartFailureDropsAbsentLocationOnRelaunch() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)
        let directory = self.initialDirectory(in: harness)
        let audioURL = harness.storage.audioURL(directory: directory)
        let locationURL = harness.storage.locationURL(directory: directory)
        harness.audioProbe.durations[audioURL.path] = 12.3
        harness.recorder.writesBeforeStartError = true
        harness.recorder.startError = NSError(domain: "WatchCaptureTests.recorder", code: 2)
        var originalID: UUID?
        harness.recorder.startObservation = { _, _ in
            originalID = try? harness.storage.scanManifests().first?.manifest.id
        }

        harness.engine.start(); await harness.engine.settled()

        let originalAudio = try Data(contentsOf: audioURL)
        let relaunch = WatchCaptureEngine(
            audioRecorder: MockWatchAudioRecorder(microphonePermission: .granted), audioSession: MockWatchAudioSession(),
            locationProvider: MockWatchLocationProvider(authorizationStatus: .authorized), storage: harness.storage,
            clock: harness.clock, audioProbe: harness.audioProbe,
            notificationScheduler: MockWatchNotificationScheduler(authorizationStatus: .authorized, alertSetting: .enabled),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider(), notificationCenter: NotificationCenter()
        )
        relaunch.reconcileOnLaunch(); await relaunch.settled()

        let entries = try harness.storage.scanManifests()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.manifest.id, originalID)
        XCTAssertEqual(entry.manifest.state, .queued)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertEqual(Set(entry.manifest.sensors), [.audio])
        XCTAssertEqual(entry.manifest.sensors.count, 1)
        XCTAssertEqual(try Data(contentsOf: harness.storage.audioURL(directory: entry.directoryURL)), originalAudio)
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: harness.storage.locationURL(directory: entry.directoryURL)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locationURL.path))
    }

    func testSegmentDirectoryCollisionsDoNotOverwriteExistingData() throws {
        let storage = try WatchCaptureStorage(
            rootURL: self.tempDirectory.appendingPathComponent("Collision-\(UUID().uuidString)", isDirectory: true)
        )
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000)
        let day = storage.dayString(for: startedAt)
        let provisional = storage.provisionalSegmentString(for: startedAt)
        let existing = try storage.ensureSegmentDirectory(day: day, segment: provisional)
        let marker = existing.appendingPathComponent("marker.txt", isDirectory: false)
        try Data("original".utf8).write(to: marker)

        XCTAssertThrowsError(try storage.ensureSegmentDirectory(day: day, segment: provisional))
        XCTAssertEqual(String(decoding: try Data(contentsOf: marker), as: UTF8.self), "original")

        let source = try storage.ensureSegmentDirectory(day: day, segment: "120000_1")
        let destination = try storage.ensureSegmentDirectory(day: day, segment: "120000_300")
        let destinationMarker = destination.appendingPathComponent("marker.txt", isDirectory: false)
        try Data("destination".utf8).write(to: destinationMarker)

        XCTAssertThrowsError(try storage.moveSegmentDirectoryIfNeeded(
            currentURL: source,
            day: day,
            currentSegment: "120000_1",
            finalSegment: "120000_300"
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(String(decoding: try Data(contentsOf: destinationMarker), as: UTF8.self), "destination")
    }
}

@MainActor
private extension WatchCaptureTests {
    struct AudioSessionNotificationCase {
        let name: Notification.Name
        let reason: WatchCaptureTerminalReason
        let userInfo: [AnyHashable: Any]?
        let makesInputUnsuitable: Bool
    }

    struct Harness {
        let engine: WatchCaptureEngine
        let recorder: MockWatchAudioRecorder
        let audioSession: MockWatchAudioSession
        let locationProvider: MockWatchLocationProvider
        let storage: WatchCaptureStorage
        let clock: MockObserverClock
        let audioProbe: MockWatchAudioProbe
        let notificationScheduler: MockWatchNotificationScheduler
        let notificationCenter: NotificationCenter
    }

    var audioSessionNotificationCases: [AudioSessionNotificationCase] {
        [
            .init(
                name: AVAudioSession.mediaServicesWereLostNotification,
                reason: .audioMediaServicesLost,
                userInfo: nil,
                makesInputUnsuitable: false
            ),
            .init(
                name: AVAudioSession.mediaServicesWereResetNotification,
                reason: .audioMediaServicesReset,
                userInfo: nil,
                makesInputUnsuitable: false
            ),
            .init(
                name: AVAudioSession.interruptionNotification,
                reason: .audioInterrupted,
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                ],
                makesInputUnsuitable: false
            ),
            .init(
                name: AVAudioSession.routeChangeNotification,
                reason: .audioRouteUnavailable,
                userInfo: nil,
                makesInputUnsuitable: true
            ),
        ]
    }

    struct ProductionAudioHarness {
        let engine: WatchCaptureEngine
        let recorder: LiveWatchAudioRecorder
        let recorders: ProductionRecorderStore
        let audioSession: MockWatchAudioSession
        let locationProvider: MockWatchLocationProvider
        let storage: WatchCaptureStorage
        let clock: MockObserverClock
        let retentionClock: FakeWatchAudioRecorderRetentionClock
        let audioProbe: MockWatchAudioProbe
        let notificationScheduler: MockWatchNotificationScheduler
        let deliveries: TerminalDeliveryProbe
    }

    func makeProductionAudioHarness(
        terminalHandoffGate: WatchCaptureHoldGate? = nil,
        synchronousTerminalHandoff: Bool = false
    ) throws -> ProductionAudioHarness {
        let recorders = ProductionRecorderStore()
        let deliveries = TerminalDeliveryProbe()
        let retentionClock = FakeWatchAudioRecorderRetentionClock()
        let recorder = LiveWatchAudioRecorder(
            recorderFactory: { url, settings in
                try recorders.makeRecorder(url: url, settings: settings)
            },
            microphonePermissionProvider: { .granted },
            retentionClock: retentionClock,
            terminalHandoff: { operation in
                if synchronousTerminalHandoff {
                    MainActor.assumeIsolated {
                        deliveries.count += 1
                        operation()
                    }
                    return
                }
                Task { @MainActor in
                    if let terminalHandoffGate {
                        await terminalHandoffGate.suspend()
                    }
                    deliveries.count += 1
                    operation()
                }
            }
        )
        let audioSession = MockWatchAudioSession()
        let locationProvider = MockWatchLocationProvider(authorizationStatus: .denied)
        let rootURL = self.tempDirectory
            .appendingPathComponent("ProductionAudioHarness-\(UUID().uuidString)", isDirectory: true)
        let storage = try WatchCaptureStorage(rootURL: rootURL)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_713_624_000))
        let audioProbe = MockWatchAudioProbe()
        let notificationScheduler = MockWatchNotificationScheduler(
            authorizationStatus: .authorized,
            alertSetting: .enabled
        )
        let engine = WatchCaptureEngine(
            audioRecorder: recorder,
            audioSession: audioSession,
            locationProvider: locationProvider,
            storage: storage,
            clock: clock,
            audioProbe: audioProbe,
            notificationScheduler: notificationScheduler,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider(),
            notificationCenter: NotificationCenter()
        )
        return ProductionAudioHarness(
            engine: engine,
            recorder: recorder,
            recorders: recorders,
            audioSession: audioSession,
            locationProvider: locationProvider,
            storage: storage,
            clock: clock,
            retentionClock: retentionClock,
            audioProbe: audioProbe,
            notificationScheduler: notificationScheduler,
            deliveries: deliveries
        )
    }

    func rolloverProductionRecorderPair(
        in harness: ProductionAudioHarness
    ) async throws -> (predecessor: WeakRecorderHandle, successor: WeakRecorderHandle) {
        harness.engine.start()
        await harness.engine.settled()
        let predecessor = try XCTUnwrap(harness.recorders.latest)
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.clock.advance(by: WatchCaptureTiming.segmentDurationSeconds)
        await self.drain(until: { harness.recorders.count == 2 })
        await harness.engine.settled()
        return (predecessor, try XCTUnwrap(harness.recorders.latest))
    }

    func assertDelayedFormerSessionCallbackIsInert(
        in harness: ProductionAudioHarness,
        former: WeakRecorderHandle,
        successor: WeakRecorderHandle,
        deliver: @MainActor (WeakRecorderHandle) -> Void
    ) async throws {
        let formerSource = try XCTUnwrap(former.forwarder).source
        let successorSource = try XCTUnwrap(successor.forwarder).source
        XCTAssertNotEqual(formerSource.sessionID, successorSource.sessionID)

        let recordBefore = try XCTUnwrap(try harness.storage.readSessionRecord())
        let storageInventoryBefore = try self.storageInventory(in: harness.storage)
        let presentationBefore = harness.engine.ownerPresentation
        let noticesBefore = harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count
        let formerTelemetryBefore = former.telemetry.snapshot
        let successorTelemetryBefore = successor.telemetry.snapshot
        XCTAssertTrue(successorTelemetryBefore.isRecording)
        let deliveriesBefore = harness.deliveries.count
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        harness.engine.onPresentationChanged = { publications.presentations.append($0) }

        deliver(former)
        await self.drain(until: { harness.deliveries.count == deliveriesBefore + 1 })
        await harness.engine.settled()

        let recordAfter = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(recordAfter, recordBefore)
        XCTAssertEqual(try self.storageInventory(in: harness.storage), storageInventoryBefore)
        XCTAssertEqual(harness.engine.ownerPresentation, presentationBefore)
        XCTAssertTrue(publications.statuses.isEmpty)
        XCTAssertTrue(publications.presentations.isEmpty)
        XCTAssertEqual(
            harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count,
            noticesBefore
        )
        XCTAssertEqual(successor.telemetry.snapshot, successorTelemetryBefore)
        XCTAssertTrue(successor.telemetry.isRecording)
        XCTAssertEqual(former.telemetry.stopCallCount, formerTelemetryBefore.stopCallCount)
        XCTAssertEqual(former.telemetry.recordCallCount, formerTelemetryBefore.recordCallCount)
        XCTAssertEqual(former.telemetry.reportedCurrentTime, formerTelemetryBefore.reportedCurrentTime)
        XCTAssertEqual(former.telemetry.isRecording, formerTelemetryBefore.isRecording)
        XCTAssertEqual(former.telemetry.deliveredCallbackCount, formerTelemetryBefore.deliveredCallbackCount + 1)
        await self.drain(until: { former.isReleased })
    }

    func assertDelayedRolloverPredecessorCallbackIsInert(
        in harness: ProductionAudioHarness,
        pair: (predecessor: WeakRecorderHandle, successor: WeakRecorderHandle),
        deliver: @MainActor (WeakRecorderHandle) -> Void
    ) async throws {
        let predecessorSource = try XCTUnwrap(pair.predecessor.forwarder).source
        let successorSource = try XCTUnwrap(pair.successor.forwarder).source
        XCTAssertEqual(predecessorSource.sessionID, successorSource.sessionID)
        XCTAssertNotNil(predecessorSource.enrollment)
        XCTAssertNotNil(successorSource.enrollment)
        XCTAssertNotEqual(predecessorSource.enrollment, successorSource.enrollment)

        let recordBefore = try XCTUnwrap(try harness.storage.readSessionRecord())
        let storageInventoryBefore = try self.storageInventory(in: harness.storage)
        let presentationBefore = harness.engine.ownerPresentation
        let noticesBefore = harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count
        let predecessorTelemetryBefore = pair.predecessor.telemetry.snapshot
        let successorTelemetryBefore = pair.successor.telemetry.snapshot
        XCTAssertTrue(successorTelemetryBefore.isRecording)
        let deliveriesBefore = harness.deliveries.count
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        harness.engine.onPresentationChanged = { publications.presentations.append($0) }

        deliver(pair.predecessor)
        await self.drain(until: { harness.deliveries.count == deliveriesBefore + 1 })
        await harness.engine.settled()

        let recordAfter = try XCTUnwrap(try harness.storage.readSessionRecord())
        let storageInventoryAfter = try self.storageInventory(in: harness.storage)
        XCTAssertEqual(recordAfter, recordBefore)
        XCTAssertEqual(storageInventoryAfter, storageInventoryBefore)
        XCTAssertEqual(harness.engine.ownerPresentation, presentationBefore)
        XCTAssertTrue(publications.statuses.isEmpty)
        XCTAssertTrue(publications.presentations.isEmpty)
        XCTAssertEqual(
            harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count,
            noticesBefore
        )
        XCTAssertEqual(pair.successor.telemetry.snapshot, successorTelemetryBefore)
        XCTAssertTrue(pair.successor.telemetry.isRecording)
        XCTAssertEqual(pair.successor.telemetry.stopCallCount, 0)
        XCTAssertNil(recordAfter.terminalReason)
        XCTAssertEqual(pair.predecessor.telemetry.stopCallCount, predecessorTelemetryBefore.stopCallCount)
        XCTAssertEqual(pair.predecessor.telemetry.recordCallCount, predecessorTelemetryBefore.recordCallCount)
        XCTAssertEqual(pair.predecessor.telemetry.reportedCurrentTime, predecessorTelemetryBefore.reportedCurrentTime)
        XCTAssertEqual(pair.predecessor.telemetry.isRecording, predecessorTelemetryBefore.isRecording)
        XCTAssertEqual(
            pair.predecessor.telemetry.deliveredCallbackCount,
            predecessorTelemetryBefore.deliveredCallbackCount + 1
        )
        await self.drain(until: { pair.predecessor.isReleased })
    }

    func storageInventory(in storage: WatchCaptureStorage) throws -> WatchCaptureStorageInventory {
        let rootURL = storage.rootURL
        let fileManager = FileManager.default

        func inventory(in directory: URL) throws -> [WatchCaptureStorageInventory.Entry] {
            // No skip options: the acceptance claim is a FULL byte-for-byte storage/media
            // inventory, so hidden files are enumerated too and any storage mutation is
            // observable. Omitting them would let a hidden-file change pass as unchanged.
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            .sorted { $0.path < $1.path }
            var entries: [WatchCaptureStorageInventory.Entry] = []
            for child in children {
                let relativePath = child.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    entries.append(.init(relativePath: relativePath, isDirectory: true, contents: nil))
                    entries += try inventory(in: child)
                } else {
                    entries.append(.init(
                        relativePath: relativePath,
                        isDirectory: false,
                        contents: try Data(contentsOf: child)
                    ))
                }
            }
            return entries
        }

        return WatchCaptureStorageInventory(entries: try inventory(in: rootURL))
    }

    func oneShotStatusAction(
        phase: WatchStatusContext.Phase,
        occurrence: Int,
        when predicate: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void
    ) -> @MainActor (WatchStatusContext) -> Void {
        var matches = 0
        var isArmed = true
        return { status in
            guard isArmed, status.phase == phase, predicate() else { return }
            matches += 1
            guard matches == occurrence else { return }
            isArmed = false
            action()
        }
    }

    func oneShotPresentationAction(
        occurrence: Int,
        when predicate: @escaping @MainActor (WatchCaptureOwnerPresentation) -> Bool,
        action: @escaping @MainActor () -> Void
    ) -> @MainActor @Sendable (WatchCaptureOwnerPresentation) -> Void {
        var matches = 0
        var isArmed = true
        return { presentation in
            guard isArmed, predicate(presentation) else { return }
            matches += 1
            guard matches == occurrence else { return }
            isArmed = false
            action()
        }
    }

    func assertOwnerStoppedTerminal(in harness: Harness, recorderStops: Int) throws {
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertEqual(harness.recorder.stopCallCount, recorderStops)
        XCTAssertFalse(harness.recorder.isRecording)
        XCTAssertEqual(harness.audioSession.setActiveCalls.filter { !$0 }.count, 1)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
    }

    func assertDetectedTerminalOnce(
        in harness: Harness,
        reason: WatchCaptureTerminalReason,
        recorderStops: Int
    ) throws {
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, reason)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertEqual(harness.recorder.stopCallCount, recorderStops)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.notificationScheduler.addCalls(identifier: WatchNoticeIdentifiers.notice).count, 1)
    }

    func assertSupersededStartTerminal(
        in harness: Harness,
        publications: WatchCapturePublicationRecord,
        recorderStops: Int,
        audioWasActivated: Bool
    ) throws {
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, .ownerStopped)
        XCTAssertEqual(record.terminalDisposition, .ownerStopped)
        XCTAssertNotNil(record.terminalAt)
        XCTAssertEqual(harness.recorder.stopCallCount, recorderStops)
        XCTAssertFalse(harness.recorder.isRecording)
        XCTAssertEqual(harness.audioSession.setActiveCalls.contains(true), audioWasActivated)
        XCTAssertEqual(harness.audioSession.setActiveCalls.filter { !$0 }.count, audioWasActivated ? 1 : 0)
        XCTAssertEqual(harness.locationProvider.startCallCount, audioWasActivated ? 1 : 0)
        XCTAssertEqual(harness.locationProvider.stopCallCount, 1)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(self.pendingSleeperCount(in: harness.clock), 0)
        XCTAssertFalse(publications.statuses.contains { $0.phase == .observing })
        XCTAssertFalse(publications.presentations.contains { $0.status == .active && $0.isSessionRunning })
    }

    func capturePublications(in harness: Harness) -> WatchCapturePublicationRecord {
        let publications = WatchCapturePublicationRecord()
        harness.engine.onPublishStatus = { publications.statuses.append($0) }
        harness.engine.onPresentationChanged = { publications.presentations.append($0) }
        return publications
    }

    func advanceNotificationGate(
        _ gate: WatchCaptureHoldGate,
        scheduler: MockWatchNotificationScheduler,
        keyPath: ReferenceWritableKeyPath<MockWatchNotificationScheduler, WatchCaptureHoldGate?>,
        rearmWith nextGate: WatchCaptureHoldGate? = nil
    ) async {
        await self.waitForGate(gate)
        scheduler[keyPath: keyPath] = nextGate
        await gate.release()
    }

    func makeHarness(
        audioPermission: Bool = true,
        microphonePermission: WatchMicrophonePermission? = nil,
        locationAuthorization: WatchLocationAuthorization = .authorized,
        notificationAuthorizationStatus: WatchNotificationAuthorizationStatus = .authorized,
        notificationAlertSetting: WatchNotificationAlertSetting = .enabled,
        fileWriter: (any WatchFileWriting)? = nil,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding = MockWatchRelayDiagnosticsEnvironmentProvider(),
        audioSessionNotificationHandoff: @escaping WatchAudioSessionNotificationHandoff = { operation in
            Task { @MainActor in operation() }
        }
    ) throws -> Harness {
        let recorder = MockWatchAudioRecorder(
            microphonePermission: microphonePermission ?? (audioPermission ? .granted : .denied)
        )
        let audioSession = MockWatchAudioSession()
        let locationProvider = MockWatchLocationProvider(authorizationStatus: locationAuthorization)
        let writer = fileWriter ?? FoundationWatchFileWriter()
        let rootURL = self.tempDirectory
            .appendingPathComponent("Harness-\(UUID().uuidString)", isDirectory: true)
        let storage = try WatchCaptureStorage(rootURL: rootURL, fileWriter: writer)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_713_624_000))
        let audioProbe = MockWatchAudioProbe()
        let notificationScheduler = MockWatchNotificationScheduler(
            authorizationStatus: notificationAuthorizationStatus,
            alertSetting: notificationAlertSetting
        )
        let notificationCenter = NotificationCenter()
        let engine = WatchCaptureEngine(
            audioRecorder: recorder,
            audioSession: audioSession,
            locationProvider: locationProvider,
            storage: storage,
            clock: clock,
            audioProbe: audioProbe,
            notificationScheduler: notificationScheduler,
            environmentProvider: environmentProvider,
            notificationCenter: notificationCenter,
            audioSessionNotificationHandoff: audioSessionNotificationHandoff
        )
        return Harness(
            engine: engine,
            recorder: recorder,
            audioSession: audioSession,
            locationProvider: locationProvider,
            storage: storage,
            clock: clock,
            audioProbe: audioProbe,
            notificationScheduler: notificationScheduler,
            notificationCenter: notificationCenter
        )
    }

    /// Yield the cooperative thread until `condition` holds or a bounded cap is hit.
    /// Deterministic replacement for fixed Task.yield() counts after advancing the mock clock.
    /// Yields until `condition` holds, then returns immediately. Fails closed at the
    /// bounded cap: silently returning would let every dependent assertion pass
    /// vacuously. `file`/`line` default to the CALL SITE, so the failure is attributed
    /// to the fixture that waited, not to this helper.
    func drain(
        until condition: () -> Bool,
        maxYields: Int = 10_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while yields < maxYields {
            if condition() { return }
            await Task.yield()
            yields += 1
        }
        if condition() { return }
        XCTFail(
            "drain(until:) exhausted \(maxYields) yields without the condition becoming true",
            file: file,
            line: line
        )
    }

    /// Yields until the gate has a parked continuation, then returns immediately.
    /// Fails closed at the bounded cap for the same reason as `drain(until:)`.
    func waitForGate(
        _ gate: WatchCaptureHoldGate,
        maxYields: Int = 10_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while yields < maxYields {
            if await gate.waiting() { return }
            await Task.yield()
            yields += 1
        }
        if await gate.waiting() { return }
        XCTFail(
            "waitForGate exhausted \(maxYields) yields without the gate suspending",
            file: file,
            line: line
        )
    }

    /// Polls the serializer's exact settled state without creating a losing task
    /// or continuation that a bounded test failure could leave suspended.
    func settleCaptureEngine(
        _ engine: WatchCaptureEngine,
        maxYields: Int = 10_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while yields < maxYields {
            if engine.lifecycleSerializer.isSettled { return }
            await Task.yield()
            yields += 1
        }
        if engine.lifecycleSerializer.isSettled { return }
        XCTFail(
            "settleCaptureEngine exhausted \(maxYields) yields without settlement",
            file: file,
            line: line
        )
    }

    func initialDirectory(in harness: Harness) -> URL {
        let startedAt = harness.clock.now()
        return harness.storage.segmentDirectoryURL(
            day: harness.storage.dayString(for: startedAt),
            segment: harness.storage.provisionalSegmentString(for: startedAt)
        )
    }

    func successorDirectory(in harness: Harness) -> URL {
        let startedAt = harness.clock.now().addingTimeInterval(WatchCaptureTiming.segmentDurationSeconds)
        return harness.storage.segmentDirectoryURL(
            day: harness.storage.dayString(for: startedAt),
            segment: harness.storage.provisionalSegmentString(for: startedAt)
        )
    }

    func assertTerminalRolloverFailure(in harness: Harness, successorStarts: Int) throws {
        let record = try XCTUnwrap(try harness.storage.readSessionRecord())
        XCTAssertEqual(record.state, .terminal)
        XCTAssertEqual(record.terminalReason, .audioStartFailed)
        XCTAssertEqual(record.terminalDisposition, .detectedStoppedItself)
        XCTAssertNotNil(record.terminalAt)
        XCTAssertFalse(record.noticeOwed)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
        XCTAssertEqual(harness.recorder.startURLs.count, successorStarts)
        XCTAssertFalse(harness.recorder.isRecording)
        XCTAssertEqual(harness.audioSession.setActiveCalls.last, false)
        XCTAssertNil(harness.notificationScheduler.pendingRequests[WatchNoticeIdentifiers.lease])
        XCTAssertGreaterThanOrEqual(harness.locationProvider.stopCallCount, 1)
    }

    func pendingSleeperCount(in clock: MockObserverClock) -> Int {
        guard let sleepers = Mirror(reflecting: clock).children.first(where: { $0.label == "sleepers" }) else {
            return 0
        }
        return Mirror(reflecting: sleepers.value).children.count
    }

    func jsonLines(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    func writeManifest(
        storage: WatchCaptureStorage,
        startedAt: Date,
        state: WatchSegmentState,
        sensors: [WatchSensor]
    ) throws -> URL {
        let day = storage.dayString(for: startedAt)
        let segment = storage.provisionalSegmentString(for: startedAt)
        let directory = try storage.ensureSegmentDirectory(day: day, segment: segment)
        let manifest = WatchSegmentManifest(
            id: UUID(),
            day: day,
            segment: segment,
            startedAt: startedAt,
            duration: 0,
            sensors: sensors,
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: state,
            failureReason: nil
        )
        try storage.writeManifest(manifest, in: directory)
        return directory
    }

    static func fix(
        time: Date = Date(timeIntervalSince1970: 1_713_624_000),
        lat: Double = 39.7392,
        lon: Double = -104.9903,
        alt: Double? = 1609,
        vAcc: Double? = 12,
        speed: Double? = 0,
        course: Double? = 180
    ) -> WatchLocationFix {
        WatchLocationFix(
            t: time,
            lat: lat,
            lon: lon,
            hAcc: 25,
            alt: alt,
            vAcc: vAcc,
            speed: speed,
            course: course,
            stationary: false
        )
    }
}

private actor WatchCaptureHoldGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaitingForResume = false
    private var isOpen = false

    func suspend() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isWaitingForResume = true
        }
        self.isWaitingForResume = false
    }

    func waiting() -> Bool { self.isWaitingForResume }

    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func open() {
        self.isOpen = true
        self.release()
    }
}

@MainActor
private final class WatchCapturePublicationRecord {
    var statuses: [WatchStatusContext] = []
    var presentations: [WatchCaptureOwnerPresentation] = []
}

@MainActor
private final class MockWatchNotificationScheduler: WatchNotificationScheduling {
    enum Call: Equatable {
        case authorizationStatus
        case alertSetting
        case requestAuthorization
        case add(identifier: String, title: String, body: String, triggerDate: Date?)
        case removePending(identifier: String)
    }

    struct PendingRequest: Equatable {
        let identifier: String
        let title: String
        let body: String
        let triggerDate: Date?
    }

    var authorizationStatusValue: WatchNotificationAuthorizationStatus
    var alertSettingValue: WatchNotificationAlertSetting
    var requestAuthorizationResult: WatchNotificationAuthorizationStatus
    var requestAuthorizationError: (any Error)?
    var addError: (any Error)?
    var onAddCallback: (@MainActor () async -> Void)?
    var authorizationStatusGate: WatchCaptureHoldGate?
    var alertSettingGate: WatchCaptureHoldGate?
    var requestAuthorizationGate: WatchCaptureHoldGate?
    var addGate: WatchCaptureHoldGate?
    var calls: [Call] = []
    var pendingRequests: [String: PendingRequest] = [:]
    var submittedRequests: [PendingRequest] = []

    init(
        authorizationStatus: WatchNotificationAuthorizationStatus,
        alertSetting: WatchNotificationAlertSetting
    ) {
        self.authorizationStatusValue = authorizationStatus
        self.alertSettingValue = alertSetting
        self.requestAuthorizationResult = authorizationStatus
    }

    func authorizationStatus() async -> WatchNotificationAuthorizationStatus {
        self.calls.append(.authorizationStatus)
        if let authorizationStatusGate {
            await authorizationStatusGate.suspend()
        }
        return self.authorizationStatusValue
    }

    func alertSetting() async -> WatchNotificationAlertSetting {
        self.calls.append(.alertSetting)
        if let alertSettingGate {
            await alertSettingGate.suspend()
        }
        return self.alertSettingValue
    }

    func requestAuthorization() async throws -> WatchNotificationAuthorizationStatus {
        self.calls.append(.requestAuthorization)
        if let requestAuthorizationGate {
            await requestAuthorizationGate.suspend()
        }
        if let requestAuthorizationError {
            throw requestAuthorizationError
        }
        self.authorizationStatusValue = self.requestAuthorizationResult
        return self.requestAuthorizationResult
    }

    func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws {
        self.calls.append(.add(identifier: identifier, title: title, body: body, triggerDate: triggerDate))
        if let addGate {
            await addGate.suspend()
        }
        if let addError {
            throw addError
        }
        if let onAddCallback {
            await onAddCallback()
        }
        let request = PendingRequest(
            identifier: identifier,
            title: title,
            body: body,
            triggerDate: triggerDate
        )
        self.submittedRequests.append(request)
        self.pendingRequests[identifier] = request
    }

    func removePending(identifier: String) {
        self.calls.append(.removePending(identifier: identifier))
        self.pendingRequests.removeValue(forKey: identifier)
    }

    func addCalls(identifier: String? = nil) -> [Call] {
        self.calls.filter { call in
            guard case let .add(addIdentifier, _, _, _) = call else { return false }
            return identifier.map { addIdentifier == $0 } ?? true
        }
    }

    func removeCalls(identifier: String? = nil) -> [Call] {
        self.calls.filter { call in
            guard case let .removePending(removeIdentifier) = call else { return false }
            return identifier.map { removeIdentifier == $0 } ?? true
        }
    }
}

@MainActor
private final class MockWatchAudioSession: WatchAudioSessionControlling {
    var hasSuitableInput = true
    var setActiveCalls: [Bool] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {}

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        self.setActiveCalls.append(active)
    }
}

@MainActor
private final class ProductionRecorderStore {
    private(set) var handles: [WeakRecorderHandle] = []

    var count: Int { self.handles.count }

    var latest: WeakRecorderHandle? {
        guard let handle = self.handles.last else { return nil }
        handle.forwarder = handle.recorder?.delegate as? WatchAudioRecorderTerminalForwarder
        return handle
    }

    func makeRecorder(url: URL, settings: [String: Any]) throws -> AVAudioRecorder {
        let telemetry = RecorderTelemetry()
        let recorder = try SynchronousFinishAudioRecorder(
            url: url,
            settings: settings,
            telemetry: telemetry
        )
        try Data("aac".utf8).write(to: url)
        let handle = WeakRecorderHandle(telemetry: telemetry)
        handle.recorder = recorder
        self.handles.append(handle)
        return recorder
    }
}

/// Counts terminal deliveries that actually reached the sink, so fixtures can
/// converge on proof a callback was delivered instead of a fixed yield count.
@MainActor
private final class TerminalDeliveryProbe {
    var count = 0
}

private final class AudioSessionNotificationHandoffProbe: @unchecked Sendable {
    typealias Operation = @MainActor @Sendable () -> Void

    private let operations = OSAllocatedUnfairLock<[Operation]>(initialState: [])

    var pendingCount: Int {
        self.operations.withLock { $0.count }
    }

    func capture(_ operation: @escaping Operation) {
        self.operations.withLock { $0.append(operation) }
    }

    @MainActor
    func releaseAll() {
        let pending = self.operations.withLock { operations -> [Operation] in
            let pending = operations
            operations.removeAll()
            return pending
        }
        for operation in pending {
            operation()
        }
    }
}

@MainActor
private final class ProductionRolloverSnapshotProbe {
    var value: ProductionRolloverSnapshot?
    var error: (any Error)?
    let publications = WatchCapturePublicationRecord()
}

@MainActor
private struct ProductionRolloverSnapshot {
    let record: WatchCaptureSessionRecord
    let storageInventory: WatchCaptureStorageInventory
    let presentation: WatchCaptureOwnerPresentation
    let notices: Int
    let successor: WeakRecorderHandle
    let successorSource: WatchCaptureSourceToken
    let successorTelemetry: RecorderTelemetry.Snapshot
    let predecessorTelemetry: RecorderTelemetry.Snapshot
}

private struct WatchCaptureStorageInventory: Equatable {
    struct Entry: Equatable {
        let relativePath: String
        let isDirectory: Bool
        let contents: Data?
    }

    let entries: [Entry]
}

@MainActor
private final class MockWatchAudioRecorder: WatchAudioRecording {
    var url: URL?
    var currentTime: TimeInterval = 0
    var isRecording = false
    var eventSink: (any WatchAudioRecorderEventSink)?
    var startURLs: [URL] = []
    var startSources: [WatchCaptureSourceToken] = []
    var stopCallCount = 0
    var microphonePermission: WatchMicrophonePermission
    var requestPermissionResult: WatchMicrophonePermission = .granted
    var requestPermissionCallCount = 0
    var nextStopDuration: TimeInterval = 300
    var startError: (any Error)?
    var writesBeforeStartError = false
    var stopError: (any Error)?
    var stopErrorOnce: (any Error)?
    var requestPermissionGate: WatchCaptureHoldGate?
    var startObservation: ((URL, WatchCaptureSourceToken) -> Void)?

    init(microphonePermission: WatchMicrophonePermission) {
        self.microphonePermission = microphonePermission
    }

    func requestPermission() async -> WatchMicrophonePermission {
        self.requestPermissionCallCount += 1
        if let requestPermissionGate {
            await requestPermissionGate.suspend()
        }
        self.microphonePermission = self.requestPermissionResult
        return self.requestPermissionResult
    }

    func start(url: URL, source: WatchCaptureSourceToken) throws {
        self.startObservation?(url, source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let startError, !self.writesBeforeStartError { throw startError }
        try Data("audio".utf8).write(to: url)
        if let startError { throw startError }
        self.url = url
        self.currentTime = 0
        self.isRecording = true
        self.startURLs.append(url)
        self.startSources.append(source)
    }

    func stop() throws -> TimeInterval {
        self.stopCallCount += 1
        if let stopErrorOnce {
            self.stopErrorOnce = nil
            throw stopErrorOnce
        }
        if let stopError { throw stopError }
        self.currentTime = self.nextStopDuration
        self.isRecording = false
        return self.nextStopDuration
    }
}

@MainActor
private final class MockWatchLocationProvider: WatchLocationProviding {
    var onFix: (@MainActor @Sendable (WatchLocationFix) -> Void)?
    var onAuthorizationChanged: (@MainActor @Sendable (WatchLocationAuthorization) -> Void)?
    var onFailure: (@MainActor @Sendable (any Error) -> Void)?
    var authorizationStatus: WatchLocationAuthorization
    var startCallCount = 0
    var stopCallCount = 0

    init(authorizationStatus: WatchLocationAuthorization) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {}

    func start() throws {
        self.startCallCount += 1
    }

    func stop() {
        self.stopCallCount += 1
    }

    func emitFix(_ fix: WatchLocationFix) {
        self.onFix?(fix)
    }

    func emitAuthorization(_ authorization: WatchLocationAuthorization) {
        self.authorizationStatus = authorization
        self.onAuthorizationChanged?(authorization)
    }

    func emitFailure(_ error: any Error) {
        self.onFailure?(error)
    }
}

@MainActor
private final class MockWatchAudioProbe: WatchAudioProbing {
    var durations: [String: TimeInterval?] = [:]
    // Six re-harnessed legacy tests depend on unseeded URLs reading decodable.
    var defaultDuration: TimeInterval? = 300

    func decodableDuration(at url: URL) -> TimeInterval? {
        if let seeded = self.durations[url.path] {
            return seeded
        }
        return self.defaultDuration
    }
}

@MainActor
private final class FailingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private let failAppend: Bool
    private let failContents: Bool
    var failAtomicReplace: Bool
    var failWriteData: Bool
    var writeDataURLs: [URL] = []
    var appendLineURLs: [URL] = []
    var readDataURLs: [URL] = []
    var atomicReplaceURLs: [URL] = []
    var removeItemURLs: [URL] = []
    var moveItems: [(source: URL, destination: URL)] = []
    var fileSizeURLs: [URL] = []
    var writeDataObservations: [String: () -> Void] = [:]
    var appendLineObservations: [String: () -> Void] = [:]
    private var atomicReplaceOrdinals: [String: Int] = [:]
    private var writeDataOrdinals: [String: Int] = [:]
    private var atomicReplaceFailures: [String: Set<Int>] = [:]
    private var writeDataFailures: [String: Set<Int>] = [:]
    private var fileSizeFailures: Set<String> = []

    init(
        failAppend: Bool,
        failContents: Bool = false,
        failAtomicReplace: Bool = false,
        failWriteData: Bool = false
    ) {
        self.failAppend = failAppend
        self.failContents = failContents
        self.failAtomicReplace = failAtomicReplace
        self.failWriteData = failWriteData
    }

    func createDirectory(at url: URL) throws {
        try self.base.createDirectory(at: url)
    }

    func createFileIfNeeded(at url: URL) throws {
        try self.base.createFileIfNeeded(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func fileSize(at url: URL) throws -> Int64 {
        self.fileSizeURLs.append(url)
        if self.fileSizeFailures.contains(url.path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try self.base.fileSize(at: url)
    }

    func readData(from url: URL) throws -> Data {
        self.readDataURLs.append(url)
        return try self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        self.writeDataURLs.append(url)
        let ordinal = self.nextOrdinal(for: url, in: &self.writeDataOrdinals)
        if self.failWriteData || self.writeDataFailures[url.path]?.contains(ordinal) == true {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        self.writeDataObservations[url.path]?()
        try self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        self.appendLineURLs.append(url)
        if self.failAppend {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        self.appendLineObservations[url.path]?()
        try self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        self.atomicReplaceURLs.append(url)
        let ordinal = self.nextOrdinal(for: url, in: &self.atomicReplaceOrdinals)
        if self.failAtomicReplace || self.atomicReplaceFailures[url.path]?.contains(ordinal) == true {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        try self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) throws {
        self.removeItemURLs.append(url)
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        self.moveItems.append((source: sourceURL, destination: destinationURL))
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        if self.failContents {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try self.base.contentsOfDirectory(at: url)
    }

    func failNextAtomicReplace(at url: URL) {
        let next = (self.atomicReplaceOrdinals[url.path] ?? 0) + 1
        self.failAtomicReplace(at: url, ordinal: next)
    }

    func failNextWriteData(at url: URL) {
        let next = (self.writeDataOrdinals[url.path] ?? 0) + 1
        self.failWriteData(at: url, ordinal: next)
    }

    func failAtomicReplace(at url: URL, ordinal: Int) {
        self.atomicReplaceFailures[url.path, default: []].insert(ordinal)
    }

    func failWriteData(at url: URL, ordinal: Int) {
        self.writeDataFailures[url.path, default: []].insert(ordinal)
    }

    func failFileSize(at url: URL) {
        self.fileSizeFailures.insert(url.path)
    }

    private func nextOrdinal(for url: URL, in ordinals: inout [String: Int]) -> Int {
        let ordinal = (ordinals[url.path] ?? 0) + 1
        ordinals[url.path] = ordinal
        return ordinal
    }
}
