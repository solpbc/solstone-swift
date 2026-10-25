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

        uploader.audioInspector = PhoneAudioInspector { _ in
            .permanent(domain: "AVFoundationErrorDomain", code: -11829)
        }
        await uploader.resumeFromDisk()

        let tombstone = try store.readTombstone(
            at: store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(segmentID.uuidString).json")
        )
        XCTAssertEqual(tombstone.reason, MobileSegmentUploader.undecodableAudioReason)
        let records = self.journalRecords(store)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, .diagnostic)
        XCTAssertEqual(records.first?.reason, MobileSegmentUploader.undecodableAudioReason)
        XCTAssertFalse(records.contains { $0.kind == .loss })

        let restarted = MobileSegmentUploader(store: store, clock: self.clock)
        XCTAssertEqual(self.journalRecords(store).count, 1)
        await restarted.resumeFromDisk()
        XCTAssertEqual(self.journalRecords(store).count, 1)

        for current in [uploader, restarted] {
            let waiting = current.pendingCount + current.failedCount + current.finalizeFailedCount
            XCTAssertEqual(waiting, 0)
            let pill = HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedIdle,
                hasBacklog: waiting > 0,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasJournalGap: false
            )
            XCTAssertEqual(pill, .caughtUp)
            let lead = StatusPaneLead.resolve(
                pillState: pill,
                waitingTotal: waiting,
                showsConnectionDetails: true
            )
            XCTAssertEqual(lead.headline, SourceVocabulary.syncedHeadline)
            XCTAssertFalse(lead.showsJournalGapNotice)
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
        uploader.audioInspector = PhoneAudioInspector { _ in
            .permanent(domain: "AVFoundationErrorDomain", code: -11829)
        }

        await uploader.resumeFromDisk()

        XCTAssertEqual(uploader.pendingCount, 1)
        let records = self.journalRecords(store)
        XCTAssertEqual(records.filter { $0.kind == .diagnostic }.count, 1)
        XCTAssertFalse(records.contains { $0.kind == .loss })
        XCTAssertFalse(store.hasTombstone(segmentID: segmentID, kind: "empty"))
        XCTAssertEqual(self.pill(waiting: uploader.pendingCount, gap: false), .syncing)

        try uploader.writeUploadedTombstone(segmentID: segmentID)

        XCTAssertEqual(uploader.pendingCount + uploader.failedCount, 0)
        XCTAssertEqual(self.journalRecords(store).filter { $0.kind == .diagnostic }.count, 1)
        XCTAssertEqual(self.pill(waiting: 0, gap: false), .caughtUp)
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
        try Data().write(to: store.screenPartURL(in: screenDirectory), options: .atomic)
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
        XCTAssertFalse(self.journalRecords(store).contains { $0.kind == .loss })

        try uploader.writeUploadedTombstone(segmentID: readable)
        XCTAssertEqual(self.pill(waiting: uploader.pendingCount, gap: false), .caughtUp)
    }

    func testRecordingStaysWhenItsInterruptionCannotBeRecorded() async throws {
        let store = self.makeStore()
        try store.ensureRoot()
        let eventsRoot = JournalEventStore.directory(besideMobileSegmentRoot: store.rootURL)
        try FileManager.default.createDirectory(at: eventsRoot, withIntermediateDirectories: true)
        let blocker = eventsRoot.appendingPathComponent("losses", isDirectory: false)
        try Data().write(to: blocker)
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        uploader.audioInspector = PhoneAudioInspector { _ in
            .permanent(domain: "AVFoundationErrorDomain", code: -11829)
        }
        let segmentID = UUID()
        let directory = try self.writeActiveSegment(segmentID: segmentID, store: store, sources: [.audio])
        let audioURL = store.audioURL(in: directory)
        try Self.writeExistedAudio(at: audioURL)
        try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
        try store.writeAudioWriterReceipt(
            PhoneAudioWriterReceipt(segmentID: segmentID, phase: .writing, acceptedFrames: 0),
            in: directory
        )

        await uploader.resumeFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(store.hasTombstone(segmentID: segmentID, kind: "empty"))
        let blockedStore = JournalEventStore(rootURL: eventsRoot)
        guard case .unreadable = blockedStore.readEvents() else {
            return XCTFail("a blocked losses directory still read as events")
        }

        try FileManager.default.removeItem(at: blocker)
        await uploader.resumeFromDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.hasTombstone(segmentID: segmentID, kind: "empty"))
        let losses = self.journalRecords(store).filter { $0.kind == .loss }
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses.first?.reason, "audio_capture_unfinished")
    }

    func testEarlierUnreadableAudioRecordsAreCarriedForwardOnce() async throws {
        let store = self.makeStore()
        try store.ensureRoot()
        let recordedAt = Date()
        let earlierRetired = UUID()
        try store.writeTombstone(
            segmentID: earlierRetired,
            kind: "empty",
            reason: MobileSegmentUploader.undecodableAudioReason,
            now: recordedAt.addingTimeInterval(-86_400)
        )
        for reason in ["unrecoverable_lost_data", "no_artifacts", "screencast_removed"] {
            try store.writeTombstone(segmentID: UUID(), kind: "empty", reason: reason, now: recordedAt)
        }
        try store.writeTombstone(segmentID: UUID(), kind: "uploaded", reason: "delivered", now: recordedAt)
        let earlierWaiting = UUID()
        let waitingDirectory = try self.writeActiveSegment(segmentID: earlierWaiting, store: store, sources: [.audio, .location])
        var manifest = try store.readManifest(in: waitingDirectory)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .removed,
                reason: MobileSegmentUploader.undecodableAudioReason,
                stage: "AVFoundationErrorDomain -11829",
                lastAttemptAt: recordedAt
            ),
            source: .audio,
            manifest: &manifest,
            in: waitingDirectory,
            now: recordedAt
        )
        _ = try store.move(segmentID: earlierWaiting, from: .active, to: .failed)

        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        await uploader.resumeFromDisk()

        let legacy = self.journalRecords(store).filter { $0.kind == .legacy }
        XCTAssertEqual(legacy.count, 2)
        XCTAssertFalse(self.journalRecords(store).contains { $0.kind == .loss })
        XCTAssertFalse(uploader.journalGapNotice.isShowing)

        await uploader.resumeFromDisk()
        XCTAssertEqual(self.journalRecords(store).filter { $0.kind == .legacy }.count, 2)
    }

    // MARK: - Pill and pane

    func testPillShowsTheInterruptionOnlyWhereItWouldOtherwiseClaimCaughtUp() {
        let cases: [(ConnectionSyncStatus, Bool, Bool, Bool, HomeStatusPillState)] = [
            (.connectedIdle, false, false, false, .journalGap),
            (.connectedWaiting, false, false, false, .journalGap),
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
                    hasJournalGap: true
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
                hasJournalGap: true
            ),
            .notPaired
        )
        XCTAssertEqual(self.pill(waiting: 0, gap: false), .caughtUp)
        XCTAssertEqual(HomeStatusPillState.journalGap.label, SourceVocabulary.journalGapHeadline)
        XCTAssertNotEqual(HomeStatusPillState.journalGap.label, HomeStatusPillState.caughtUp.label)
        XCTAssertFalse(HomeStatusPillState.journalGap.shouldPulse(reduceMotion: false))
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
            let dayLine = SourceVocabulary.journalGapToday
            let withNotice = StatusPaneLead.resolve(
                pillState: pillState,
                waitingTotal: waiting,
                showsConnectionDetails: false,
                gapDayLine: dayLine
            )
            let without = StatusPaneLead.resolve(
                pillState: pillState,
                waitingTotal: waiting,
                showsConnectionDetails: false
            )
            XCTAssertTrue(withNotice.showsJournalGapNotice, "\(pillState) \(waiting)")
            XCTAssertEqual(withNotice.journalGapDayLine, dayLine)
            XCTAssertFalse(without.showsJournalGapNotice, "\(pillState) \(waiting)")
            XCTAssertEqual(withNotice.lead, without.lead)
            XCTAssertEqual(withNotice.region, without.region)
        }

        let clean = StatusPaneLead.resolve(pillState: .caughtUp, waitingTotal: 0, showsConnectionDetails: true)
        XCTAssertEqual(clean.headline, SourceVocabulary.syncedHeadline)
        XCTAssertFalse(clean.showsJournalGapNotice)

        let gap = StatusPaneLead.resolve(
            pillState: .journalGap,
            waitingTotal: 0,
            showsConnectionDetails: true,
            gapDayLine: SourceVocabulary.journalGapToday
        )
        XCTAssertEqual(gap.headline, SourceVocabulary.journalGapHeadline)
        XCTAssertEqual(gap.subline, SourceVocabulary.journalGapToday)
        XCTAssertFalse(gap.showsJournalGapNotice)
        XCTAssertEqual(gap.region, clean.region)
        XCTAssertNil(gap.buttonTitle)
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
            hasJournalGap: true
        )
        XCTAssertEqual(interrupted.role, .journalGap)
        let clean = onThisPhoneHeadline(
            migration: drained,
            isPaired: true,
            isConnected: true,
            awaitingMarkConfirmation: false,
            isStalled: false,
            connectionStatus: .connectedIdle,
            hasJournalGap: false
        )
        XCTAssertEqual(clean.role, .upToDate)
        let sending = onThisPhoneHeadline(
            migration: OnThisPhoneMigration(onThisPhone: 2, needsAttention: 0),
            isPaired: true,
            isConnected: true,
            awaitingMarkConfirmation: false,
            isStalled: false,
            connectionStatus: .connectedTransferring,
            hasJournalGap: true
        )
        XCTAssertEqual(sending.role, .syncing)

        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: true, hasWelcomeFraming: false, hasJournalGap: true),
            .journalGap
        )
        XCTAssertEqual(
            onThisPhoneEmptyInviteBranch(isJournalPaired: true, hasWelcomeFraming: false, hasJournalGap: false),
            .allQuiet
        )
    }

    // MARK: - Widgets

    func testWidgetsShowTheInterruptionInPlaceOfCaughtUp() {
        let interrupted = self.makeSnapshot(journalGap: true)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: interrupted, sourceKind: .observer), .journalGap)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: interrupted), .journalGap)
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: interrupted), .journalGap)
        XCTAssertNil(ObserverStatusPresentation.journalGap.count)
        XCTAssertEqual(ObserverStatusPresentation.journalGap.symbol, "calendar.badge.minus")
        XCTAssertEqual(ObserverStatusPresentation.journalGap.label, SourceVocabulary.journalGapHeadline)
        XCTAssertNotEqual(ObserverStatusPresentation.journalGap.symbol, ObserverStatusPresentation.caughtUp.symbol)

        let sending = self.makeSnapshot(backlogCount: 2, journalGap: true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: sending), .waiting(count: 2))
        let held = self.makeSnapshot(awaitingMarkConfirmation: true, journalGap: true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: held), .awaitingMarkConfirmation(count: 0))
        let unpaired = self.makeSnapshot(isPaired: false, journalGap: true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: unpaired), .notPaired)

        let clean = self.makeSnapshot(journalGap: false)
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
            journalGap: true
        ) else {
            return XCTFail("expected app group mirror write to succeed")
        }
        XCTAssertEqual(mirror.snapshot()?.journalGap, true)

        guard case .success = ObserverCaptureControlMirrorWriter.update(
            session: .notLive,
            mirror: mirror,
            controls: AudioInterruptionControlReloadSpy()
        ) else {
            return XCTFail("expected capture control mirror write to succeed")
        }
        XCTAssertEqual(mirror.snapshot()?.journalGap, true)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: mirror.snapshot()), .journalGap)

        var stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: rootURL.appendingPathComponent(AppGroupMirror.Snapshot.fileName)))
                as? [String: Any]
        )
        stored.removeValue(forKey: "journalGap")
        stored["audioInterrupted"] = true
        let earlier = try JSONDecoder().decode(
            AppGroupMirror.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: stored)
        )
        XCTAssertFalse(earlier.journalGap)
    }

    // MARK: - Helpers

    private func pill(waiting: Int, gap: Bool) -> HomeStatusPillState {
        HomeStatusPillState.resolve(
            isPaired: true,
            status: .connectedIdle,
            hasBacklog: waiting > 0,
            isStalled: false,
            awaitingMarkConfirmation: false,
            hasJournalGap: gap
        )
    }

    private func journalRecords(_ store: MobileSegmentStore, file: StaticString = #filePath, line: UInt = #line) -> [JournalEventRecord] {
        let events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: store.rootURL))
        guard case .events(let records) = events.readEvents() else {
            XCTFail("journal events unreadable", file: file, line: line)
            return []
        }
        return records
    }

    /// A delimited phone file with an `mdat` payload of 16 bytes. The box walker calls this existed.
    private static func writeExistedAudio(at url: URL) throws {
        var bytes = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x6D, 0x70, 0x34, 0x32,
            0x00, 0x00, 0x00, 0x00,
            0x69, 0x73, 0x6F, 0x6D,
            0x6D, 0x70, 0x34, 0x32,
        ])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x18, 0x6D, 0x64, 0x61, 0x74])
        bytes.append(contentsOf: [UInt8](repeating: 0x11, count: 16))
        try bytes.write(to: url, options: .atomic)
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
        journalGap: Bool
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
            journalGap: journalGap
        )
    }
}
