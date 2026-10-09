// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentFinalizeResolverTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!
    private var engines: [TransferEngine] = []
    private var testID: String!

    override func setUp() {
        super.setUp()
        MobileSegmentFinalizeResolverURLProtocol.assertNoLateRequests()
        self.testID = UUID().uuidString
        MobileSegmentFinalizeResolverURLProtocol.beginTest(id: self.testID)
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentFinalizeResolverTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() async throws {
        // Stop every engine before waiting: some tests recreate an uploader
        // with a second engine while the original one still owns work.
        for engine in self.engines {
            await engine.pause()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        for engine in self.engines {
            while await engine.snapshot().counters.inFlightCount > 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let snapshot = await engine.snapshot()
            XCTAssertEqual(snapshot.counters.inFlightCount, 0, "Transfer requests did not finish before teardown")
        }
        MobileSegmentFinalizeResolverURLProtocol.reset()
        await Task.yield()
        MobileSegmentFinalizeResolverURLProtocol.assertNoLateRequests()
        self.engines.removeAll()
        try FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        self.testID = nil
        try await super.tearDown()
    }

    private func audioRecoveryFixtureURL(named filename: String) throws -> URL {
        let resourceURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL, "test bundle resources are unavailable")
        let candidates = [
            resourceURL.appendingPathComponent(filename, isDirectory: false),
            resourceURL.appendingPathComponent("AudioRecovery", isDirectory: true).appendingPathComponent(filename, isDirectory: false),
            resourceURL.appendingPathComponent("Fixtures/AudioRecovery", isDirectory: true).appendingPathComponent(filename, isDirectory: false),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        XCTFail("Missing audio recovery fixture \(filename) in bundle at \(resourceURL.path)")
        throw NSError(domain: "AudioRecoveryFixture", code: 404)
    }

    func testRecoveredPrefixKeepsInterruptionAndCorrectTransferDuration() async throws {
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")
        let cleanFixtureURL = try self.audioRecoveryFixtureURL(named: "clean12.m4a")

        // Case 1: resolveFinalizeFailure on aged failed segment with killed bytes and writing receipt
        let segmentID1 = UUID()
        let startedAt1 = self.clock.now().addingTimeInterval(-1200)
        let failedDirectory1 = try self.writeBundle(
            segmentID: segmentID1,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: startedAt1
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receiptJSON1 = """
        {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID1.uuidString)","version":1}
        """
        try Data(receiptJSON1.utf8).write(to: failedDirectory1.appendingPathComponent("audio-writer.json"), options: .atomic)

        let initialPrefix1 = try XCTUnwrap(harness.store.readManifest(in: failedDirectory1).segment?.split(separator: "_").first.map(String.init))

        let result1 = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID1, directory: failedDirectory1, lifecycle: .failed)
        XCTAssertEqual(result1, .repend)

        let pendingDirectory1 = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID1)
        let manifest1 = try harness.store.readManifest(in: pendingDirectory1)
        XCTAssertEqual(try XCTUnwrap(manifest1.audio.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(manifest1.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(harness.store.audioInterruptionCount(), 1)
        let interruption1 = try harness.store.readTombstone(
            at: harness.store.audioInterruptionDirectory().appendingPathComponent("\(segmentID1.uuidString).json")
        )
        XCTAssertEqual(interruption1.reason, "audio_capture_unfinished")
        XCTAssertEqual(manifest1.segment, "\(initialPrefix1)_11")

        // Case 2: resumeFromDisk on a second aged failed segment with same killed bytes and writing receipt
        self.stubDelivered()
        let segmentID2 = UUID()
        let startedAt2 = self.clock.now().addingTimeInterval(-1500)
        let failedDirectory2 = try self.writeBundle(
            segmentID: segmentID2,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: startedAt2
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receiptJSON2 = """
        {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID2.uuidString)","version":1}
        """
        try Data(receiptJSON2.utf8).write(to: failedDirectory2.appendingPathComponent("audio-writer.json"), options: .atomic)
        let initialPrefix2 = try XCTUnwrap(harness.store.readManifest(in: failedDirectory2).segment?.split(separator: "_").first.map(String.init))

        await harness.uploader.resumeFromDisk()

        let snapshots2 = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot2 = try XCTUnwrap(
            snapshots2.first(where: { $0.manifest.itemID == segmentID2 })
        )
        XCTAssertEqual(try XCTUnwrap(snapshot2.manifest.observerIngest?.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(snapshot2.manifest.observerIngest?.segment), "\(initialPrefix2)_11")
        XCTAssertEqual(harness.store.audioInterruptionCount(), 2)
        let interruption2 = try harness.store.readTombstone(
            at: harness.store.audioInterruptionDirectory().appendingPathComponent("\(segmentID2.uuidString).json")
        )
        XCTAssertEqual(interruption2.reason, "audio_capture_unfinished")

        // Case 3: third aged failed segment whose bytes are clean12.m4a and completed receipt with 192000 frames
        let segmentID3 = UUID()
        let startedAt3 = self.clock.now().addingTimeInterval(-1800)
        let failedDirectory3 = try self.writeBundle(
            segmentID: segmentID3,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: startedAt3
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receiptJSON3 = """
        {"acceptedFrames":192000,"phase":"completed","sampleRate":16000,"segmentID":"\(segmentID3.uuidString)","version":1}
        """
        try Data(receiptJSON3.utf8).write(to: failedDirectory3.appendingPathComponent("audio-writer.json"), options: .atomic)
        let initialPrefix3 = try XCTUnwrap(harness.store.readManifest(in: failedDirectory3).segment?.split(separator: "_").first.map(String.init))

        let result3 = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID3, directory: failedDirectory3, lifecycle: .failed)
        XCTAssertEqual(result3, .repend)

        let pendingDirectory3 = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID3)
        let manifest3 = try harness.store.readManifest(in: pendingDirectory3)
        XCTAssertEqual(try XCTUnwrap(manifest3.audio.durationS), 12.0, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(manifest3.durationS), 12.0, accuracy: 1.0 / 16000)
        XCTAssertEqual(manifest3.segment, "\(initialPrefix3)_12")
        XCTAssertEqual(harness.store.audioInterruptionCount(), 2) // still 2, no new record
    }

    func testInjectedInspectDurationsBehavior() async throws {
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")

        let nonDecodableCases: [PhoneAudioInspectionResult] = [
            .missingDuration,
            .duration(0),
            .duration(.nan),
            .duration(.infinity)
        ]

        for inspectCase in nonDecodableCases {
            for elapsed in [15.0, 290.0] {
                let segmentID = UUID()
                let startedAt = self.clock.now().addingTimeInterval(-1000)
                let failedDirectory = try self.writeBundle(
                    segmentID: segmentID,
                    store: harness.store,
                    lifecycle: .failed,
                    sources: [.audio],
                    startedAt: startedAt
                ) { directory, manifest, startedAt, endedAt in
                    let audioURL = harness.store.audioURL(in: directory)
                    try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
                    try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
                    try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
                }
                var bundleManifest = try harness.store.readManifest(in: failedDirectory)
                bundleManifest.durationS = elapsed
                bundleManifest.endedAt = startedAt.addingTimeInterval(elapsed)
                bundleManifest.segment = "090000_\(Int(elapsed))"
                try harness.store.writeManifest(bundleManifest, in: failedDirectory)

                let receiptJSON = """
                {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID.uuidString)","version":1}
                """
                try Data(receiptJSON.utf8).write(to: failedDirectory.appendingPathComponent("audio-writer.json"), options: .atomic)

                harness.uploader.audioInspector = PhoneAudioInspector { _ in inspectCase }

                let countBefore = harness.store.audioInterruptionCount()
                let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
                XCTAssertEqual(result, .deferred)
                let manifest = try harness.store.readManifest(in: failedDirectory)
                XCTAssertNotEqual(manifest.audio.state, .finalizedArtifact)
                XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
                XCTAssertEqual(harness.store.audioInterruptionCount(), countBefore)
                XCTAssertEqual(manifest.durationS, elapsed)
            }
        }

        // Then injected 9.916 and 10.876 stored
        let segmentID9 = UUID()
        let failedDir9 = try self.writeBundle(
            segmentID: segmentID9,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1500)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receiptJSON9 = """
        {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID9.uuidString)","version":1}
        """
        try Data(receiptJSON9.utf8).write(to: failedDir9.appendingPathComponent("audio-writer.json"), options: .atomic)
        harness.uploader.audioInspector = PhoneAudioInspector { _ in .duration(9.916) }
        let result9 = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID9, directory: failedDir9, lifecycle: .failed)
        XCTAssertEqual(result9, .repend)
        let manifest9 = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID9))
        XCTAssertEqual(try XCTUnwrap(manifest9.audio.durationS), 9.916, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(manifest9.durationS), 9.916, accuracy: 1.0 / 16000)

        let segmentID10 = UUID()
        let failedDir10 = try self.writeBundle(
            segmentID: segmentID10,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1600)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receiptJSON10 = """
        {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID10.uuidString)","version":1}
        """
        try Data(receiptJSON10.utf8).write(to: failedDir10.appendingPathComponent("audio-writer.json"), options: .atomic)
        harness.uploader.audioInspector = PhoneAudioInspector { _ in .duration(10.876) }
        let result10 = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID10, directory: failedDir10, lifecycle: .failed)
        XCTAssertEqual(result10, .repend)
        let manifest10 = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID10))
        XCTAssertEqual(try XCTUnwrap(manifest10.audio.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(manifest10.durationS), 10.876, accuracy: 1.0 / 16000)
    }

    func testManifestWriteErrorAndEnqueueErrorRecovery() async throws {
        self.stubDelivered()
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")

        // 1. testWriteManifestError after outcome file
        let segmentID1 = UUID()
        let failedDir1 = try self.writeBundle(
            segmentID: segmentID1,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        var initialManifest1 = try harness.store.readManifest(in: failedDir1)
        initialManifest1.durationS = 290
        initialManifest1.segment = "090000_290"
        try harness.store.writeManifest(initialManifest1, in: failedDir1)

        let receiptJSON1 = """
        {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID1.uuidString)","version":1}
        """
        try Data(receiptJSON1.utf8).write(to: failedDir1.appendingPathComponent("audio-writer.json"), options: .atomic)

        harness.store.testWriteManifestError = NSError(domain: "test", code: -101, userInfo: nil)
        do {
            _ = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID1, directory: failedDir1, lifecycle: .failed)
            XCTFail("Expected testWriteManifestError to be thrown")
        } catch {
            // Threw error, bytes remain, no enqueue
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDir1).path))
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
            XCTAssertTrue(snapshots.isEmpty)
        }

        // Segment was NOT deleted. New uploader on same store enqueues exactly one TransferManifest
        let harness1New = try await self.makeHarness()
        let uploader1New = MobileSegmentUploader(transferEngine: harness1New.engine, store: harness.store, clock: self.clock)
        await uploader1New.resumeFromDisk()

        let snapshots1 = await harness1New.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let item1Snapshots = snapshots1.filter { $0.manifest.itemID == segmentID1 }
        XCTAssertEqual(item1Snapshots.count, 1)
        let snapshot1 = try XCTUnwrap(item1Snapshots.first)
        XCTAssertEqual(try XCTUnwrap(snapshot1.manifest.observerIngest?.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(snapshot1.manifest.observerIngest?.segment), "090000_11")
        for s in item1Snapshots {
            let dur = s.manifest.observerIngest?.durationS ?? 0
            XCTAssertFalse(abs(dur - 60) < 0.1 || abs(dur - 15) < 0.1 || abs(dur - 290) < 0.1)
        }

        // 2. testEnqueueError before enqueueIfAbsent after corrected manifest is on disk;
        // new uploader enqueues one TransferManifest with duration 10.876 and suffix _11
        let harnessForPart2 = try await self.makeHarness()
        let segmentID2 = UUID()
        let failedDir2 = try self.writeBundle(
            segmentID: segmentID2,
            store: harnessForPart2.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1200)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harnessForPart2.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harnessForPart2.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        var initialManifest2 = try harnessForPart2.store.readManifest(in: failedDir2)
        initialManifest2.durationS = 15
        initialManifest2.segment = "090000_15"
        try harnessForPart2.store.writeManifest(initialManifest2, in: failedDir2)

        let receiptJSON2 = """
        {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID2.uuidString)","version":1}
        """
        try Data(receiptJSON2.utf8).write(to: failedDir2.appendingPathComponent("audio-writer.json"), options: .atomic)

        let result2 = try await harnessForPart2.uploader.resolveFinalizeFailure(segmentID: segmentID2, directory: failedDir2, lifecycle: .failed)
        XCTAssertEqual(result2, .repend)

        harnessForPart2.uploader.testEnqueueError = NSError(domain: "test", code: -102, userInfo: nil)
        await harnessForPart2.uploader.resumeFromDisk()

        // Corrected manifest is on disk in pending/
        let pendingDir2 = harnessForPart2.store.segmentDirectoryURL(.pending, segmentID: segmentID2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDir2.path))
        let pendingManifest2 = try harnessForPart2.store.readManifest(in: pendingDir2)
        XCTAssertEqual(try XCTUnwrap(pendingManifest2.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(pendingManifest2.segment, "090000_11")

        // Now new uploader resumes from disk
        let harnessPart2New = try await self.makeHarness()
        let uploaderPart2New = MobileSegmentUploader(transferEngine: harnessPart2New.engine, store: harnessForPart2.store, clock: self.clock)
        await uploaderPart2New.resumeFromDisk()

        let snapshots2 = await harnessPart2New.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let item2Snapshots = snapshots2.filter { $0.manifest.itemID == segmentID2 }
        XCTAssertEqual(item2Snapshots.count, 1)
        let snapshot2 = try XCTUnwrap(item2Snapshots.first)
        XCTAssertEqual(try XCTUnwrap(snapshot2.manifest.observerIngest?.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(snapshot2.manifest.observerIngest?.segment), "090000_11")
        for s in item2Snapshots {
            let dur = s.manifest.observerIngest?.durationS ?? 0
            XCTAssertFalse(abs(dur - 60) < 0.1 || abs(dur - 15) < 0.1 || abs(dur - 290) < 0.1)
        }
    }

    func testPendingSegmentsWithOuterDurationsRecoverCorrectly() async throws {
        self.stubDelivered()
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")

        let tokyoZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let utcOffset = tokyoZone.secondsFromGMT()

        for elapsed in [15.0, 290.0] {
            let segmentID = UUID()
            let startedAt = self.clock.now().addingTimeInterval(-1500)
            let dayString = "2026-04-21"
            let initialSegment = "090000_\(Int(elapsed))"

            let pendingDir = try self.writeBundle(
                segmentID: segmentID,
                store: harness.store,
                lifecycle: .pending,
                sources: [.audio],
                startedAt: startedAt
            ) { directory, manifest, startedAt, endedAt in
                let audioURL = harness.store.audioURL(in: directory)
                try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
                try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
                try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            }
            var initialManifest = try harness.store.readManifest(in: pendingDir)
            initialManifest.day = dayString
            initialManifest.segment = initialSegment
            initialManifest.tz = "Asia/Tokyo"
            initialManifest.utcOffsetSeconds = utcOffset
            initialManifest.durationS = elapsed
            initialManifest.endedAt = startedAt.addingTimeInterval(elapsed)
            try harness.store.writeManifest(initialManifest, in: pendingDir)

            let receiptJSON = """
            {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID.uuidString)","version":1}
            """
            try Data(receiptJSON.utf8).write(to: pendingDir.appendingPathComponent("audio-writer.json"), options: .atomic)

            await harness.uploader.resumeFromDisk()

            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
            let snapshot = try XCTUnwrap(snapshots.first(where: { $0.manifest.itemID == segmentID }))

            XCTAssertEqual(try XCTUnwrap(snapshot.manifest.observerIngest?.durationS), 10.876, accuracy: 1.0 / 16000)
            XCTAssertEqual(try XCTUnwrap(snapshot.manifest.observerIngest?.segment), "090000_11")
            XCTAssertEqual(snapshot.manifest.observerIngest?.segmentID, segmentID)
            XCTAssertEqual(snapshot.manifest.observerIngest?.day, dayString)
            XCTAssertEqual(snapshot.manifest.observerIngest?.tz, "Asia/Tokyo")
            XCTAssertEqual(snapshot.manifest.observerIngest?.utcOffsetSeconds, utcOffset)
        }
    }

    func testOuterDurationsReplacedWhileTimeZoneMetadataPreserved() async throws {
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")

        let tokyoZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let utcOffset = tokyoZone.secondsFromGMT()

        for elapsed in [15.0, 290.0] {
            let segmentID = UUID()
            let startedAt = self.clock.now().addingTimeInterval(-1500)
            let dayString = "2026-04-21"
            let initialSegment = "090000_\(Int(elapsed))"

            let failedDir = try self.writeBundle(
                segmentID: segmentID,
                store: harness.store,
                lifecycle: .failed,
                sources: [.audio],
                startedAt: startedAt
            ) { directory, manifest, startedAt, endedAt in
                let audioURL = harness.store.audioURL(in: directory)
                try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
                try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
                try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            }
            var initialManifest = try harness.store.readManifest(in: failedDir)
            initialManifest.day = dayString
            initialManifest.segment = initialSegment
            initialManifest.tz = "Asia/Tokyo"
            initialManifest.utcOffsetSeconds = utcOffset
            initialManifest.durationS = elapsed
            initialManifest.endedAt = startedAt.addingTimeInterval(elapsed)
            try harness.store.writeManifest(initialManifest, in: failedDir)

            let receiptJSON = """
            {"acceptedFrames":0,"phase":"writing","sampleRate":16000,"segmentID":"\(segmentID.uuidString)","version":1}
            """
            try Data(receiptJSON.utf8).write(to: failedDir.appendingPathComponent("audio-writer.json"), options: .atomic)

            let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDir, lifecycle: .failed)
            XCTAssertEqual(result, .repend)

            let pendingDir = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
            let recoveredManifest = try harness.store.readManifest(in: pendingDir)

            XCTAssertEqual(try XCTUnwrap(recoveredManifest.durationS), 10.876, accuracy: 1.0 / 16000)
            XCTAssertEqual(try XCTUnwrap(recoveredManifest.audio.durationS), 10.876, accuracy: 1.0 / 16000)
            XCTAssertEqual(recoveredManifest.segment, "090000_11")

            XCTAssertEqual(recoveredManifest.segmentID, segmentID)
            XCTAssertEqual(recoveredManifest.day, dayString)
            XCTAssertEqual(recoveredManifest.tz, "Asia/Tokyo")
            XCTAssertEqual(recoveredManifest.utcOffsetSeconds, utcOffset)

            self.stubDelivered()
            await harness.uploader.resumeFromDisk()

            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
            let itemSnapshots = snapshots.filter { $0.manifest.itemID == segmentID }
            XCTAssertEqual(itemSnapshots.count, 1)
            let snapshot = try XCTUnwrap(itemSnapshots.first)
            XCTAssertEqual(try XCTUnwrap(snapshot.manifest.observerIngest?.durationS), 10.876, accuracy: 1.0 / 16000)
            let segmentName = try XCTUnwrap(snapshot.manifest.observerIngest?.segment)
            XCTAssertTrue(segmentName.hasSuffix("_11"))
            for s in itemSnapshots {
                let dur = s.manifest.observerIngest?.durationS ?? 0
                XCTAssertFalse(abs(dur - 15) < 0.1 || abs(dur - 60) < 0.1 || abs(dur - 290) < 0.1)
            }
        }
    }

    func testReceiptParsingAndValidationScenarios() async throws {
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")
        let cleanFixtureURL = try self.audioRecoveryFixtureURL(named: "clean12.m4a")

        // 1. Invalid receipts defer and keep bytes (are unusable, not absent)
        let invalidReceiptPayloads = [
            "not a json",
            #"{"version":2,"segmentID":"UUID","phase":"writing","sampleRate":16000,"acceptedFrames":0}"#,
            #"{"version":1,"segmentID":"00000000-0000-0000-0000-000000000000","phase":"writing","sampleRate":16000,"acceptedFrames":0}"#,
            #"{"version":1,"segmentID":"UUID","phase":"writing","sampleRate":16000,"acceptedFrames":-5}"#,
            #"{"version":1,"segmentID":"UUID","phase":"writing","sampleRate":44100,"acceptedFrames":0}"#,
            #"{"version":1,"segmentID":"UUID","phase":"writing","sampleRate":16000,"acceptedFrames":0,"extraKey":"bad"}"#,
            #"{"version":1,"segmentID":"UUID","phase":"writing","sampleRate":16000,"acceptedFrames":0,"reason":"audio_writer_failed"}"#,
            #"{"version":1.5,"segmentID":"UUID","phase":"writing","sampleRate":16000,"acceptedFrames":0}"#,
        ]

        for payload in invalidReceiptPayloads {
            let segmentID = UUID()
            let failedDir = try self.writeBundle(
                segmentID: segmentID,
                store: harness.store,
                lifecycle: .failed,
                sources: [.audio],
                startedAt: self.clock.now().addingTimeInterval(-1000)
            ) { directory, manifest, startedAt, endedAt in
                let audioURL = harness.store.audioURL(in: directory)
                try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
                try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
                try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            }
            let formattedPayload = payload.replacingOccurrences(of: "UUID", with: segmentID.uuidString)
            try Data(formattedPayload.utf8).write(to: failedDir.appendingPathComponent("audio-writer.json"), options: .atomic)

            let readResult = harness.store.readAudioWriterReceipt(in: failedDir, expectedSegmentID: segmentID)
            XCTAssertEqual(readResult, .unusable)
            XCTAssertNotEqual(readResult, .absent)

            let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDir, lifecycle: .failed)
            XCTAssertEqual(result, .deferred)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDir).path))
        }

        // Unreadable receipt (mode 000)
        let unreadableID = UUID()
        let unreadableDir = try self.writeBundle(
            segmentID: unreadableID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receiptURL = unreadableDir.appendingPathComponent("audio-writer.json")
        try Data("{}".utf8).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: receiptURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receiptURL.path)
        }
        let unreadableResult = try await harness.uploader.resolveFinalizeFailure(segmentID: unreadableID, directory: unreadableDir, lifecycle: .failed)
        XCTAssertEqual(unreadableResult, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: unreadableDir).path))

        // 2. Missing receipt:
        // - readable legacy 12s with no unfinished interruption -> finalizes 12.0s
        let legacyID = UUID()
        let legacyDir = try self.writeBundle(
            segmentID: legacyID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let countBeforeLegacy = harness.store.audioInterruptionCount()
        let legacyResult = try await harness.uploader.resolveFinalizeFailure(segmentID: legacyID, directory: legacyDir, lifecycle: .failed)
        XCTAssertEqual(legacyResult, .repend)
        let legacyPendingManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: legacyID))
        XCTAssertEqual(try XCTUnwrap(legacyPendingManifest.audio.durationS), 12.0, accuracy: 1.0 / 16000)
        XCTAssertEqual(harness.store.audioInterruptionCount(), countBeforeLegacy)

        // - ftyp-only retires with audio_undecodable_container
        let ftypID = UUID()
        let ftypDir = try self.writeBundle(
            segmentID: ftypID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try MobileSegmentTestFixtures.writeFtypOnlyAudio(at: audioURL)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let ftypResult = try await harness.uploader.resolveFinalizeFailure(segmentID: ftypID, directory: ftypDir, lifecycle: .failed)
        XCTAssertEqual(ftypResult, .retired)
        let ftypTombstone = try harness.store.readTombstone(at: harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(ftypID.uuidString).json"))
        XCTAssertEqual(ftypTombstone.reason, "audio_undecodable_container")

        // 3. Completed receipt 12s (192000 frames) and clean12 audio agree -> no interruption
        let agreeID = UUID()
        let agreeDir = try self.writeBundle(
            segmentID: agreeID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let agreeReceipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: agreeID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 192000
        )
        try harness.store.writeAudioWriterReceipt(agreeReceipt, in: agreeDir)
        let agreeCountBefore = harness.store.audioInterruptionCount()
        let agreeResult = try await harness.uploader.resolveFinalizeFailure(segmentID: agreeID, directory: agreeDir, lifecycle: .failed)
        XCTAssertEqual(agreeResult, .repend)
        XCTAssertEqual(harness.store.audioInterruptionCount(), agreeCountBefore)

        // 4. Duration mismatch: completed receipt says 60s (960000 frames), but audio is clean12 (12s)
        let mismatchID = UUID()
        let mismatchDir = try self.writeBundle(
            segmentID: mismatchID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let mismatchReceipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: mismatchID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 960000
        )
        try harness.store.writeAudioWriterReceipt(mismatchReceipt, in: mismatchDir)
        let mismatchResult = try await harness.uploader.resolveFinalizeFailure(segmentID: mismatchID, directory: mismatchDir, lifecycle: .failed)
        XCTAssertEqual(mismatchResult, .repend)
        let mismatchPendingManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: mismatchID))
        XCTAssertEqual(try XCTUnwrap(mismatchPendingManifest.audio.durationS), 12.0, accuracy: 1.0 / 16000)
        let mismatchInterruption = try harness.store.readTombstone(at: harness.store.audioInterruptionDirectory().appendingPathComponent("\(mismatchID.uuidString).json"))
        XCTAssertEqual(mismatchInterruption.reason, "audio_writer_duration_mismatch")

        // 5. Writing receipt with stale non-zero frames stores 10.876
        let staleFramesID = UUID()
        let staleDir = try self.writeBundle(
            segmentID: staleFramesID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let staleReceipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: staleFramesID,
            phase: .writing,
            sampleRate: 16000,
            acceptedFrames: 50000
        )
        try harness.store.writeAudioWriterReceipt(staleReceipt, in: staleDir)
        let staleResult = try await harness.uploader.resolveFinalizeFailure(segmentID: staleFramesID, directory: staleDir, lifecycle: .failed)
        XCTAssertEqual(staleResult, .repend)
        let stalePendingManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: staleFramesID))
        XCTAssertEqual(try XCTUnwrap(stalePendingManifest.audio.durationS), 10.876, accuracy: 1.0 / 16000)

        // 6. Completed 0 frames defers
        let zeroFramesID = UUID()
        let zeroDir = try self.writeBundle(
            segmentID: zeroFramesID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let zeroReceipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: zeroFramesID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 0
        )
        try harness.store.writeAudioWriterReceipt(zeroReceipt, in: zeroDir)
        let zeroResult = try await harness.uploader.resolveFinalizeFailure(segmentID: zeroFramesID, directory: zeroDir, lifecycle: .failed)
        XCTAssertEqual(zeroResult, .deferred)
    }

    func testEvidenceWriteFailureRecoversCleanly() async throws {
        self.stubDelivered()
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")

        let blockerURL = harness.store.rootURL.appendingPathComponent("interruptions")
        try Data("blocker".utf8).write(to: blockerURL, options: .atomic)

        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-1200)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            let locationURL = harness.store.locationURL(in: directory)
            try Data(#"{"fix_count":1,"kind":"location","schema":"solstone.location.segment/1"}"#.utf8)
                .write(to: locationURL, options: .atomic)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .writing,
            sampleRate: 16000,
            acceptedFrames: 0
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        do {
            _ = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
            XCTFail("Expected resolveFinalizeFailure to throw when interruptions blocker exists")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
            let manifest = try harness.store.readManifest(in: failedDirectory)
            XCTAssertNotEqual(manifest.audio.state, .finalizedArtifact)
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
            XCTAssertEqual(harness.store.audioInterruptionCount(), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: failedDirectory).path))
            XCTAssertEqual(manifest.location.durationS, 300)
        }

        try FileManager.default.removeItem(at: blockerURL)

        let newHarness = try await self.makeHarness()
        let newUploader = MobileSegmentUploader(transferEngine: newHarness.engine, store: harness.store, clock: self.clock)
        await newUploader.resumeFromDisk()

        let snapshots = await newHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let itemSnapshots = snapshots.filter { $0.manifest.itemID == segmentID }
        XCTAssertEqual(itemSnapshots.count, 1)
        let snapshot = try XCTUnwrap(itemSnapshots.first)
        XCTAssertEqual(try XCTUnwrap(snapshot.manifest.observerIngest?.durationS), 10.876, accuracy: 1.0 / 16000)
        let segmentName = try XCTUnwrap(snapshot.manifest.observerIngest?.segment)
        XCTAssertTrue(segmentName.hasSuffix("_11"))
        XCTAssertTrue(snapshot.manifest.payloadParts.contains(where: { $0.relativePath == "location.jsonl" }))
        XCTAssertEqual(harness.store.audioInterruptionCount(), 1)
        let interruption = try harness.store.readTombstone(
            at: harness.store.audioInterruptionDirectory().appendingPathComponent("\(segmentID.uuidString).json")
        )
        XCTAssertEqual(interruption.reason, "audio_capture_unfinished")
    }

    func testMismatchWrittenBeforePublicationThrowsAndRecovers() async throws {
        let harness = try await self.makeHarness()
        let cleanFixtureURL = try self.audioRecoveryFixtureURL(named: "clean12.m4a")

        let blockerURL = harness.store.rootURL.appendingPathComponent("interruptions")
        try Data("blocker".utf8).write(to: blockerURL, options: .atomic)

        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 960000
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        do {
            _ = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
            XCTFail("Expected resolveFinalizeFailure to throw")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
            let manifest = try harness.store.readManifest(in: failedDirectory)
            XCTAssertNotEqual(manifest.audio.state, .finalizedArtifact)
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        }

        try FileManager.default.removeItem(at: blockerURL)

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
        XCTAssertEqual(result, .repend)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(try XCTUnwrap(manifest.audio.durationS), 12.0, accuracy: 1.0 / 16000)
        let interruption = try harness.store.readTombstone(
            at: harness.store.audioInterruptionDirectory().appendingPathComponent("\(segmentID.uuidString).json")
        )
        XCTAssertEqual(interruption.reason, "audio_writer_duration_mismatch")
    }

    func testGenerated60sControlPublishesWithoutInterruption() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try MobileSegmentTestFixtures.writeReadableAudio(at: audioURL, seconds: 60)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 960000
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        let countBefore = harness.store.audioInterruptionCount()
        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
        XCTAssertEqual(result, .repend)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(try XCTUnwrap(manifest.audio.durationS), 60.0, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(manifest.durationS), 60.0, accuracy: 1.0 / 16000)
        XCTAssertEqual(harness.store.audioInterruptionCount(), countBefore)
    }

    func testTransientInspectIsNotMismatchAndDefers() async throws {
        let harness = try await self.makeHarness()
        let cleanFixtureURL = try self.audioRecoveryFixtureURL(named: "clean12.m4a")
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 192000
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        harness.uploader.audioInspector = PhoneAudioInspector { _ in .transient(domain: "test", code: 1) }

        let countBefore = harness.store.audioInterruptionCount()
        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
        XCTAssertEqual(result, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
        XCTAssertEqual(harness.store.audioInterruptionCount(), countBefore)
    }

    func testFaultedReceiptWithReasonAudioWriterFailed() async throws {
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .faulted,
            sampleRate: 16000,
            acceptedFrames: 0,
            reason: "audio_writer_failed"
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
        XCTAssertEqual(result, .repend)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(try XCTUnwrap(manifest.audio.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(manifest.durationS), 10.876, accuracy: 1.0 / 16000)
        let interruption = try harness.store.readTombstone(
            at: harness.store.audioInterruptionDirectory().appendingPathComponent("\(segmentID.uuidString).json")
        )
        XCTAssertEqual(interruption.reason, "audio_writer_failed")
    }

    func testCompletedReceiptPermanentInspectDefersWithoutInterruption() async throws {
        let harness = try await self.makeHarness()
        let cleanFixtureURL = try self.audioRecoveryFixtureURL(named: "clean12.m4a")
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: self.clock.now().addingTimeInterval(-1000)
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: cleanFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .completed,
            sampleRate: 16000,
            acceptedFrames: 192000
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        harness.uploader.audioInspector = PhoneAudioInspector { _ in
            .permanent(domain: "AVFoundationErrorDomain", code: -11829)
        }

        let countBefore = harness.store.audioInterruptionCount()
        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
        XCTAssertEqual(result, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
        XCTAssertEqual(harness.store.audioInterruptionCount(), countBefore)
    }

    func testOffsetOnlyStampPreservesDayAndOffsetWithNilTimeZone() async throws {
        let harness = try await self.makeHarness()
        let killedFixtureURL = try self.audioRecoveryFixtureURL(named: "killed12.m4a")
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-1500)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try Data(contentsOf: killedFixtureURL).write(to: audioURL, options: .atomic)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        var initialManifest = try harness.store.readManifest(in: failedDirectory)
        initialManifest.day = "2026-04-21"
        initialManifest.segment = "090000_290"
        initialManifest.tz = nil
        initialManifest.utcOffsetSeconds = -18000
        initialManifest.durationS = 290
        initialManifest.endedAt = startedAt.addingTimeInterval(290)
        try harness.store.writeManifest(initialManifest, in: failedDirectory)

        let receipt = PhoneAudioWriterReceipt(
            version: 1,
            segmentID: segmentID,
            phase: .writing,
            sampleRate: 16000,
            acceptedFrames: 0
        )
        try harness.store.writeAudioWriterReceipt(receipt, in: failedDirectory)

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)
        XCTAssertEqual(result, .repend)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let recoveredManifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(recoveredManifest.segment, "090000_11")
        XCTAssertNil(recoveredManifest.tz)
        XCTAssertEqual(recoveredManifest.day, "2026-04-21")
        XCTAssertEqual(recoveredManifest.utcOffsetSeconds, -18000)
        XCTAssertEqual(try XCTUnwrap(recoveredManifest.durationS), 10.876, accuracy: 1.0 / 16000)
        XCTAssertEqual(try XCTUnwrap(recoveredManifest.audio.durationS), 10.876, accuracy: 1.0 / 16000)
    }

    func testFailedAudioSurvivorDeadLocationRequeuesAudioOnly() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertEqual(manifest.location.reason, "location_no_local_data")
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("audio survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }

        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testUnrecoverableLocationOnlyWritesLostDataEmptyTombstone() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        let tombstone = try self.emptyTombstone(segmentID: segmentID, store: harness.store)
        XCTAssertEqual(tombstone.reason, "unrecoverable_lost_data")
        XCTAssertNotEqual(tombstone.reason, "no_artifacts")
    }

    func testFailedAudioPresentReadableContainerPromotesWithoutLostDataTombstone() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-3_600)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try MobileSegmentTestFixtures.writeReadableAudio(at: audioURL, seconds: 400)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.audio.durationS, 300)
        XCTAssertEqual(manifest.audio.mode, .meeting)
        XCTAssertEqual(try self.emptyTombstoneCount(store: harness.store), 0)
    }

    // AC13 inversion & AC9
    func testFailedAudioPresentUndecodableRetiresWithAudioUndecodableTombstone() async throws {
        let diagnosticLog = DiagnosticLog()
        let harness = try await self.makeHarness(diagnosticLog: diagnosticLog)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-120)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            let audioURL = harness.store.audioURL(in: directory)
            try MobileSegmentTestFixtures.writeFtypOnlyAudio(at: audioURL)
            try MobileSegmentTestFixtures.setAudioModificationDate(at: audioURL, offset: -400, clock: self.clock)
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        let tombstone = try self.emptyTombstone(segmentID: segmentID, store: harness.store)
        XCTAssertEqual(tombstone.reason, "audio_undecodable_container")

        let uploadEvents = diagnosticLog.filtered(by: [.upload])
        let event = try XCTUnwrap(uploadEvents.first { $0.detail?.contains(segmentID.uuidString) == true })
        XCTAssertEqual(event.severity, DiagnosticSeverity.warning)
        XCTAssertEqual(event.message, "needs attention")
        let detail = try XCTUnwrap(event.detail)
        XCTAssertTrue(detail.contains("source=audio"))
        XCTAssertTrue(detail.contains("reason=audio_undecodable_container"))
        XCTAssertTrue(detail.contains("domain=AVFoundationErrorDomain"))
        XCTAssertTrue(detail.contains("code=-11829"))
    }

    func testFailedLiveLocationPartialCorruptPartSalvagesLocationAndRequeuesBoth() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.liveLocation.writeLocationPart(
                segmentID: segmentID,
                store: harness.store,
                directory: directory,
                startedAt: startedAt,
                fixes: [self.liveLocation.locationFix(at: startedAt.addingTimeInterval(60))]
            )
            try harness.store.appendData(Data("not json\n".utf8), to: harness.store.locationPartURL(in: directory))
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.reason, "location_live_partial_salvage")
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("partial location delivery after corrupt line") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }

        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio", "location"]))
    }

    func testFailedLiveLocationMissingStateRemovesLocationRequeuesAudio() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try Data("not json\n".utf8).write(to: harness.store.locationPartURL(in: directory), options: .atomic)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertEqual(manifest.location.reason, "location_live_corrupt")
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("audio delivery after missing location state") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }

        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testUnrecoverableCorruptLocationOnlyTombstones() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            try Data("not json\n".utf8).write(to: harness.store.locationPartURL(in: directory), options: .atomic)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        let tombstone = try self.emptyTombstone(segmentID: segmentID, store: harness.store)
        XCTAssertEqual(tombstone.reason, "unrecoverable_lost_data")
        XCTAssertNotEqual(tombstone.reason, "no_artifacts")
    }

    func testFailedLiveLocationPartRecoversBeforeDiscarding() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            try self.liveLocation.writeLocationPart(
                segmentID: segmentID,
                store: harness.store,
                directory: directory,
                startedAt: startedAt,
                fixes: [self.liveLocation.locationFix(at: startedAt.addingTimeInterval(60))]
            )
            try self.liveLocation.writeLocationLiveness(
                segmentID: segmentID,
                store: harness.store,
                directory: directory,
                lastSeenAt: endedAt
            )
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: pendingDirectory).path))

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("recovered location delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["location"]))
    }

    func testScheduleUploadResolvesPendingFinalizeFailureInPlaceWithoutRecursing() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let pendingDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .pending,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        self.stubDelivered()

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("pending finalize-failure delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }

        XCTAssertEqual(MobileSegmentFinalizeResolverURLProtocol.callCount, 1)
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testFinalizeFailureResolverIsIdempotentAcrossRepeatedPilePasses() async throws {
        let harness = try await self.makeHarness()
        let survivorID = UUID()
        let retiredID = UUID()
        _ = try self.writeBundle(
            segmentID: survivorID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: retiredID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        self.stubDelivered()

        await harness.uploader.resolveFinalizeFailurePile()
        try await self.waitFor("first idempotence pass") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: survivorID).path)
        }
        XCTAssertNotNil(try self.emptyTombstone(segmentID: retiredID, store: harness.store))

        await harness.uploader.resolveFinalizeFailurePile()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(MobileSegmentFinalizeResolverURLProtocol.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: retiredID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: survivorID).path))
        XCTAssertEqual(try self.emptyTombstoneCount(store: harness.store), 1)
    }

    func testFinalizeFailurePileKeepsPoisonFailedAndStillDrainsRecoverableSegment() async throws {
        let harness = try await self.makeHarness()
        let poisonID = UUID()
        let recoverableID = UUID()
        let poisonDirectory = try self.writeBundle(
            segmentID: poisonID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try FileManager.default.createDirectory(at: harness.store.locationPartURL(in: directory), withIntermediateDirectories: true)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: recoverableID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        self.stubDelivered()

        await harness.uploader.resolveFinalizeFailurePile()
        try await self.waitFor("batch isolation survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: recoverableID).path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: poisonDirectory.path))
        let poisonManifest = try harness.store.readManifest(in: poisonDirectory)
        XCTAssertEqual(poisonManifest.location.state, .failedToFinalize)
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testResolveFinalizeFailurePileStrictlyDecreasesRecoverableFinalizeFailurePile() async throws {
        let harness = try await self.makeHarness()
        let audioSurvivorID = UUID()
        let recoveredLocationID = UUID()
        let locationSurvivorID = UUID()
        _ = try self.writeBundle(
            segmentID: audioSurvivorID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: recoveredLocationID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try self.liveLocation.writeLocationPart(
                segmentID: recoveredLocationID,
                store: harness.store,
                directory: directory,
                startedAt: startedAt,
                fixes: [self.liveLocation.locationFix(at: startedAt.addingTimeInterval(30))]
            )
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: locationSurvivorID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFinalizedLocation(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let beforeCount = try harness.store.list(.failed).count
        self.stubDelivered()

        await harness.uploader.resolveFinalizeFailurePile()
        try await self.waitFor("strict count decrease deliveries") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 3
                && ((try? harness.store.list(.failed).count) ?? beforeCount) < beforeCount
        }

        let sourceSets = try MobileSegmentFinalizeResolverURLProtocol.receivedBodies.map { try self.sources(in: $0).sorted() }
        XCTAssertEqual(sourceSets.filter { $0 == ["audio"] }.count, 1)
        XCTAssertEqual(sourceSets.filter { $0 == ["location"] }.count, 2)
        XCTAssertEqual(try harness.store.list(.failed).count, 0)
    }

    func testFailedLocationSurvivorDeadAudioRequeuesLocationOnly() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFinalizedLocation(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .removed)
        XCTAssertEqual(manifest.audio.reason, "audio_no_local_data")
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("location survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["location"]))
    }

    func testDeadScreencastFacetIsRemovedWithoutTombstoneWhileSurvivorRemains() async throws {
        let harness = try await self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .screencast]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .screencast, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try await harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.screencast.state, .removed)
        XCTAssertEqual(manifest.screencast.reason, "screencast_removed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
                .path
        ))

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("screencast survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }
}

private extension MobileSegmentFinalizeResolverTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let engine: TransferEngine
    }

    var liveLocation: MobileSegmentLiveLocationTestSupport {
        MobileSegmentLiveLocationTestSupport(clock: self.clock)
    }

    func makeHarness(connected: Bool = true, maxAttempts: Int = 1, diagnosticLog: DiagnosticLog? = nil) async throws -> Harness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentFinalizeResolverURLProtocol.self]
        configuration.httpAdditionalHeaders = [MobileSegmentFinalizeResolverURLProtocol.testIDHeader: self.testID!]
        _ = maxAttempts
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true),
            sessionConfiguration: configuration,
            endpointResolver: connected
                ? TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
                : TransferCutoverEndpointResolver()
        )
        self.engines.append(transferHarness.engine)
        try await transferHarness.engine.start()
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        let uploader = MobileSegmentUploader(transferEngine: transferHarness.engine, store: store, clock: self.clock, diagnosticLog: diagnosticLog)
        return Harness(
            uploader: uploader,
            store: store,
            engine: transferHarness.engine
        )
    }

    func writeBundle(
        segmentID: UUID,
        store: MobileSegmentStore,
        lifecycle: MobileSegmentLifecycle,
        sources: Set<MobileSegmentSource>,
        startedAt: Date? = nil,
        configure: (URL, inout MobileSegmentManifest, Date, Date) throws -> Void
    ) throws -> URL {
        let startedAt = startedAt ?? self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: 1
        )
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)
        try configure(directory, &manifest, startedAt, endedAt)

        manifest = try store.readManifest(in: directory)
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        try store.writeManifest(manifest, in: directory)
        if lifecycle == .failed {
            try store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: "test failure",
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 1,
                    stage: "test",
                    lastAttemptAt: endedAt
                ),
                in: directory
            )
        }
        guard lifecycle != .active else { return directory }
        return try store.move(segmentID: segmentID, from: .active, to: lifecycle)
    }

    func writeFinalizedAudio(
        store: MobileSegmentStore,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let audioURL = store.audioURL(in: directory)
        try Data("audio-\(manifest.segmentID.uuidString)".utf8).write(to: audioURL, options: .atomic)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: store.fileSize(at: audioURL),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            mode: .meeting
        )
        try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
    }

    func writeFinalizedLocation(
        store: MobileSegmentStore,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let locationURL = store.locationURL(in: directory)
        try Data(#"{"fix_count":1,"kind":"location","schema":"solstone.location.segment/1"}"#.utf8)
            .write(to: locationURL, options: .atomic)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "location.jsonl",
            bytes: store.fileSize(at: locationURL),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            fixCount: 1
        )
        try store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
    }

    func writeFailedOutcome(
        source: MobileSegmentSource,
        store: MobileSegmentStore,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let resolution = MobileSegmentSourceResolution(
            state: .failedToFinalize,
            startedAt: startedAt,
            endedAt: endedAt,
            reason: "\(source.rawValue)_finalize_failed",
            stage: "test",
            lastAttemptAt: endedAt,
            mode: source == .audio ? .meeting : nil
        )
        try store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
    }

    func stubDelivered() {
        MobileSegmentFinalizeResolverURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok"}"#.utf8)
            )
        }
    }

    func waitFor(_ label: String, timeout: Duration = .seconds(5), condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    func sources(in body: Data) throws -> Set<String> {
        let envelope = try self.multipartEnvelope(in: body)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        let sources = try XCTUnwrap(meta["sources"] as? [String])
        return Set(sources)
    }

    func emptyTombstone(segmentID: UUID, store: MobileSegmentStore) throws -> MobileSegmentTombstone {
        let tombstoneURL = store.tombstoneDirectory(kind: "empty")
            .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileSegmentTombstone.self, from: Data(contentsOf: tombstoneURL))
    }

    func emptyTombstoneCount(store: MobileSegmentStore) throws -> Int {
        let directory = store.tombstoneDirectory(kind: "empty")
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == "json" }.count
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private final class MobileSegmentFinalizeResolverURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    static let testIDHeader = "X-Finalize-Resolver-Test-ID"

    private struct State {
        var testID: String?
        var handler: Handler?
        var callCount = 0
        var bodies: [Data] = []
        var lateRequests: [String] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var handler: Handler? {
        get { self.state.withLock { $0.handler } }
        set { self.state.withLock { $0.handler = newValue } }
    }

    static var callCount: Int {
        self.state.withLock { $0.callCount }
    }

    static var receivedBodies: [Data] {
        self.state.withLock { $0.bodies }
    }

    static func beginTest(id: String) {
        self.state.withLock { $0 = State(testID: id) }
    }

    static func reset() {
        self.state.withLock {
            $0.testID = nil
            $0.handler = nil
            $0.callCount = 0
            $0.bodies = []
        }
    }

    static func assertNoLateRequests(file: StaticString = #filePath, line: UInt = #line) {
        let requests = self.state.withLock { $0.lateRequests }
        XCTAssertTrue(requests.isEmpty, "Requests reached the protocol after teardown: \(requests)", file: file, line: line)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        XCTAssertNil(self.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            self.request.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName),
            ObserverServerURL.ingestProtocolVersion
        )
        let body = Self.bodyData(from: self.request)
        let requestTestID = self.request.value(forHTTPHeaderField: Self.testIDHeader)
        let admission = Self.state.withLock { state -> (Handler?, Bool) in
            guard let requestTestID, requestTestID == state.testID else {
                state.lateRequests.append(requestTestID ?? "missing test ID")
                return (nil, false)
            }
            state.bodies.append(body)
            state.callCount += 1
            return (state.handler, true)
        }
        guard admission.1 else {
            XCTFail("Request outlived its test and reached MobileSegmentFinalizeResolverURLProtocol after reset()")
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        guard let handler = admission.0 else {
            XCTFail("MobileSegmentFinalizeResolverURLProtocol handler not set")
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            var (response, data) = try handler(self.request)
            if response.statusCode == 200 && data == Data(#"{"status":"ok"}"#.utf8) {
                data = transferTestMatchingReceipt(
                    body: body,
                    contentType: self.request.value(forHTTPHeaderField: "Content-Type")
                )
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var output = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            output.append(buffer, count: read)
        }
        return output
    }
}
