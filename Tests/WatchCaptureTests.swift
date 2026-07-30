// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
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

        await harness.engine.start()
        await self.drain(until: { self.pendingSleeperCount(in: harness.clock) >= 2 })
        harness.clock.advance(by: 300)
        await self.drain(until: { harness.recorder.startURLs.count == 2 })

        XCTAssertEqual(harness.recorder.startURLs.count, 2)
        XCTAssertFalse(harness.audioSession.setActiveCalls.contains(false))

        await harness.engine.stop()

        XCTAssertEqual(harness.audioSession.setActiveCalls, [true, false])
    }

    func testClockRolloverFinalizesCurrentSegmentAndOpensNext() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        await harness.engine.start()
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

        await harness.engine.start()
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

        await harness.engine.start()
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

    func testAC9DeliveredSegmentsCountAsConfirmingAndTerminalStatesAsHandedOff() throws {
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

        await harness.engine.start()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        await harness.engine.stop()

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

        await harness.engine.start()
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

        await harness.engine.start()
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

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.start()

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

        await harness.engine.start()

        XCTAssertEqual(harness.recorder.requestPermissionCallCount, 0)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
    }

    func testMicrophonePermissionAndAudioArmFailuresHaveDistinctOutcomes() async throws {
        let notDetermined = try self.makeHarness(
            microphonePermission: .notDetermined,
            locationAuthorization: .authorized
        )
        notDetermined.recorder.requestPermissionResult = .denied
        await notDetermined.engine.start()

        let denied = try self.makeHarness(audioPermission: false, locationAuthorization: .authorized)
        await denied.engine.start()

        let armFailure = try self.makeHarness(locationAuthorization: .authorized)
        armFailure.recorder.startError = ObserverError.unavailable(reason: "audio unavailable")
        await armFailure.engine.start()

        XCTAssertEqual(notDetermined.engine.ownerPresentation.startRefusalReason, .microphonePermissionNotDetermined)
        XCTAssertEqual(denied.engine.ownerPresentation.startRefusalReason, .microphonePermissionDenied)
        XCTAssertEqual(armFailure.engine.ownerPresentation.startRefusalReason, .audioArmFailed)
        XCTAssertFalse(armFailure.engine.ownerPresentation.isSessionRunning)
        XCTAssertTrue(try armFailure.storage.scanManifests().isEmpty)
    }

    func testRouteChangeWithoutSuitableInputTerminatesWithDetectedReason() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        await harness.engine.start()
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
        await lost.engine.start()
        await self.drain(until: { lostStatuses.contains { $0.phase == .observing } })
        lostStatuses.removeAll()
        lost.notificationCenter.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
        await self.drain(until: { lostStatuses.contains { $0.audioTerminalReason == .audioMediaServicesLost } })

        let reset = try self.makeHarness(locationAuthorization: .denied)
        var resetStatuses: [WatchStatusContext] = []
        reset.engine.onPublishStatus = { resetStatuses.append($0) }
        await reset.engine.start()
        await self.drain(until: { resetStatuses.contains { $0.phase == .observing } })
        resetStatuses.removeAll()
        reset.notificationCenter.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await self.drain(until: { resetStatuses.contains { $0.audioTerminalReason == .audioMediaServicesReset } })

        XCTAssertEqual(lostStatuses.last?.audioTerminalReason, .audioMediaServicesLost)
        XCTAssertEqual(resetStatuses.last?.audioTerminalReason, .audioMediaServicesReset)
    }

    func testRecorderDelegateFailuresTerminateWithDistinctReasons() async throws {
        let finished = try self.makeHarness(locationAuthorization: .denied)
        var finishedStatuses: [WatchStatusContext] = []
        finished.engine.onPublishStatus = { finishedStatuses.append($0) }
        await finished.engine.start()
        await self.drain(until: { finishedStatuses.contains { $0.phase == .observing } })
        finishedStatuses.removeAll()
        finished.recorder.eventSink?.audioRecorderDidFinish(successfully: false)
        await self.drain(until: { finishedStatuses.contains { $0.audioTerminalReason == .audioFinishUnsuccessful } })

        let encoded = try self.makeHarness(locationAuthorization: .denied)
        var encodedStatuses: [WatchStatusContext] = []
        encoded.engine.onPublishStatus = { encodedStatuses.append($0) }
        await encoded.engine.start()
        await self.drain(until: { encodedStatuses.contains { $0.phase == .observing } })
        encodedStatuses.removeAll()
        encoded.recorder.eventSink?.audioRecorderEncodeError(nil)
        await self.drain(until: { encodedStatuses.contains { $0.audioTerminalReason == .audioEncodeError } })

        XCTAssertEqual(finishedStatuses.last?.audioTerminalReason, .audioFinishUnsuccessful)
        XCTAssertEqual(encodedStatuses.last?.audioTerminalReason, .audioEncodeError)
    }

    func testLivenessPollFailuresTerminateWithDistinctReasons() async throws {
        let stopped = try self.makeHarness(locationAuthorization: .denied)
        var stoppedStatuses: [WatchStatusContext] = []
        stopped.engine.onPublishStatus = { stoppedStatuses.append($0) }
        await stopped.engine.start()
        await self.drain(until: { self.pendingSleeperCount(in: stopped.clock) >= 2 })
        stopped.recorder.isRecording = false
        stopped.clock.advance(by: 15)
        await self.drain(until: { stoppedStatuses.contains { $0.audioTerminalReason == .audioRecorderStopped } })

        let stalled = try self.makeHarness(locationAuthorization: .denied)
        var stalledStatuses: [WatchStatusContext] = []
        stalled.engine.onPublishStatus = { stalledStatuses.append($0) }
        await stalled.engine.start()
        await self.drain(until: { self.pendingSleeperCount(in: stalled.clock) >= 2 })
        stalled.recorder.currentTime = 5
        stalled.clock.advance(by: 15)
        await self.drain(until: { stalledStatuses.contains { $0.seq >= 2 } })
        stalledStatuses.removeAll()
        stalled.clock.advance(by: 15)
        await self.drain(until: { stalledStatuses.contains { $0.audioTerminalReason == .audioClockStalled } })

        XCTAssertEqual(stoppedStatuses.last?.audioTerminalReason, .audioRecorderStopped)
        XCTAssertEqual(stalledStatuses.last?.audioTerminalReason, .audioClockStalled)
    }

    func testAppendFixInCallbackDurablyWritesBeforeFinalize() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        await harness.engine.start()
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

        await harness.engine.start()
        harness.locationProvider.emitFix(Self.fix())
        harness.locationProvider.emitFix(Self.fix(lat: 39.8))
        await harness.engine.stop()

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
        await notArmed.engine.start()
        await notArmed.engine.stop()
        let notArmedEntry = try XCTUnwrap(notArmed.storage.scanManifests().first)
        XCTAssertFalse(notArmedEntry.manifest.sensors.contains(.location))
        XCTAssertFalse(notArmed.storage.fileWriter.fileExists(at: notArmed.storage.locationURL(directory: notArmedEntry.directoryURL)))

        let stalled = try self.makeHarness(locationAuthorization: .authorized)
        await stalled.engine.start()
        await stalled.engine.stop()
        let stalledManifest = try XCTUnwrap(stalled.storage.scanManifests().first?.manifest)
        XCTAssertEqual(stalledManifest.fixCount, 0)
        XCTAssertTrue(stalledManifest.gap)

        let stationary = try self.makeHarness(locationAuthorization: .authorized)
        await stationary.engine.start()
        stationary.locationProvider.emitFix(Self.fix())
        await self.drain(until: { self.pendingSleeperCount(in: stationary.clock) >= 2 })
        stationary.clock.advance(by: 300)
        await self.drain(until: {
            (try? stationary.storage.scanManifests().count) == 2
        })
        await stationary.engine.stop()
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

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.reconcileOnLaunch()

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        XCTAssertEqual(entry.manifest.state, .queued)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertTrue(entry.manifest.lost)
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: harness.storage.audioURL(directory: entry.directoryURL)))
    }

    func testFinalizeProbeMarksUndecodableAudioLost() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        await harness.engine.start()
        harness.locationProvider.emitFix(Self.fix())
        let audioURL = try XCTUnwrap(harness.recorder.url)
        harness.audioProbe.durations[audioURL.path] = .some(nil)
        await harness.engine.stop()

        let entry = try XCTUnwrap(harness.storage.scanManifests().first)
        XCTAssertEqual(entry.manifest.state, .queued)
        XCTAssertTrue(entry.manifest.partial)
        XCTAssertTrue(entry.manifest.lost)
        XCTAssertFalse(harness.storage.fileWriter.fileExists(at: harness.storage.audioURL(directory: entry.directoryURL)))
        XCTAssertTrue(harness.storage.fileWriter.fileExists(at: harness.storage.locationURL(directory: entry.directoryURL)))
    }

    func testDecodableNonZeroAudioFinalizesHealthyWithoutLostPartial() async throws {
        let harness = try self.makeHarness(locationAuthorization: .denied)

        await harness.engine.start()
        let audioURL = try XCTUnwrap(harness.recorder.url)
        harness.audioProbe.durations[audioURL.path] = 123
        await harness.engine.stop()

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

        await harness.engine.start()
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
    }

    func testElapsedLocationCoverageSegmentIsNeverDiscarded() async throws {
        let harness = try self.makeHarness(locationAuthorization: .authorized)

        await harness.engine.start()
        harness.locationProvider.emitFix(Self.fix())
        await harness.engine.stop()

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

        await harness.engine.start()
        harness.locationProvider.emitFix(Self.fix())
        let degraded = harness.engine.ownerPresentation
        XCTAssertEqual(degraded.status, .active)
        XCTAssertEqual(degraded.locationAdvisory, .writeFailed)
        XCTAssertTrue(degraded.isSessionRunning)
        await harness.engine.stop()

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

        await harness.engine.start()

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

        await harness.engine.start()
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

        await harness.engine.start()
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

        await harness.engine.start()
        harness.locationProvider.emitFailure(NSError(domain: "WatchCaptureTests.location", code: 1))
        XCTAssertEqual(harness.engine.ownerPresentation.locationAdvisory, .providerFailed)
        await harness.engine.stop()
        XCTAssertEqual(harness.engine.ownerPresentation.locationAdvisory, .providerFailed)
        await harness.engine.start()
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
        await writeFailure.engine.start()
        writeFailure.locationProvider.emitFix(Self.fix())

        let authorization = try self.makeHarness(audioPermission: true, locationAuthorization: .authorized)
        await authorization.engine.start()
        authorization.locationProvider.emitAuthorization(.denied)

        let provider = try self.makeHarness(audioPermission: true, locationAuthorization: .authorized)
        await provider.engine.start()
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

        await harness.engine.start()
        await harness.engine.stop()

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

        await harness.engine.reconcileOnLaunch()

        XCTAssertTrue(harness.recorder.startURLs.isEmpty)
        XCTAssertTrue(harness.audioSession.setActiveCalls.isEmpty)
        XCTAssertEqual(harness.engine.ownerPresentation.queuedCount, 1)
    }

    func testSessionRecordWriteUsesAtomicReplaceFile() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)

        await harness.engine.start()

        let recordURL = harness.storage.sessionRecordURL()
        XCTAssertTrue(fileWriter.atomicReplaceURLs.contains(recordURL))
        XCTAssertFalse(fileWriter.writeDataURLs.contains(recordURL))
        XCTAssertFalse(fileWriter.readDataURLs.contains(recordURL))
    }

    func testSessionRecordWriteFailureTerminatesAndPublishesPersistenceAdvisory() async throws {
        let fileWriter = FailingWatchFileWriter(failAppend: false, failAtomicReplace: true)
        let harness = try self.makeHarness(locationAuthorization: .denied, fileWriter: fileWriter)

        await harness.engine.start()
        await harness.engine.stop()

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

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.start()
        await self.drain(until: { statuses.contains { $0.phase == .observing } })
        statuses.removeAll()
        presentations.removeAll()
        fileWriter.failWriteData = true
        await harness.engine.stop()

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

    func testUndecodableSessionRecordResolvesUncleanWithNoticeOwed() async throws {
        let harness = try self.makeHarness()
        try harness.storage.fileWriter.atomicReplaceFile(
            at: harness.storage.sessionRecordURL(),
            with: Data("{".utf8)
        )
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        await harness.engine.reconcileOnLaunch()

        XCTAssertEqual(statuses.last?.audioTerminalReason, .processExitedWhileActive)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(harness.engine.ownerPresentation.persistenceAdvisory, .sessionRecordUnreadable)
        XCTAssertFalse(harness.engine.ownerPresentation.isSessionRunning)
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

        await harness.engine.reconcileOnLaunch()

        XCTAssertEqual(statuses.last?.sessionID, "session-1")
        XCTAssertEqual(statuses.last?.audioTerminalReason, .processExitedWhileActive)
        XCTAssertEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
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

        await harness.engine.reconcileOnLaunch()

        XCTAssertNotEqual(statuses.last?.audioTerminalDisposition, .inferredStoppedItself)
        XCTAssertEqual(try harness.storage.readSessionRecord()?.noticeOwed, false)
    }

    func testReconcileAbsentSessionRecordDoesNotReportStoppedItselfOrNoticeOwed() async throws {
        let harness = try self.makeHarness()
        var statuses: [WatchStatusContext] = []
        harness.engine.onPublishStatus = { statuses.append($0) }

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.reconcileOnLaunch()
        let afterFirst = try XCTUnwrap(try harness.storage.readSessionRecord())
        await harness.engine.reconcileOnLaunch()
        let afterSecond = try XCTUnwrap(try harness.storage.readSessionRecord())

        XCTAssertEqual(statuses.filter { $0.audioTerminalDisposition == .inferredStoppedItself }.count, 1)
        XCTAssertEqual(afterFirst.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(afterSecond.terminalReason, .processExitedWhileActive)
        XCTAssertEqual(afterFirst.terminalAt, terminalAt)
        XCTAssertEqual(afterSecond.terminalAt, terminalAt)
        XCTAssertFalse(afterFirst.noticeOwed)
        XCTAssertFalse(afterSecond.noticeOwed)
    }

    func testFinalizedUnsentSegmentsBecomeQueuedOnRelaunch() async throws {
        let harness = try self.makeHarness()
        _ = try self.writeManifest(
            storage: harness.storage,
            startedAt: Date(timeIntervalSince1970: 1_713_624_000),
            state: .finalized,
            sensors: [.audio]
        )

        await harness.engine.reconcileOnLaunch()

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

        await harness.engine.start()
        harness.locationProvider.emitFix(Self.fix(alt: nil, vAcc: nil, speed: nil, course: nil))
        await harness.engine.stop()

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
    struct Harness {
        let engine: WatchCaptureEngine
        let recorder: MockWatchAudioRecorder
        let audioSession: MockWatchAudioSession
        let locationProvider: MockWatchLocationProvider
        let storage: WatchCaptureStorage
        let clock: MockObserverClock
        let audioProbe: MockWatchAudioProbe
        let notificationCenter: NotificationCenter
    }

    func makeHarness(
        audioPermission: Bool = true,
        microphonePermission: WatchMicrophonePermission? = nil,
        locationAuthorization: WatchLocationAuthorization = .authorized,
        fileWriter: (any WatchFileWriting)? = nil
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
        let notificationCenter = NotificationCenter()
        let engine = WatchCaptureEngine(
            audioRecorder: recorder,
            audioSession: audioSession,
            locationProvider: locationProvider,
            storage: storage,
            clock: clock,
            audioProbe: audioProbe,
            notificationCenter: notificationCenter
        )
        return Harness(
            engine: engine,
            recorder: recorder,
            audioSession: audioSession,
            locationProvider: locationProvider,
            storage: storage,
            clock: clock,
            audioProbe: audioProbe,
            notificationCenter: notificationCenter
        )
    }

    /// Yield the cooperative thread until `condition` holds or a bounded cap is hit.
    /// Deterministic replacement for fixed Task.yield() counts after advancing the mock clock.
    func drain(until condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
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
private final class MockWatchAudioRecorder: WatchAudioRecording {
    var url: URL?
    var currentTime: TimeInterval = 0
    var isRecording = false
    var eventSink: (any WatchAudioRecorderEventSink)?
    var startURLs: [URL] = []
    var stopCallCount = 0
    var microphonePermission: WatchMicrophonePermission
    var requestPermissionResult: WatchMicrophonePermission = .granted
    var requestPermissionCallCount = 0
    var nextStopDuration: TimeInterval = 300
    var startError: (any Error)?

    init(microphonePermission: WatchMicrophonePermission) {
        self.microphonePermission = microphonePermission
    }

    func requestPermission() async -> WatchMicrophonePermission {
        self.requestPermissionCallCount += 1
        self.microphonePermission = self.requestPermissionResult
        return self.requestPermissionResult
    }

    func start(url: URL) throws {
        if let startError { throw startError }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        self.url = url
        self.currentTime = 0
        self.isRecording = true
        self.startURLs.append(url)
    }

    func stop() throws -> TimeInterval {
        self.stopCallCount += 1
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
    var readDataURLs: [URL] = []
    var atomicReplaceURLs: [URL] = []

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

    func readData(from url: URL) throws -> Data {
        self.readDataURLs.append(url)
        return try self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        self.writeDataURLs.append(url)
        if self.failWriteData {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        try self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        if self.failAppend {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        try self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        self.atomicReplaceURLs.append(url)
        if self.failAtomicReplace {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        try self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        if self.failContents {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try self.base.contentsOfDirectory(at: url)
    }
}
