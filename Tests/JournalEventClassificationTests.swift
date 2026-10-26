// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import XCTest

/// Each deletion and publish path records a loss, a diagnostic, or nothing, from the file itself.
@MainActor
final class JournalEventClassificationTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: MobileSegmentStore!
    private var clock: MockObserverClock!
    private var uploader: MobileSegmentUploader!

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalEventClassification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
        self.uploader = MobileSegmentUploader(store: self.store, clock: self.clock, audioInspector: Self.permanentInspector)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.uploader = nil
        self.store = nil
        self.clock = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testPermanentRemovalRecordsALossOnlyWhenTheAudioExisted() async throws {
        let writing = try await self.resolveAudio(
            bytes: Self.fortyEightByteAudio,
            receipt: .writing,
            frames: 0
        )
        XCTAssertEqual(writing.resolution, .retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writing.audioURL.path))
        let writingLoss = try self.record(segmentID: writing.segmentID, kind: .loss, reason: "audio_capture_unfinished")
        XCTAssertEqual(writingLoss.source, .audio)

        let faulted = try await self.resolveAudio(
            bytes: Self.ftypOnly,
            receipt: .faulted,
            frames: 0,
            faultReason: "audio_writer_failed"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: faulted.audioURL.path))
        XCTAssertEqual(
            try self.record(segmentID: faulted.segmentID, kind: .diagnostic, reason: "audio_writer_failed").kind,
            .diagnostic
        )
        XCTAssertFalse(try self.records(segmentID: faulted.segmentID).contains { $0.kind == .loss })

        let absent = try await self.resolveAudio(bytes: Self.ftypOnly, receipt: nil, frames: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.audioURL.path))
        XCTAssertEqual(
            try self.record(segmentID: absent.segmentID, kind: .diagnostic, reason: "audio_undecodable_container").kind,
            .diagnostic
        )

        let existedAbsent = try await self.resolveAudio(bytes: Self.fortyEightByteAudio, receipt: nil, frames: 0)
        XCTAssertEqual(
            try self.record(segmentID: existedAbsent.segmentID, kind: .loss, reason: "audio_undecodable_container").kind,
            .loss
        )

        try self.replaceDirectory(self.eventsDirectory("diagnostics"), withFile: Data("blocked".utf8))
        let stillDeleted = try await self.resolveAudio(bytes: Self.ftypOnly, receipt: nil, frames: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stillDeleted.audioURL.path))

        try self.replaceDirectory(self.eventsDirectory("losses"), withFile: Data("blocked".utf8))
        let kept = try self.parkFailedAudio(bytes: Self.fortyEightByteAudio, receipt: .writing, frames: 0, faultReason: nil)
        do {
            _ = try await self.uploader.resolveFinalizeFailure(segmentID: kept.segmentID, directory: kept.directory, lifecycle: .failed)
            XCTFail("a loss that cannot be recorded still deleted the audio")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.audioURL.path))
        }
    }

    func testPublishArmsRecordADiagnosticAndLeaveTheFile() async throws {
        self.uploader.audioInspector = Self.durationInspector(10)
        let writing = try await self.resolveAudio(bytes: Self.ftypOnly, receipt: .writing, frames: 0)
        XCTAssertEqual(writing.resolution, .repend)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writing.audioURL.path))
        XCTAssertEqual(
            try self.record(segmentID: writing.segmentID, kind: .diagnostic, reason: "audio_capture_unfinished").kind,
            .diagnostic
        )
        XCTAssertFalse(try self.records(segmentID: writing.segmentID).contains { $0.kind == .loss })

        let faulted = try await self.resolveAudio(
            bytes: Self.ftypOnly,
            receipt: .faulted,
            frames: 0,
            faultReason: "audio_writer_failed"
        )
        XCTAssertEqual(faulted.resolution, .repend)
        XCTAssertTrue(FileManager.default.fileExists(atPath: faulted.audioURL.path))
        XCTAssertEqual(
            try self.record(segmentID: faulted.segmentID, kind: .diagnostic, reason: "audio_writer_failed").id.hasSuffix("-fault"),
            false
        )

        let mismatch = try await self.resolveAudio(bytes: Self.ftypOnly, receipt: .completed, frames: 16_000)
        XCTAssertEqual(mismatch.resolution, .repend)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatch.audioURL.path))
        XCTAssertEqual(
            try self.record(segmentID: mismatch.segmentID, kind: .diagnostic, reason: "audio_writer_duration_mismatch").kind,
            .diagnostic
        )

        self.uploader.audioInspector = Self.permanentInspector
        let headerOnly = try await self.resolveAudio(bytes: Self.ftypOnly, receipt: .completed, frames: 0)
        XCTAssertEqual(headerOnly.resolution, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: headerOnly.audioURL.path))
        XCTAssertTrue(try self.records(segmentID: headerOnly.segmentID).isEmpty)

        let completedPermanent = try await self.resolveAudio(bytes: Self.fortyEightByteAudio, receipt: .completed, frames: 16_000)
        XCTAssertEqual(completedPermanent.resolution, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedPermanent.audioURL.path))
        XCTAssertFalse(try self.records(segmentID: completedPermanent.segmentID).contains { $0.kind == .loss })

        try self.replaceDirectory(self.eventsDirectory("diagnostics"), withFile: Data("blocked".utf8))
        self.uploader.audioInspector = Self.durationInspector(10)
        let publishedAnyway = try await self.resolveAudio(bytes: Self.ftypOnly, receipt: .writing, frames: 0)
        XCTAssertEqual(publishedAnyway.resolution, .repend)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedAnyway.audioURL.path))
    }

    func testWriterFaultIsOneDiagnosticAndALaterLossIsTheOtherFile() async throws {
        let segmentID = UUID()
        let sessionID = UUID()
        let directory = self.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let audioURL = self.store.audioURL(in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try PhoneAudioFragmentWriter(
            url: audioURL,
            segmentID: segmentID,
            sessionID: sessionID,
            sourceFormat: format,
            clock: self.clock,
            journalEventsDirectory: self.uploader.journalEvents.rootURL
        )
        await writer.latchFault(reason: "audio_writer_failed")
        await writer.latchFault(reason: "audio_writer_failed")
        let faultID = JournalEventStore.diagnosticID(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            writerFault: true
        )
        let fault = try self.record(id: faultID)
        XCTAssertEqual(fault.count, 1)
        XCTAssertTrue(fault.id.hasSuffix("-fault"))

        try self.uploader.journalEvents.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: nil,
            now: self.clock.now(),
            writerFault: true
        )
        XCTAssertEqual(try self.record(id: faultID).count, 2)

        let engine = MobileSegmentEngine(uploader: self.uploader, clock: self.clock)
        let recorder = MockObserverRecorder()
        let manager = ObserverManager(
            recorder: recorder,
            mobileSegmentEngine: engine,
            journalEvents: self.uploader.journalEvents,
            clock: self.clock
        )
        recorder.emitPhoneAudioFault(
            PhoneAudioWriterFault(segmentID: segmentID, sessionID: sessionID, reason: "audio_writer_failed")
        )
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(try self.records(segmentID: segmentID).count, 1)

        try self.uploader.journalEvents.openGate(now: self.clock.now())
        try self.uploader.journalEvents.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.clock.now(),
            now: self.clock.now()
        )
        let rows = try self.records(segmentID: segmentID)
        XCTAssertEqual(rows.filter { $0.kind == .diagnostic }.count, 1)
        XCTAssertEqual(rows.filter { $0.kind == .loss }.count, 1)
        await self.uploader.refreshJournalGapNotice()
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedIdle,
                hasBacklog: false,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasJournalGap: self.uploader.journalGapNotice.isShowing
            ),
            .journalGap
        )
    }

    func testScreencastRemovalRecordsOneEventForTheScreenFiles() async throws {
        let existed = try await self.resolveScreen(file: Data("partial-screen".utf8), name: "screen.mp4")
        XCTAssertEqual(existed.resolution, .retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existed.fileURL.path))
        XCTAssertEqual(
            try self.record(segmentID: existed.segmentID, kind: .loss, reason: "screencast_removed").source,
            .screencast
        )

        let header = try await self.resolveScreen(file: Self.ftypOnly, name: "screen.mp4.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: header.fileURL.path))
        XCTAssertEqual(
            try self.record(segmentID: header.segmentID, kind: .diagnostic, reason: "screencast_removed").kind,
            .diagnostic
        )

        let absent = try self.parkFailed(sources: [.screencast], failed: [.screencast]) { _, _, _ in }
        let absentResolution = try await self.uploader.resolveFinalizeFailure(
            segmentID: absent.segmentID,
            directory: absent.directory,
            lifecycle: .failed
        )
        XCTAssertEqual(absentResolution, .retired)
        XCTAssertTrue(try self.records(segmentID: absent.segmentID).isEmpty)

        try self.replaceDirectory(self.eventsDirectory("losses"), withFile: Data("blocked".utf8))
        let kept = try await self.parkScreenFile(Data("partial-screen".utf8), name: "screen.mp4")
        do {
            _ = try await self.uploader.resolveFinalizeFailure(segmentID: kept.segmentID, directory: kept.directory, lifecycle: .failed)
            XCTFail("a screen loss that cannot be recorded still deleted the file")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.fileURL.path))
        }
    }

    func testUnplayableScreenPartUsesExistenceForTheKind() async throws {
        let header = try await self.finalizeScreenPart(Self.ftypOnly, name: "screen.mp4.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: header.fileURL.path))
        XCTAssertEqual(
            try self.record(segmentID: header.segmentID, kind: .diagnostic, reason: "screencast_unplayable_part").source,
            .screencast
        )

        let existed = try await self.finalizeScreenPart(Data("partial-screen".utf8), name: "screen.mp4.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: existed.fileURL.path))
        XCTAssertEqual(
            try self.record(segmentID: existed.segmentID, kind: .loss, reason: "screencast_unplayable_part").kind,
            .loss
        )

        let absent = try self.openActive(sources: [.screencast])
        await self.uploader.finalizeActiveSegment(segmentID: absent.segmentID, endedAt: self.clock.now())
        XCTAssertTrue(try self.records(segmentID: absent.segmentID).isEmpty)

        try self.replaceDirectory(self.eventsDirectory("losses"), withFile: Data("blocked".utf8))
        let kept = try self.openActive(sources: [.screencast])
        let part = kept.directory.appendingPathComponent("screen.mp4.part")
        try Data("partial-screen".utf8).write(to: part)
        await self.uploader.finalizeActiveSegment(segmentID: kept.segmentID, endedAt: self.clock.now())
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
    }

    func testScreenAudioPartAndPromotedAudioFollowSize() async throws {
        let header = try await self.finalizeScreenPart(Self.ftypOnly, name: "screen-audio.m4a.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: header.fileURL.path))
        XCTAssertEqual(
            try self.record(segmentID: header.segmentID, kind: .diagnostic, reason: "screencast_unplayable_part").source,
            .screenAudio
        )

        let existed = try await self.finalizeScreenPart(Data("partial-screen-audio".utf8), name: "screen-audio.m4a.part")
        XCTAssertEqual(
            try self.record(segmentID: existed.segmentID, kind: .loss, reason: "screencast_unplayable_part").source,
            .screenAudio
        )

        let empty = try self.openActive(sources: [.screencast])
        try Data().write(to: self.store.audioURL(in: empty.directory))
        await self.uploader.finalizeActiveSegment(segmentID: empty.segmentID, endedAt: self.clock.now())
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.store.audioURL(in: empty.directory).path))
        XCTAssertEqual(
            try self.record(segmentID: empty.segmentID, kind: .diagnostic, reason: "audio_empty_promoted").source,
            .audio
        )

        let promoted = try self.openActive(sources: [.screencast])
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: promoted.directory))
        await self.uploader.finalizeActiveSegment(segmentID: promoted.segmentID, endedAt: self.clock.now())
        let kept = try XCTUnwrap(self.store.findDirectory(segmentID: promoted.segmentID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.store.audioURL(in: kept.url).path))
        XCTAssertTrue(try self.records(segmentID: promoted.segmentID).isEmpty)

        let stat = StatFailingFileManager()
        let root = self.tempDirectory.appendingPathComponent("nil-size-segment", isDirectory: true)
        let nilStore = MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true), fileManager: stat)
        let nilUploader = MobileSegmentUploader(store: nilStore, clock: self.clock)
        let segmentID = UUID()
        let directory = try nilStore.createActive(manifest: MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: self.clock.now().addingTimeInterval(-3_600),
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        ))
        let audioURL = nilStore.audioURL(in: directory)
        try Data("promoted-but-unreadable".utf8).write(to: audioURL)
        stat.blockedPath = audioURL.path
        await nilUploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        guard case .events(let rows) = nilUploader.journalEvents.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertTrue(rows.isEmpty)
    }

    func testMissingAudioIsALossOnlyWhenFramesWereAccepted() async throws {
        let accepted = try await self.resolveMissingAudio(frames: 32_000, phase: .completed)
        XCTAssertEqual(
            try self.record(segmentID: accepted.segmentID, kind: .loss, reason: "audio_no_local_data").kind,
            .loss
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: accepted.directory.path))

        let empty = try await self.resolveMissingAudio(frames: 0, phase: .writing)
        XCTAssertEqual(
            try self.record(segmentID: empty.segmentID, kind: .diagnostic, reason: "audio_no_local_data").kind,
            .diagnostic
        )
        XCTAssertFalse(try self.records(segmentID: empty.segmentID).contains { $0.kind == .loss })

        let parked = try self.openActive(sources: [.audio])
        await self.uploader.finalizeActiveSegment(segmentID: parked.segmentID, endedAt: self.clock.now())
        let found = try XCTUnwrap(self.store.findDirectory(segmentID: parked.segmentID))
        XCTAssertEqual(found.lifecycle, .failed)
        let manifest = try self.store.readManifest(in: found.url)
        XCTAssertEqual(manifest.audio.state, .failedToFinalize)
        XCTAssertTrue(try self.records(segmentID: parked.segmentID).isEmpty)

        try self.replaceDirectory(self.eventsDirectory("losses"), withFile: Data("blocked".utf8))
        let kept = try self.parkMissingAudio(frames: 32_000, phase: .faulted, faultReason: "audio_writer_failed")
        do {
            _ = try await self.uploader.resolveFinalizeFailure(segmentID: kept.segmentID, directory: kept.directory, lifecycle: .failed)
            XCTFail("a missing-audio loss that cannot be recorded still retired the segment")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.directory.path))
            XCTAssertFalse(self.store.hasTombstone(segmentID: kept.segmentID, kind: "empty"))
        }
    }

    func testOwnerRemovalIsADiagnosticAndNeverALoss() throws {
        let plain = try self.openActive(sources: [.audio])
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: plain.directory))
        self.uploader.dropSegment(segmentID: plain.segmentID)
        XCTAssertNil(self.store.findDirectory(segmentID: plain.segmentID))
        let plainRows = try self.records(segmentID: plain.segmentID)
        XCTAssertEqual(plainRows.map(\.kind), [.diagnostic])
        XCTAssertEqual(plainRows.map(\.reason), ["owner_removed"])

        let undecodable = try self.openActive(sources: [.audio])
        var manifest = try self.store.readManifest(in: undecodable.directory)
        try self.store.writeOutcome(
            MobileSegmentSourceResolution(state: .noArtifact, reason: "audio_undecodable_container"),
            source: .audio,
            manifest: &manifest,
            in: undecodable.directory,
            now: self.clock.now()
        )
        self.uploader.dropSegment(segmentID: undecodable.segmentID)
        XCTAssertTrue(self.store.hasTombstone(segmentID: undecodable.segmentID, kind: "empty"))
        XCTAssertFalse(try self.records().contains { $0.kind == .loss })
    }

    func testOwnerRemovalRemovesKeptPartsWhenTheEventStoreFails() throws {
        let opened = try self.openActive(sources: [.screencast])
        try Data("kept".utf8).write(to: self.store.screenPartURL(in: opened.directory))
        try Data("kept-numbered".utf8).write(to: opened.directory.appendingPathComponent("screen.mp4.part.1"))
        let events = self.uploader.journalEvents.rootURL
        try FileManager.default.createDirectory(at: events.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: events)
        try Data("blocked".utf8).write(to: events)

        self.uploader.dropSegment(segmentID: opened.segmentID)

        XCTAssertNil(self.store.findDirectory(segmentID: opened.segmentID))
        try FileManager.default.removeItem(at: events)
    }

    func testAnOwnerRemovalThatCannotRemoveIsReportedAndTheRowStays() throws {
        let fileManager = RemoveFailingFileManager()
        let store = MobileSegmentStore(
            rootURL: self.tempDirectory.appendingPathComponent("remove-failing/MobileSegment", isDirectory: true),
            fileManager: fileManager
        )
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let directory = try store.createActive(manifest: MobileSegmentManifest(
            segmentID: UUID(),
            startedAt: self.clock.now(),
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        ))
        let segmentID = try XCTUnwrap(UUID(uuidString: directory.lastPathComponent))
        fileManager.blockedPath = directory.path

        uploader.dropSegment(segmentID: segmentID)

        XCTAssertNotNil(store.findDirectory(segmentID: segmentID))
        XCTAssertEqual(uploader.lastError, "mobile segment owner removal failed segment=\(segmentID.uuidString)")
        guard case .events(let rows) = uploader.journalEvents.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertFalse(rows.contains { $0.segmentID == segmentID.uuidString })
    }

    func testRetirementStillRefusesADirectoryWithAnUnrecordedKeptPart() throws {
        let opened = try self.openActive(sources: [.screencast])
        try Data("kept".utf8).write(to: self.store.screenPartURL(in: opened.directory))
        XCTAssertThrowsError(try self.store.remove(opened.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.directory.path))
    }

    func testOwnerScreenRemovalIsADiagnosticAndNeverALoss() async throws {
        let opened = try self.openActive(sources: [.screencast])
        let screen = self.store.screenURL(in: opened.directory)
        try Data("partial-screen".utf8).write(to: screen)
        var manifest = try self.store.readManifest(in: opened.directory)
        try self.store.writeOutcome(
            MobileSegmentSourceResolution(state: .finalizedArtifact, artifactFilename: "screen.mp4", bytes: 14),
            source: .screencast,
            manifest: &manifest,
            in: opened.directory,
            now: self.clock.now()
        )
        await self.uploader.redactScreencastFacet(segmentID: opened.segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: screen.path))
        XCTAssertEqual(try self.records().map(\.reason), ["owner_removed"])
        XCTAssertFalse(try self.records().contains { $0.kind == .loss })
    }

    func testScreenRedactionKeepsAudioAndLocationAndRemovesEveryScreenPart() async throws {
        let opened = try self.openActive(sources: [.audio, .location, .screencast])
        var manifest = try self.store.readManifest(in: opened.directory)
        for (source, url) in [
            (MobileSegmentSource.audio, self.store.audioURL(in: opened.directory)),
            (.location, self.store.locationURL(in: opened.directory)),
            (.screencast, self.store.screenURL(in: opened.directory)),
        ] {
            try Data("\(source.rawValue)-bytes".utf8).write(to: url)
            try self.store.writeOutcome(
                MobileSegmentSourceResolution(state: .finalizedArtifact, artifactFilename: url.lastPathComponent, bytes: 12),
                source: source,
                manifest: &manifest,
                in: opened.directory,
                now: self.clock.now()
            )
        }
        for name in ["screen.mp4.part", "screen.mp4.part.1", "screen-audio.m4a", "screen-audio.m4a.part", "screen-audio.m4a.part.2"] {
            try Data("screen-material".utf8).write(to: opened.directory.appendingPathComponent(name))
        }

        await self.uploader.redactScreencastFacet(segmentID: opened.segmentID)

        let found = try XCTUnwrap(self.store.findDirectory(segmentID: opened.segmentID))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: found.url.path))
        XCTAssertTrue(names.contains("audio.m4a"))
        XCTAssertTrue(names.contains(self.store.locationURL(in: found.url).lastPathComponent))
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix("screen.mp4") && !$0.hasPrefix("screen-audio.m4a") })
        XCTAssertFalse(try self.records().contains { $0.kind == .loss })
    }

    func testDeliveredResidueWritesNoJournalEvent() throws {
        let opened = try self.openActive(sources: [.audio])
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: opened.directory))
        let pending = try self.store.move(segmentID: opened.segmentID, from: .active, to: .pending)
        try self.uploader.writeUploadedTombstone(segmentID: opened.segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(self.store.hasTombstone(segmentID: opened.segmentID, kind: "uploaded"))
        XCTAssertTrue(try self.records().isEmpty)
    }

    func testTransferResidueAndTempCleanupWriteNoJournalEvent() async throws {
        let segmentID = UUID()
        let directory = self.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-a-manifest".utf8).write(to: self.store.manifestURL(in: directory))
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: directory))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentTransferEnqueue", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let tempFile = tempRoot.appendingPathComponent("enqueue-body", isDirectory: false)
        try Data("temp".utf8).write(to: tempFile)

        let part = self.tempDirectory.appendingPathComponent("screen.mp4.part")
        let final = self.tempDirectory.appendingPathComponent("screen.mp4")
        try Data("previous".utf8).write(to: final)
        try Data("replacement".utf8).write(to: part)

        await self.uploader.resumeFromDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.path))
        try MobileSegmentScreencastJSONStore.finalizePart(partURL: part, finalURL: final)
        XCTAssertEqual(try Data(contentsOf: final), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))

        let removable = try self.openActive(sources: [.audio])
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: removable.directory))
        try self.store.remove(removable.directory)
        XCTAssertTrue(try self.records().isEmpty)
    }

    func testReplacingAnExistingFinalRecordsTheFileThatWasThere() throws {
        let segmentID = UUID()
        let now = self.clock.now()
        let part = self.tempDirectory.appendingPathComponent("final-part.mp4")
        let final = self.tempDirectory.appendingPathComponent("final-screen.mp4")
        try Data("previous".utf8).write(to: final)
        try Data("replacement".utf8).write(to: part)
        let replacement = JournalFinalReplacement(
            segmentID: segmentID,
            source: .screencast,
            captureAt: now,
            now: now,
            eventsRoot: self.uploader.journalEvents.rootURL
        )
        try MobileSegmentScreencastJSONStore.finalizePart(
            partURL: part,
            finalURL: final,
            replacement: replacement
        )
        XCTAssertEqual(try Data(contentsOf: final), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(
            try self.record(segmentID: segmentID, kind: .loss, reason: JournalFinalReplacement.reason).kind,
            .loss
        )

        let sameID = UUID()
        let samePart = self.tempDirectory.appendingPathComponent("same-part.mp4")
        let sameFinal = self.tempDirectory.appendingPathComponent("same-final.mp4")
        try Data("same-bytes".utf8).write(to: samePart)
        try Data("same-bytes".utf8).write(to: sameFinal)
        try MobileSegmentScreencastJSONStore.finalizePart(
            partURL: samePart,
            finalURL: sameFinal,
            replacement: JournalFinalReplacement(
                segmentID: sameID,
                source: .screencast,
                captureAt: now,
                now: now,
                eventsRoot: self.uploader.journalEvents.rootURL
            )
        )
        XCTAssertTrue(try self.records(segmentID: sameID).isEmpty)

        try self.replaceDirectory(self.eventsDirectory("losses"), withFile: Data("blocked".utf8))
        let keptPart = self.tempDirectory.appendingPathComponent("kept-part.mp4")
        let keptFinal = self.tempDirectory.appendingPathComponent("kept-final.mp4")
        try Data("new-part".utf8).write(to: keptPart)
        try Data("old-final".utf8).write(to: keptFinal)
        XCTAssertNoThrow(
            try MobileSegmentScreencastJSONStore.finalizePart(
                partURL: keptPart,
                finalURL: keptFinal,
                replacement: JournalFinalReplacement(
                    segmentID: UUID(),
                    source: .screencast,
                    captureAt: now,
                    now: now,
                    eventsRoot: self.uploader.journalEvents.rootURL
                )
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptPart.path))
        XCTAssertEqual(try Data(contentsOf: keptFinal), Data("old-final".utf8))
    }

    func testUnreadableScreenAudioPartSurvivesEmptyRetirement() async throws {
        let stat = StatFailingFileManager()
        let statStore = MobileSegmentStore(
            rootURL: self.tempDirectory.appendingPathComponent("unreadable-audio-part/MobileSegment", isDirectory: true),
            fileManager: stat
        )
        let uploader = MobileSegmentUploader(store: statStore, clock: self.clock)
        let segmentID = UUID()
        let directory = try statStore.createActive(manifest: MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: self.clock.now().addingTimeInterval(-10),
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        ))
        var manifest = try statStore.readManifest(in: directory)
        try statStore.writeOutcome(
            MobileSegmentSourceResolution(state: .noArtifact, reason: "screencast_removed"),
            source: .screencast,
            manifest: &manifest,
            in: directory,
            now: self.clock.now()
        )
        let part = statStore.screenAudioPartURL(in: directory)
        try Data("partial-screen-audio".utf8).write(to: part)
        stat.blockedPath = part.path
        await uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        XCTAssertNotNil(statStore.findDirectory(segmentID: segmentID))
    }

    func testRootMigrationWritesNoJournalEventAndLeavesTheCachesRoot() throws {
        let legacy = self.tempDirectory.appendingPathComponent("CachesMobileSegment", isDirectory: true)
        let segmentID = UUID()
        let source = legacy
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent(segmentID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("cached-audio".utf8).write(to: source.appendingPathComponent("audio.m4a"))
        let suite = "journal-gap-migrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = self.store.migrateRoot(fromLegacyCachesRoot: legacy, defaults: defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.store.segmentDirectoryURL(.active, segmentID: segmentID).appendingPathComponent("audio.m4a").path))
        XCTAssertTrue(try self.records().isEmpty)
    }

    func testRollbackRecordsAnEmptyKeptPartAndDeletesItEvenWhenTheRecordFails() throws {
        let recorded = try self.openActive(sources: [.screencast])
        try Data().write(to: recorded.directory.appendingPathComponent("screen.mp4.part.1"))
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: recorded.segmentID, now: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: recorded.segmentID))
        let rows = try self.records(segmentID: recorded.segmentID)
        XCTAssertEqual(rows.map(\.kind), [.diagnostic])
        XCTAssertEqual(rows.map(\.reason), ["empty_part"])

        let blocked = try self.openActive(sources: [.screencast])
        try Data().write(to: blocked.directory.appendingPathComponent("screen.mp4.part.1"))
        let events = self.uploader.journalEvents.rootURL
        try FileManager.default.createDirectory(at: events.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: events)
        try Data("blocked".utf8).write(to: events)
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: blocked.segmentID, now: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: blocked.segmentID))
        try FileManager.default.removeItem(at: events)
    }

    func testRollbackRemovesOnlyAProvenEmptyCandidate() throws {
        let missing = UUID()
        let missingURL = self.store.segmentDirectoryURL(.active, segmentID: missing)
        try Data("not-a-directory".utf8).write(to: missingURL)
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: missing, now: self.clock.now())
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingURL.path))

        let leased = try self.openActive(sources: [.audio])
        PhoneAudioWriterLease.acquire(leased.segmentID)
        defer { PhoneAudioWriterLease.release(leased.segmentID) }
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: leased.segmentID, now: self.clock.now())
        XCTAssertNotNil(self.store.findDirectory(segmentID: leased.segmentID))
        PhoneAudioWriterLease.release(leased.segmentID)

        let empty = try self.openActive(sources: [.screencast])
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: empty.segmentID, now: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: empty.segmentID))

        let header = try self.openActive(sources: [.audio])
        try Self.ftypOnly.write(to: self.store.audioURL(in: header.directory))
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: header.segmentID, now: self.clock.now())
        XCTAssertNotNil(self.store.findDirectory(segmentID: header.segmentID))
        XCTAssertTrue(try self.records(segmentID: header.segmentID).isEmpty)

        let receiptOnly = try self.openActive(sources: [.audio])
        try self.store.writeAudioWriterReceipt(
            PhoneAudioWriterReceipt(segmentID: receiptOnly.segmentID, phase: .writing, acceptedFrames: 0),
            in: receiptOnly.directory
        )
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: receiptOnly.segmentID, now: self.clock.now())
        XCTAssertNotNil(self.store.findDirectory(segmentID: receiptOnly.segmentID))

        let screenHeader = try self.openActive(sources: [.screencast])
        try Data().write(to: self.store.screenURL(in: screenHeader.directory))
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: screenHeader.segmentID, now: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: screenHeader.segmentID))

        let existed = try self.openActive(sources: [.audio])
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: existed.directory))
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: existed.segmentID, now: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: existed.segmentID))
        XCTAssertEqual(
            try self.record(segmentID: existed.segmentID, kind: .loss, reason: "segment_rollback").source,
            .audio
        )

        let screen = try self.openActive(sources: [.screencast])
        try Data("partial-screen".utf8).write(to: self.store.screenURL(in: screen.directory))
        try Data("partial-audio".utf8).write(to: self.store.screenAudioURL(in: screen.directory))
        try self.uploader.discardUnprovenRollbackCandidate(segmentID: screen.segmentID, now: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: screen.segmentID))
        let screenRows = try self.records(segmentID: screen.segmentID)
        XCTAssertEqual(Set(screenRows.map(\.source)), [.screencast, .screenAudio])

        let stat = StatFailingFileManager()
        let statRoot = self.tempDirectory.appendingPathComponent("unreadable-screen", isDirectory: true)
        let statStore = MobileSegmentStore(
            rootURL: statRoot.appendingPathComponent("MobileSegment", isDirectory: true),
            fileManager: stat
        )
        let statUploader = MobileSegmentUploader(store: statStore, clock: self.clock)
        let unreadableID = UUID()
        let unreadableDirectory = try statStore.createActive(manifest: MobileSegmentManifest(
            segmentID: unreadableID,
            startedAt: self.clock.now().addingTimeInterval(-3_600),
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        ))
        let unreadableScreen = statStore.screenURL(in: unreadableDirectory)
        try Data("partial-screen".utf8).write(to: unreadableScreen)
        stat.blockedPath = unreadableScreen.path
        try statUploader.discardUnprovenRollbackCandidate(segmentID: unreadableID, now: self.clock.now())
        XCTAssertNotNil(statStore.findDirectory(segmentID: unreadableID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableScreen.path))
        guard case .events(let unreadableRows) = statUploader.journalEvents.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertTrue(unreadableRows.isEmpty)

        try self.replaceDirectory(self.eventsDirectory("losses"), withFile: Data("blocked".utf8))
        let kept = try self.openActive(sources: [.audio])
        try Self.fortyEightByteAudio.write(to: self.store.audioURL(in: kept.directory))
        XCTAssertThrowsError(try self.uploader.discardUnprovenRollbackCandidate(segmentID: kept.segmentID, now: self.clock.now()))
        XCTAssertNotNil(self.store.findDirectory(segmentID: kept.segmentID))
    }

    func testBelowMinimumDurationRecordsBeforeTheDelete() throws {
        let loss = try self.openActive(sources: [.audio])
        let lossURL = loss.directory.appendingPathComponent("short.m4a")
        try Self.fortyEightByteAudio.write(to: lossURL)
        try self.uploader.recordAudioFinalized(
            segmentID: loss.segmentID,
            finalized: ObserverRecordedChunk(url: lossURL, duration: 0.05),
            startedAt: self.clock.now().addingTimeInterval(-10),
            endedAt: self.clock.now(),
            mode: .meeting,
            minimumDuration: 0.1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: lossURL.path))
        XCTAssertEqual(
            try self.record(segmentID: loss.segmentID, kind: .diagnostic, reason: "audio_below_min_duration").kind,
            .diagnostic
        )
        let manifest = try self.store.readManifest(in: loss.directory)
        XCTAssertEqual(manifest.audio.state, .noArtifact)

        let diagnostic = try self.openActive(sources: [.audio])
        let diagnosticURL = self.store.audioURL(in: diagnostic.directory)
        try Self.ftypOnly.write(to: diagnosticURL)
        try self.uploader.recordAudioFinalized(
            segmentID: diagnostic.segmentID,
            finalized: ObserverRecordedChunk(url: diagnosticURL, duration: 0.05),
            startedAt: self.clock.now().addingTimeInterval(-10),
            endedAt: self.clock.now(),
            mode: .meeting,
            minimumDuration: 0.1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticURL.path))
        XCTAssertEqual(
            try self.record(segmentID: diagnostic.segmentID, kind: .diagnostic, reason: "audio_below_min_duration").kind,
            .diagnostic
        )

        let moved = try self.openActive(sources: [.audio])
        let side = moved.directory.appendingPathComponent("chunk.m4a")
        try Self.fortyEightByteAudio.write(to: side)
        try self.uploader.recordAudioFinalized(
            segmentID: moved.segmentID,
            finalized: ObserverRecordedChunk(url: side, duration: 1),
            startedAt: self.clock.now().addingTimeInterval(-10),
            endedAt: self.clock.now(),
            mode: .meeting,
            minimumDuration: 0.1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.store.audioURL(in: moved.directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: side.path))
        XCTAssertTrue(try self.records(segmentID: moved.segmentID).isEmpty)

        try self.replaceDirectory(self.eventsDirectory("diagnostics"), withFile: Data("blocked".utf8))
        let kept = try self.openActive(sources: [.audio])
        let keptURL = self.store.audioURL(in: kept.directory)
        try Self.fortyEightByteAudio.write(to: keptURL)
        XCTAssertNoThrow(
            try self.uploader.recordAudioFinalized(
                segmentID: kept.segmentID,
                finalized: ObserverRecordedChunk(url: keptURL, duration: 0.05),
                startedAt: self.clock.now().addingTimeInterval(-10),
                endedAt: self.clock.now(),
                mode: .meeting,
                minimumDuration: 0.1
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptURL.path))
        let keptManifest = try self.store.readManifest(in: kept.directory)
        XCTAssertEqual(keptManifest.audio.state, .noArtifact)
        var diagnosticsIsDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.eventsDirectory("diagnostics").path, isDirectory: &diagnosticsIsDirectory))
        XCTAssertFalse(diagnosticsIsDirectory.boolValue)

        let stat = StatFailingFileManager()
        let statRoot = self.tempDirectory.appendingPathComponent("unreadable-short", isDirectory: true)
        let statStore = MobileSegmentStore(
            rootURL: statRoot.appendingPathComponent("MobileSegment", isDirectory: true),
            fileManager: stat
        )
        let statUploader = MobileSegmentUploader(store: statStore, clock: self.clock)
        let unreadable = try statStore.createActive(manifest: MobileSegmentManifest(
            segmentID: UUID(),
            startedAt: self.clock.now().addingTimeInterval(-10),
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        ))
        let unreadableURL = statStore.audioURL(in: unreadable)
        try Self.fortyEightByteAudio.write(to: unreadableURL)
        stat.blockedPath = unreadableURL.path
        let unreadableID = try statStore.readManifest(in: unreadable).segmentID
        XCTAssertNoThrow(
            try statUploader.recordAudioFinalized(
                segmentID: unreadableID,
                finalized: ObserverRecordedChunk(url: unreadableURL, duration: 0.05),
                startedAt: self.clock.now().addingTimeInterval(-10),
                endedAt: self.clock.now(),
                mode: .meeting,
                minimumDuration: 0.1
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableURL.path))
        let unreadableManifest = try statStore.readManifest(in: unreadable)
        XCTAssertNotEqual(unreadableManifest.audio.state, .noArtifact)
        guard case .events(let unreadableRows) = statUploader.journalEvents.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertFalse(unreadableRows.contains { $0.reason == "audio_below_min_duration" })
    }

    func testReplacingABroadcastPartRecordsThePartThatWasThere() throws {
        let eventsRoot = self.uploader.journalEvents.rootURL
        let segmentID = UUID()
        let now = self.clock.now()
        let existed = self.tempDirectory.appendingPathComponent("existed-part.mp4")
        try Data("partial-screen".utf8).write(to: existed)
        try JournalPartRemoval.removeExisting(
            at: existed,
            source: .screencast,
            reason: "screencast_part_replaced",
            segmentID: segmentID,
            captureAt: now,
            now: now,
            eventsRoot: eventsRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: existed.path))
        XCTAssertEqual(try self.record(segmentID: segmentID, kind: .loss, reason: "screencast_part_replaced").source, .screencast)

        let headerID = UUID()
        let header = self.tempDirectory.appendingPathComponent("header-part.mp4")
        try Self.ftypOnly.write(to: header)
        try JournalPartRemoval.removeExisting(
            at: header,
            source: .screencast,
            reason: "screencast_part_replaced",
            segmentID: headerID,
            captureAt: now,
            now: now,
            eventsRoot: eventsRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: header.path))
        XCTAssertEqual(try self.record(segmentID: headerID, kind: .diagnostic, reason: "screencast_part_replaced").kind, .diagnostic)

        let absentID = UUID()
        try JournalPartRemoval.removeExisting(
            at: self.tempDirectory.appendingPathComponent("missing-part.mp4"),
            source: .screencast,
            reason: "screencast_part_replaced",
            segmentID: absentID,
            captureAt: now,
            now: now,
            eventsRoot: eventsRoot
        )
        XCTAssertTrue(try self.records(segmentID: absentID).isEmpty)

        let container = self.tempDirectory.appendingPathComponent("broadcast-root", isDirectory: true)
        let audioSegment = UUID()
        let handoff = ScreencastFixtures.handoff(segmentID: audioSegment)
        let part = MobileSegmentScreencastPaths.url(
            root: container,
            relativePath: MobileSegmentScreencastPaths.screenAudioPartRelativePath(segmentID: audioSegment)
        )
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial-screen-audio".utf8).write(to: part)
        let writer = ScreencastBroadcastAudioWriter()
        try writer.open(rootURL: container, handoff: handoff, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        let audioEvents = JournalEventStore(rootURL: JournalEventStore.directory(inAppGroupRoot: container))
        guard case .events(let rows) = audioEvents.readEvents() else {
            return XCTFail("broadcast journal events unreadable")
        }
        let replaced = rows.first { $0.segmentID == audioSegment.uuidString }
        XCTAssertEqual(replaced?.kind, .loss)
        XCTAssertEqual(replaced?.source, .screenAudio)
        XCTAssertEqual(replaced?.reason, "screencast_part_replaced")
        let parentEvents = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: container))
        guard case .events(let parentRows) = parentEvents.readEvents() else {
            return XCTFail("broadcast journal events unreadable")
        }
        XCTAssertFalse(parentRows.contains { $0.segmentID == audioSegment.uuidString })

        let retryID = UUID()
        let retryURL = self.tempDirectory.appendingPathComponent("retry-part.mp4")
        try Data("partial-screen".utf8).write(to: retryURL)
        try self.uploader.journalEvents.recordLoss(
            segmentID: retryID,
            source: .screencast,
            reason: "screencast_part_replaced",
            captureAt: now,
            now: now
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retryURL.path))
        try JournalPartRemoval.removeExisting(
            at: retryURL,
            source: .screencast,
            reason: "screencast_part_replaced",
            segmentID: retryID,
            captureAt: now,
            now: now,
            eventsRoot: eventsRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: retryURL.path))
        XCTAssertEqual(
            try self.records(segmentID: retryID).filter { $0.reason == "screencast_part_replaced" }.count,
            1
        )

        let blockedRoot = self.tempDirectory.appendingPathComponent("blocked-broadcast", isDirectory: true)
        let blockedEvents = JournalEventStore.directory(inAppGroupRoot: blockedRoot)
        try FileManager.default.createDirectory(at: blockedEvents, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedEvents.appendingPathComponent("losses", isDirectory: false))
        let blockedSegment = UUID()
        let blockedHandoff = ScreencastFixtures.handoff(segmentID: blockedSegment)
        let blockedPart = MobileSegmentScreencastPaths.url(
            root: blockedRoot,
            relativePath: MobileSegmentScreencastPaths.screenAudioPartRelativePath(segmentID: blockedSegment)
        )
        try FileManager.default.createDirectory(at: blockedPart.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial-screen-audio".utf8).write(to: blockedPart)
        let blockedWriter = ScreencastBroadcastAudioWriter()
        XCTAssertNoThrow(try blockedWriter.open(rootURL: blockedRoot, handoff: blockedHandoff, now: now))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedPart.path))
        let claimed = try XCTUnwrap(blockedWriter.partURL)
        XCTAssertNotEqual(claimed, blockedPart)
        XCTAssertTrue(claimed.lastPathComponent.hasPrefix(blockedPart.lastPathComponent))

        let stat = StatFailingFileManager()
        let unreadablePart = self.tempDirectory.appendingPathComponent("unreadable-part.mp4")
        try Data("partial-screen".utf8).write(to: unreadablePart)
        stat.blockedPath = unreadablePart.path
        let claimedUnreadable = JournalPartClaim.urlForNewCapture(
            canonical: unreadablePart,
            source: .screencast,
            reason: "screencast_part_replaced",
            segmentID: UUID(),
            captureAt: now,
            now: now,
            eventsRoot: eventsRoot,
            fileManager: stat
        )
        XCTAssertNotEqual(claimedUnreadable, unreadablePart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadablePart.path))
    }

    func testRetainedAudioRestoreWritesNoJournalEvent() async throws {
        let parked = try self.parkFailed(sources: [.audio], failed: [.audio]) { directory, store, _ in
            let retained = store.audioURL(in: directory).appendingPathExtension("retained")
            try Self.fortyEightByteAudio.write(to: retained)
            try FileManager.default.setAttributes(
                [.modificationDate: self.clock.now()],
                ofItemAtPath: retained.path
            )
        }
        let resolution = try await self.uploader.resolveFinalizeFailure(
            segmentID: parked.segmentID,
            directory: parked.directory,
            lifecycle: .failed
        )
        XCTAssertEqual(resolution, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.store.audioURL(in: parked.directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.store.audioURL(in: parked.directory).appendingPathExtension("retained").path))
        XCTAssertTrue(try self.records(segmentID: parked.segmentID).isEmpty)
    }

    func testStaleScreenLivenessAndLeaseSweepWriteNoJournalEvent() async throws {
        let segmentID = UUID()
        let directory = self.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: UUID(),
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: self.clock.now().addingTimeInterval(-60),
            acceptedFrameCount: 0,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            liveness,
            to: MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: directory)
        )
        let leases = self.store.rootURL
            .appendingPathComponent("screencast", isDirectory: true)
            .appendingPathComponent("leases", isDirectory: true)
        try FileManager.default.createDirectory(at: leases, withIntermediateDirectories: true)
        try Data("lease".utf8).write(to: leases.appendingPathComponent("lease.json"))

        await self.uploader.resumeFromDisk()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leases.path))
        XCTAssertTrue(try self.records().isEmpty)
    }

    func testObserverCacheCleanupWritesNoJournalEvent() async throws {
        let cache = self.tempDirectory.appendingPathComponent("observer-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent("empty.m4a"))
        let bodies = cache.appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: bodies.appendingPathComponent("body.bin"))
        let defaults = UserDefaults(suiteName: "journal-gap-cache-\(UUID().uuidString)")!
        defaults.set(false, forKey: MobileSegmentTransferSpoolMigrator.flagKey)
        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: self.tempDirectory,
            observerCacheRootURL: cache,
            store: self.store,
            diagnosticLog: nil,
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("empty.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodies.path))
        XCTAssertTrue(try self.records().isEmpty)
    }

    func testLocationRemovalWritesNoJournalEvent() throws {
        let opened = try self.openActive(sources: [.location])
        try self.uploader.recordLocationFinalizeRemoved(
            segmentID: opened.segmentID,
            endedAt: self.clock.now(),
            reason: "location_no_local_data"
        )
        let manifest = try self.store.readManifest(in: opened.directory)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertTrue(try self.records().isEmpty)
    }

    // MARK: - Helpers

    private struct ResolvedAudio {
        var segmentID: UUID
        var directory: URL
        var audioURL: URL
        var resolution: FinalizeFailureResolution
    }

    private struct OpenedSegment {
        var segmentID: UUID
        var directory: URL
    }

    private func eventsDirectory(_ name: String) -> URL {
        self.uploader.journalEvents.rootURL.appendingPathComponent(name, isDirectory: true)
    }

    private func records() throws -> [JournalEventRecord] {
        guard case .events(let rows) = self.uploader.journalEvents.readEvents() else {
            XCTFail("journal events unreadable")
            return []
        }
        return rows
    }

    private func records(segmentID: UUID) throws -> [JournalEventRecord] {
        try self.records().filter { $0.segmentID == segmentID.uuidString }
    }

    private func record(segmentID: UUID, kind: JournalEventKind, reason: String) throws -> JournalEventRecord {
        try XCTUnwrap(self.records(segmentID: segmentID).first { $0.kind == kind && $0.reason == reason })
    }

    private func record(id: String) throws -> JournalEventRecord {
        try XCTUnwrap(self.records().first { $0.id == id })
    }

    private func openActive(sources: Set<MobileSegmentSource>) throws -> OpenedSegment {
        let segmentID = UUID()
        let directory = try self.store.createActive(manifest: MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: self.clock.now().addingTimeInterval(-3_600),
            openedWithSources: sources,
            activeSourceSetVersion: 1
        ))
        return OpenedSegment(segmentID: segmentID, directory: directory)
    }

    private func parkFailed(
        sources: Set<MobileSegmentSource>,
        failed: Set<MobileSegmentSource>,
        prepare: (URL, MobileSegmentStore, inout MobileSegmentManifest) throws -> Void
    ) throws -> (segmentID: UUID, directory: URL) {
        let opened = try self.openActive(sources: sources)
        var manifest = try self.store.readManifest(in: opened.directory)
        try prepare(opened.directory, self.store, &manifest)
        for source in failed {
            try self.store.writeOutcome(
                MobileSegmentSourceResolution(
                    state: .failedToFinalize,
                    reason: "\(source.rawValue)_finalize_failed",
                    stage: "source-finalize",
                    lastAttemptAt: self.clock.now()
                ),
                source: source,
                manifest: &manifest,
                in: opened.directory,
                now: self.clock.now()
            )
        }
        try self.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "source artifact failed to finalize",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 1,
                stage: "source-finalize",
                lastAttemptAt: self.clock.now()
            ),
            in: opened.directory
        )
        let directory = try self.store.move(segmentID: opened.segmentID, from: .active, to: .failed)
        return (opened.segmentID, directory)
    }

    private func parkFailedAudio(
        bytes: Data,
        receipt: PhoneAudioWriterReceiptPhase?,
        frames: Int64,
        faultReason: String?
    ) throws -> (segmentID: UUID, directory: URL, audioURL: URL) {
        let parked = try self.parkFailed(sources: [.audio], failed: [.audio]) { directory, store, _ in
            let audioURL = store.audioURL(in: directory)
            try bytes.write(to: audioURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: self.clock.now().addingTimeInterval(-400)],
                ofItemAtPath: audioURL.path
            )
            if let receipt {
                try store.writeAudioWriterReceipt(
                    PhoneAudioWriterReceipt(
                        segmentID: store.readManifest(in: directory).segmentID,
                        phase: receipt,
                        acceptedFrames: frames,
                        reason: faultReason
                    ),
                    in: directory
                )
            }
        }
        return (parked.segmentID, parked.directory, self.store.audioURL(in: parked.directory))
    }

    private func resolveAudio(
        bytes: Data,
        receipt: PhoneAudioWriterReceiptPhase?,
        frames: Int64,
        faultReason: String? = nil
    ) async throws -> ResolvedAudio {
        let parked = try self.parkFailedAudio(bytes: bytes, receipt: receipt, frames: frames, faultReason: faultReason)
        let resolution = try await self.uploader.resolveFinalizeFailure(
            segmentID: parked.segmentID,
            directory: parked.directory,
            lifecycle: .failed
        )
        let audioURL = self.store.findDirectory(segmentID: parked.segmentID).map { self.store.audioURL(in: $0.url) } ?? parked.audioURL
        return ResolvedAudio(segmentID: parked.segmentID, directory: parked.directory, audioURL: audioURL, resolution: resolution)
    }

    private func parkMissingAudio(
        frames: Int64,
        phase: PhoneAudioWriterReceiptPhase,
        faultReason: String? = nil
    ) throws -> (segmentID: UUID, directory: URL) {
        try self.parkFailed(sources: [.audio], failed: [.audio]) { directory, store, _ in
            let segmentID = try store.readManifest(in: directory).segmentID
            try store.writeAudioWriterReceipt(
                PhoneAudioWriterReceipt(segmentID: segmentID, phase: phase, acceptedFrames: frames, reason: faultReason),
                in: directory
            )
        }
    }

    private func resolveMissingAudio(frames: Int64, phase: PhoneAudioWriterReceiptPhase) async throws -> (segmentID: UUID, directory: URL) {
        let parked = try self.parkMissingAudio(frames: frames, phase: phase, faultReason: phase == .faulted ? "audio_writer_failed" : nil)
        _ = try await self.uploader.resolveFinalizeFailure(segmentID: parked.segmentID, directory: parked.directory, lifecycle: .failed)
        return parked
    }

    private func resolveScreen(file: Data, name: String) async throws -> (segmentID: UUID, fileURL: URL, resolution: FinalizeFailureResolution) {
        let parked = try await self.parkScreenFile(file, name: name)
        let resolution = try await self.uploader.resolveFinalizeFailure(
            segmentID: parked.segmentID,
            directory: parked.directory,
            lifecycle: .failed
        )
        return (parked.segmentID, parked.fileURL, resolution)
    }

    private func parkScreenFile(_ file: Data, name: String) async throws -> (segmentID: UUID, directory: URL, fileURL: URL) {
        let parked = try self.parkFailed(sources: [.screencast], failed: [.screencast]) { directory, _, _ in
            try file.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        return (parked.segmentID, parked.directory, parked.directory.appendingPathComponent(name))
    }

    private func finalizeScreenPart(_ file: Data, name: String) async throws -> (segmentID: UUID, fileURL: URL) {
        let opened = try self.openActive(sources: [.screencast])
        let fileURL = opened.directory.appendingPathComponent(name)
        try file.write(to: fileURL, options: .atomic)
        await self.uploader.finalizeActiveSegment(segmentID: opened.segmentID, endedAt: self.clock.now())
        return (opened.segmentID, fileURL)
    }

    private func replaceDirectory(_ url: URL, withFile data: Data) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static let ftypOnly = Data([
        0x00, 0x00, 0x00, 0x18,
        0x66, 0x74, 0x79, 0x70,
        0x6D, 0x70, 0x34, 0x32,
        0x00, 0x00, 0x00, 0x00,
        0x69, 0x73, 0x6F, 0x6D,
        0x6D, 0x70, 0x34, 0x32,
    ])

    /// 28-byte `ftyp`, 8-byte `wide`, 12-byte `mdat` with 4 payload bytes.
    private static let fortyEightByteAudio: Data = {
        var bytes = Data([
            0x00, 0x00, 0x00, 0x1C,
            0x66, 0x74, 0x79, 0x70,
        ])
        bytes.append(Data(repeating: 0, count: 20))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x08, 0x77, 0x69, 0x64, 0x65])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x0C, 0x6D, 0x64, 0x61, 0x74, 0x01, 0x02, 0x03, 0x04])
        return bytes
    }()

    private static let permanentInspector = PhoneAudioInspector { _ in
        .permanent(domain: "AVFoundationErrorDomain", code: -11829)
    }

    private static func durationInspector(_ seconds: TimeInterval) -> PhoneAudioInspector {
        PhoneAudioInspector { _ in .duration(seconds) }
    }
}

final class StatFailingFileManager: FileManager, @unchecked Sendable {
    var blockedPath: String?

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path == self.blockedPath {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }
}

final class RemoveFailingFileManager: FileManager, @unchecked Sendable {
    var blockedPath: String?

    override func removeItem(at url: URL) throws {
        if url.path == self.blockedPath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
