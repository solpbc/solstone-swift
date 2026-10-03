// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
private final class AudioInterruptionControlReloadSpy: ObserverCaptureControlReloading {
    func reloadControls(ofKind kind: String) {}
}

/// Owner audio that is retired as unreadable stays visible as an interruption on the
/// status pill, the status pane, the on-this-device screen and the widgets, apart from
/// the send count, until nothing else is left to say.
@MainActor
final class AudioInterruptionStatusTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInterruptionStatusTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        try await super.tearDown()
    }

    // MARK: - Evidence

    func testUnreadableAudioRetirementIsAnInterruptionThatSurvivesRestart() async throws {
        let store = self.makeStore()
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let segmentID = UUID()
        let directory = try self.writeActiveSegment(segmentID: segmentID, store: store, sources: [.audio])
        try self.writeUnreadableAudio(in: directory, store: store)

        await uploader.resumeFromDisk()

        let tombstone = try store.readTombstone(
            at: store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(segmentID.uuidString).json")
        )
        XCTAssertEqual(tombstone.reason, MobileSegmentUploader.undecodableAudioReason)
        XCTAssertEqual(uploader.audioInterruptionCount, 1)

        let restarted = MobileSegmentUploader(store: store, clock: self.clock)
        XCTAssertEqual(restarted.audioInterruptionCount, 1)
        await restarted.resumeFromDisk()
        XCTAssertEqual(restarted.audioInterruptionCount, 1)

        for current in [uploader, restarted] {
            let waiting = current.pendingCount + current.failedCount + current.finalizeFailedCount
            XCTAssertEqual(waiting, 0)
            let pill = HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedIdle,
                hasBacklog: waiting > 0,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasAudioInterruption: current.audioInterruptionCount > 0
            )
            XCTAssertEqual(pill, .audioInterrupted)
            let lead = StatusPaneLead.resolve(
                pillState: pill,
                waitingTotal: waiting,
                showsConnectionDetails: true,
                hasAudioInterruption: current.audioInterruptionCount > 0
            )
            XCTAssertEqual(lead.headline, SourceVocabulary.audioInterruptedHeadline)
            XCTAssertEqual(lead.subline, SourceVocabulary.audioInterruptedLine)
            XCTAssertFalse(lead.showsAudioInterruptionNotice)
            XCTAssertNil(lead.buttonTitle)
        }
    }

    func testUnreadableAudioBesideLocationStaysAnInterruptionAfterTheQueueDrains() async throws {
        let store = self.makeStore()
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let live = MobileSegmentLiveLocationTestSupport(clock: self.clock)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let directory = try live.writeActiveLocation(
            segmentID: segmentID,
            store: store,
            sources: [.audio, .location],
            startedAt: startedAt
        )
        try live.writeLocationPart(
            segmentID: segmentID,
            store: store,
            directory: directory,
            startedAt: startedAt,
            fixes: [live.locationFix(at: startedAt.addingTimeInterval(60))]
        )
        try live.writeLocationLiveness(
            segmentID: segmentID,
            store: store,
            directory: directory,
            lastSeenAt: self.clock.now().addingTimeInterval(-121)
        )
        try self.writeUnreadableAudio(in: directory, store: store)

        await uploader.resumeFromDisk()

        // The location survives and waits to send; the lost audio is recorded beside it,
        // not as a queue item.
        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.audioInterruptionCount, 1)
        XCTAssertFalse(store.hasTombstone(segmentID: segmentID, kind: "empty"))
        XCTAssertEqual(self.pill(waiting: uploader.pendingCount, interrupted: true), .syncing)

        try uploader.writeUploadedTombstone(segmentID: segmentID)

        XCTAssertEqual(uploader.pendingCount + uploader.failedCount, 0)
        XCTAssertEqual(uploader.audioInterruptionCount, 1)
        XCTAssertEqual(self.pill(waiting: 0, interrupted: uploader.audioInterruptionCount > 0), .audioInterrupted)
    }

    func testEmptyRetirementsWithNoRecordedAudioAreNotInterruptions() async throws {
        let store = self.makeStore()
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let neverRecorded = UUID()
        _ = try self.writeActiveSegment(
            segmentID: neverRecorded,
            store: store,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-61)
        )
        let screenOnly = UUID()
        let screenDirectory = try self.writeActiveSegment(segmentID: screenOnly, store: store, sources: [.screencast])
        try Data("partial".utf8).write(to: store.screenPartURL(in: screenDirectory), options: .atomic)
        let readable = UUID()
        let readableDirectory = try self.writeActiveSegment(segmentID: readable, store: store, sources: [.audio])
        let readableURL = store.audioURL(in: readableDirectory)
        try MobileSegmentTestFixtures.writeReadableAudio(at: readableURL, seconds: 12)
        try MobileSegmentTestFixtures.setAudioModificationDate(at: readableURL, offset: -400, clock: self.clock)

        await uploader.resumeFromDisk()

        XCTAssertEqual(
            try store.readTombstone(at: self.emptyTombstoneURL(neverRecorded, store: store)).reason,
            "unrecoverable_lost_data"
        )
        XCTAssertTrue(store.hasTombstone(segmentID: screenOnly, kind: "empty"))
        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.audioInterruptionCount, 0)

        try uploader.writeUploadedTombstone(segmentID: readable)
        XCTAssertEqual(self.pill(waiting: uploader.pendingCount, interrupted: uploader.audioInterruptionCount > 0), .caughtUp)
    }

    func testRecordingStaysWhenItsInterruptionCannotBeRecorded() async throws {
        let store = self.makeStore()
        try store.ensureRoot()
        let blocker = store.rootURL.appendingPathComponent("interruptions", isDirectory: false)
        try Data().write(to: blocker)
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let segmentID = UUID()
        let directory = try self.writeActiveSegment(segmentID: segmentID, store: store, sources: [.audio])
        try self.writeUnreadableAudio(in: directory, store: store)

        await uploader.resumeFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(in: directory).path))
        XCTAssertFalse(store.hasTombstone(segmentID: segmentID, kind: "empty"))
        XCTAssertEqual(uploader.audioInterruptionCount, 0)

        try FileManager.default.removeItem(at: blocker)
        await uploader.resumeFromDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.hasTombstone(segmentID: segmentID, kind: "empty"))
        XCTAssertEqual(uploader.audioInterruptionCount, 1)
    }

    func testEarlierUnreadableAudioRecordsAreCarriedForwardOnce() async throws {
        let store = self.makeStore()
        try store.ensureRoot()
        let earlierRetired = UUID()
        try store.writeTombstone(
            segmentID: earlierRetired,
            kind: "empty",
            reason: MobileSegmentUploader.undecodableAudioReason,
            now: self.clock.now().addingTimeInterval(-86_400)
        )
        for reason in ["unrecoverable_lost_data", "no_artifacts", "screencast_removed"] {
            try store.writeTombstone(segmentID: UUID(), kind: "empty", reason: reason, now: self.clock.now())
        }
        try store.writeTombstone(segmentID: UUID(), kind: "uploaded", reason: "delivered", now: self.clock.now())
        let earlierWaiting = UUID()
        let waitingDirectory = try self.writeActiveSegment(segmentID: earlierWaiting, store: store, sources: [.audio, .location])
        var manifest = try store.readManifest(in: waitingDirectory)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .removed,
                reason: MobileSegmentUploader.undecodableAudioReason,
                stage: "AVFoundationErrorDomain -11829",
                lastAttemptAt: self.clock.now()
            ),
            source: .audio,
            manifest: &manifest,
            in: waitingDirectory,
            now: self.clock.now()
        )
        _ = try store.move(segmentID: earlierWaiting, from: .active, to: .failed)

        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        await uploader.resumeFromDisk()

        XCTAssertEqual(uploader.audioInterruptionCount, 2)
        XCTAssertTrue(store.hasBackfilledAudioInterruptions)

        await uploader.resumeFromDisk()
        XCTAssertEqual(MobileSegmentUploader(store: store, clock: self.clock).audioInterruptionCount, 2)
    }

    // MARK: - Pill and pane

    func testPillShowsTheInterruptionOnlyWhereItWouldOtherwiseClaimCaughtUp() {
        let cases: [(ConnectionSyncStatus, Bool, Bool, Bool, HomeStatusPillState)] = [
            (.connectedIdle, false, false, false, .audioInterrupted),
            (.connectedWaiting, false, false, false, .audioInterrupted),
            (.connectedIdle, true, false, false, .syncing),
            (.connectedIdle, false, true, false, .awaitingMarkConfirmation),
            (.connectedIdle, false, false, true, .stalled),
            (.offline, false, false, false, .offline),
            (.reconnecting, false, false, false, .connecting),
        ]
        for (status, hasBacklog, awaiting, stalled, expected) in cases {
            XCTAssertEqual(
                HomeStatusPillState.resolve(
                    isPaired: true,
                    status: status,
                    hasBacklog: hasBacklog,
                    isStalled: stalled,
                    awaitingMarkConfirmation: awaiting,
                    hasAudioInterruption: true
                ),
                expected
            )
        }
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: false,
                status: .connectedIdle,
                hasBacklog: false,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasAudioInterruption: true
            ),
            .notPaired
        )
        XCTAssertEqual(self.pill(waiting: 0, interrupted: false), .caughtUp)
        XCTAssertNotEqual(HomeStatusPillState.audioInterrupted.label, HomeStatusPillState.caughtUp.label)
        XCTAssertFalse(HomeStatusPillState.audioInterrupted.shouldPulse(reduceMotion: false))
    }

    func testPaneKeepsTheNoticeBesideOtherFacts() {
        let beside: [(HomeStatusPillState, Int)] = [
            (.syncing, 4),
            (.offline, 4),
            (.offline, 0),
            (.awaitingMarkConfirmation, 2),
            (.notPaired, 0),
            (.connecting, 1),
        ]
        for (pillState, waiting) in beside {
            let withNotice = StatusPaneLead.resolve(
                pillState: pillState,
                waitingTotal: waiting,
                showsConnectionDetails: false,
                hasAudioInterruption: true
            )
            let without = StatusPaneLead.resolve(
                pillState: pillState,
                waitingTotal: waiting,
                showsConnectionDetails: false,
                hasAudioInterruption: false
            )
            XCTAssertTrue(withNotice.showsAudioInterruptionNotice, "\(pillState) \(waiting)")
            XCTAssertFalse(without.showsAudioInterruptionNotice, "\(pillState) \(waiting)")
            XCTAssertEqual(withNotice.lead, without.lead)
            XCTAssertEqual(withNotice.region, without.region)
        }

        let clean = StatusPaneLead.resolve(pillState: .caughtUp, waitingTotal: 0, showsConnectionDetails: true)
        XCTAssertEqual(clean.headline, SourceVocabulary.syncedHeadline)
        XCTAssertFalse(clean.showsAudioInterruptionNotice)

        let interrupted = StatusPaneLead.resolve(
            pillState: .audioInterrupted,
            waitingTotal: 0,
            showsConnectionDetails: true,
            hasAudioInterruption: true
        )
        XCTAssertNotEqual(interrupted.headline, SourceVocabulary.syncedHeadline)
        XCTAssertEqual(interrupted.region, clean.region)
        XCTAssertNil(interrupted.buttonTitle)
    }

    // MARK: - On this device

    func testOnThisDeviceDoesNotSayEverythingArrived() {
        let drained = OnThisPhoneMigration(onThisPhone: 0, needsAttention: 0)
        let interrupted = onThisPhoneHeadline(
            migration: drained,
            isPaired: true,
            isConnected: true,
            awaitingMarkConfirmation: false,
            isStalled: false,
            connectionStatus: .connectedIdle,
            hasAudioInterruption: true
        )
        XCTAssertEqual(interrupted.role, .audioInterrupted)
        let clean = onThisPhoneHeadline(
            migration: drained,
            isPaired: true,
            isConnected: true,
            awaitingMarkConfirmation: false,
            isStalled: false,
            connectionStatus: .connectedIdle,
            hasAudioInterruption: false
        )
        XCTAssertEqual(clean.role, .upToDate)
        let sending = onThisPhoneHeadline(
            migration: OnThisPhoneMigration(onThisPhone: 2, needsAttention: 0),
            isPaired: true,
            isConnected: true,
            awaitingMarkConfirmation: false,
            isStalled: false,
            connectionStatus: .connectedTransferring,
            hasAudioInterruption: true
        )
        XCTAssertEqual(sending.role, .syncing)

        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: true, hasWelcomeFraming: false, hasAudioInterruption: true),
            .audioInterrupted
        )
        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: true, hasWelcomeFraming: false, hasAudioInterruption: false),
            .allQuiet
        )
    }

    // MARK: - Widgets

    func testWidgetsShowTheInterruptionInPlaceOfCaughtUp() {
        let interrupted = self.makeSnapshot(audioInterrupted: true)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: interrupted, sourceKind: .observer), .audioInterrupted)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: interrupted), .audioInterrupted)
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: interrupted), .audioInterrupted)
        XCTAssertNil(ObserverStatusPresentation.audioInterrupted.count)
        XCTAssertNotEqual(ObserverStatusPresentation.audioInterrupted.symbol, ObserverStatusPresentation.caughtUp.symbol)
        XCTAssertNotEqual(ObserverStatusPresentation.audioInterrupted.label, ObserverStatusPresentation.caughtUp.label)

        let sending = self.makeSnapshot(backlogCount: 2, audioInterrupted: true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: sending), .waiting(count: 2))
        let held = self.makeSnapshot(awaitingMarkConfirmation: true, audioInterrupted: true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: held), .awaitingMarkConfirmation(count: 0))
        let unpaired = self.makeSnapshot(isPaired: false, audioInterrupted: true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: unpaired), .notPaired)

        let clean = self.makeSnapshot(audioInterrupted: false)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: clean, sourceKind: .observer), .caughtUp)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: clean), .caughtUp)
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: clean), .caughtUp)
    }

    func testWidgetSnapshotCarriesTheInterruptionAcrossWriters() throws {
        let rootURL = self.tempDirectory.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let mirror = AppGroupMirror(rootURLProvider: { rootURL })
        guard case .success = mirror.updateSessionAndSources(
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: .active],
            backlogCount: 0,
            awaitingMarkConfirmation: false,
            audioInterrupted: true
        ) else {
            return XCTFail("expected app group mirror write to succeed")
        }
        XCTAssertEqual(mirror.snapshot()?.audioInterrupted, true)

        guard case .success = ObserverCaptureControlMirrorWriter.update(
            session: .notLive,
            mirror: mirror,
            controls: AudioInterruptionControlReloadSpy()
        ) else {
            return XCTFail("expected capture control mirror write to succeed")
        }
        XCTAssertEqual(mirror.snapshot()?.audioInterrupted, true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: mirror.snapshot()), .audioInterrupted)

        var stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: rootURL.appendingPathComponent(AppGroupMirror.Snapshot.fileName)))
                as? [String: Any]
        )
        stored.removeValue(forKey: "audioInterrupted")
        let earlier = try JSONDecoder().decode(
            AppGroupMirror.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: stored)
        )
        XCTAssertFalse(earlier.audioInterrupted)
    }

    // MARK: - Helpers

    private func pill(waiting: Int, interrupted: Bool) -> HomeStatusPillState {
        HomeStatusPillState.resolve(
            isPaired: true,
            status: .connectedIdle,
            hasBacklog: waiting > 0,
            isStalled: false,
            awaitingMarkConfirmation: false,
            hasAudioInterruption: interrupted
        )
    }

    private func makeStore() -> MobileSegmentStore {
        MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
    }

    private func emptyTombstoneURL(_ segmentID: UUID, store: MobileSegmentStore) -> URL {
        store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(segmentID.uuidString).json")
    }

    private func writeActiveSegment(
        segmentID: UUID,
        store: MobileSegmentStore,
        sources: Set<MobileSegmentSource>,
        startedAt: Date? = nil
    ) throws -> URL {
        try store.createActive(manifest: MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt ?? self.clock.now().addingTimeInterval(-3_600),
            openedWithSources: sources,
            activeSourceSetVersion: 1
        ))
    }

    /// What a recorder killed mid-segment leaves: a container header and no index.
    private func writeUnreadableAudio(in directory: URL, store: MobileSegmentStore) throws {
        let audioURL = store.audioURL(in: directory)
        try MobileSegmentTestFixtures.writeFtypOnlyAudio(at: audioURL)
        try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
    }

    private func makeSnapshot(
        isPaired: Bool = true,
        backlogCount: Int = 0,
        awaitingMarkConfirmation: Bool = false,
        audioInterrupted: Bool
    ) -> AppGroupMirror.Snapshot {
        AppGroupMirror.Snapshot(
            schemaVersion: AppGroupMirror.Snapshot.currentSchemaVersion,
            writtenAt: Date(),
            pairing: AppGroupMirror.PairingSnapshot(journalName: isPaired ? "sol" : nil, isPaired: isPaired),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: .active],
            backlogCount: backlogCount,
            awaitingMarkConfirmation: awaitingMarkConfirmation,
            audioInterrupted: audioInterrupted
        )
    }
}
