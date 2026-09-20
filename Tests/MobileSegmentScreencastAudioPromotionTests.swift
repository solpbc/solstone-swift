// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreMedia
import Foundation
import ReplayKit
import XCTest

@MainActor
final class MobileSegmentScreencastAudioPromotionTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() async throws {
        try await super.setUp()
        TransferURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentPromotionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() async throws {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        try await super.tearDown()
    }

    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let engine: TransferEngine
    }

    func makeHarness(
        endpointAvailable: Bool = false,
        store: MobileSegmentStore? = nil,
        withTransferEngine: Bool = true,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) -> Harness {
        let store = store ?? MobileSegmentStore(
            rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        )
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("Transfers-\(UUID().uuidString)", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: endpointAvailable
                ? TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
                : TransferCutoverEndpointResolver()
        )
        return Harness(
            uploader: MobileSegmentUploader(
                transferEngine: withTransferEngine ? transferHarness.engine : nil,
                store: store,
                clock: self.clock,
                cooperator: cooperator
            ),
            store: store,
            engine: transferHarness.engine
        )
    }

    // MARK: - Unit Tests

    func testPromotedScreenAudioReasonValue() {
        XCTAssertEqual(MobileSegmentManifest.promotedScreenAudioReason, "screen_broadcast")
    }

    func testPromoteScreenAudioManifestHelper() {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(300)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )

        XCTAssertFalse(manifest.openedWithSources.contains(.audio))
        XCTAssertEqual(manifest.audio.state, .notDeclared)

        let resolution = manifest.promoteScreenAudio(
            bytes: 12345,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 300,
            now: endedAt
        )

        XCTAssertTrue(manifest.openedWithSources.contains(.audio))
        XCTAssertEqual(resolution.state, .finalizedArtifact)
        XCTAssertEqual(resolution.artifactFilename, "audio.m4a")
        XCTAssertEqual(resolution.bytes, 12345)
        XCTAssertEqual(resolution.durationS, 300)
        XCTAssertEqual(resolution.reason, MobileSegmentManifest.promotedScreenAudioReason)
        XCTAssertEqual(resolution.mode, .meeting)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.audio.artifactFilename, "audio.m4a")
        XCTAssertEqual(manifest.audio.reason, MobileSegmentManifest.promotedScreenAudioReason)
        XCTAssertEqual(manifest.audio.mode, .meeting)
    }

    // MARK: - AC6

    func testAC6HappyScreencastAudioPromotion() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)

        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioURL, seconds: 60)
        let expectedAudioBytes = try Data(contentsOf: screenAudioURL)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })

        XCTAssertEqual(snapshot.manifest.observerIngest?.sources, ["audio", "screencast"])
        let partIDs = snapshot.manifest.payloadParts.map(\.partID)
        XCTAssertEqual(partIDs, ["audio", "screencast"])

        let payloadAudioURL = await harness.engine.payloadFileURL(itemID: segmentID, partID: "audio")
        let actualPayloadURL = try XCTUnwrap(payloadAudioURL)
        let actualAudioData = try Data(contentsOf: actualPayloadURL)
        XCTAssertEqual(actualAudioData, expectedAudioBytes)

        let tombstoneURL = harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(segmentID.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstoneURL.path))
    }

    func testAC6TwinNoScreenMp4FreshLivenessRemainsActive() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioURL, seconds: 60)

        // Write fresh liveness (lastSeenAt == endedAt)
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: UUID(),
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: endedAt,
            acceptedFrameCount: 1,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            liveness,
            to: MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: activeDir)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        // Must remain in active
        XCTAssertTrue(harness.store.fileExists(activeDir))
        let readManifest = try harness.store.readManifest(in: activeDir)
        XCTAssertEqual(readManifest.audio.state, .notDeclared)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testAC6TwinScreenMp4OnlyNoMicFileScreencastOnlySnapshot() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })

        XCTAssertEqual(snapshot.manifest.payloadParts.map(\.partID), ["screencast"])
        let audioPayload = await harness.engine.payloadFileURL(itemID: segmentID, partID: "audio")
        XCTAssertNil(audioPayload)
    }

    // MARK: - AC7

    func testAC7ResumeFromDiskActiveScreencastWithBothFiles() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioURL, seconds: 60)

        // Advance clock past rotation ceiling so screencast is terminal
        self.clock.advance(by: MobileSegmentDuration.rotationCeiling + 10)

        await harness.uploader.resumeFromDisk()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])
    }

    func testAC7RecordScreencastFinalizedThenFinalizeActiveSegmentSegmentDayDurationMatchesTwin() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        // Fixture with mic
        let micSegmentID = UUID()
        let micManifest = MobileSegmentManifest(
            segmentID: micSegmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let micActiveDir = try harness.store.createActive(manifest: micManifest)
        let micScreenURL = harness.store.screenURL(in: micActiveDir)
        let micAudioURL = harness.store.screenAudioURL(in: micActiveDir)
        try Data(repeating: 0xAA, count: 1024).write(to: micScreenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: micAudioURL, seconds: 60)
        try harness.uploader.recordScreencastFinalized(
            segmentID: micSegmentID,
            artifactURL: micScreenURL,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60
        )
        await harness.uploader.finalizeActiveSegment(segmentID: micSegmentID, endedAt: endedAt)

        // Fixture without mic (twin)
        let noMicSegmentID = UUID()
        let noMicManifest = MobileSegmentManifest(
            segmentID: noMicSegmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let noMicActiveDir = try harness.store.createActive(manifest: noMicManifest)
        let noMicScreenURL = harness.store.screenURL(in: noMicActiveDir)
        try Data(repeating: 0xAA, count: 1024).write(to: noMicScreenURL)
        try harness.uploader.recordScreencastFinalized(
            segmentID: noMicSegmentID,
            artifactURL: noMicScreenURL,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60
        )
        await harness.uploader.finalizeActiveSegment(segmentID: noMicSegmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let micSnapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == micSegmentID })
        let noMicSnapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == noMicSegmentID })

        let micIngest = try XCTUnwrap(micSnapshot.manifest.observerIngest)
        let noMicIngest = try XCTUnwrap(noMicSnapshot.manifest.observerIngest)

        XCTAssertEqual(micIngest.segment, noMicIngest.segment)
        XCTAssertEqual(micIngest.day, noMicIngest.day)
        XCTAssertEqual(micIngest.durationS, noMicIngest.durationS)
        XCTAssertFalse(micIngest.segment.contains("_1"))
    }

    func testAC7ManifestLessActiveDirectoryAdoptionAndPromotion() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let activeDir = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)
        let sidecarURL = MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: activeDir)

        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioURL, seconds: 60)

        let sidecar = MobileSegmentScreencastWindowSidecar(
            schemaVersion: 1,
            sessionID: UUID(),
            revision: 1,
            windowIndex: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
        try MobileSegmentScreencastJSONStore.write(sidecar, to: sidecarURL)

        self.clock.advance(by: MobileSegmentDuration.rotationCeiling + 10)

        await harness.uploader.resumeFromDisk()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])
    }

    func testAC7LockKillUnfinalizedAudioPartDiscardedScreenOnlyEnqueues() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)

        // Write real unfinalized audio .part with ScreencastBroadcastAudioWriter
        let realAudioWriter = ScreencastBroadcastAudioWriter()
        let handoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: UUID(),
            segmentID: segmentID,
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: startedAt,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            scheduleAnchorMs: Int64(startedAt.timeIntervalSince1970 * 1000),
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: startedAt
        )
        try realAudioWriter.open(
            rootURL: self.tempDirectory,
            handoff: handoff,
            now: startedAt
        )
        for i in 0..<30 {
            let pts = CMTime(value: Int64(i * 1600), timescale: 16000)
            let sample = self.makePCMSampleBuffer(pts: pts)
            try realAudioWriter.appendAudio(sample, now: startedAt.addingTimeInterval(Double(i) * 0.1))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Do NOT finish writing, leaves empty 0-byte .part on disk
        let partURL = harness.store.screenAudioPartURL(in: activeDir)
        XCTAssertTrue(harness.store.fileExists(partURL))
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(fileSize, 0, "unfinalized AVAssetWriter .part is 0 bytes")

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["screencast"])
    }

    func testAC7PlayableAudioPartPromoted() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioPartURL = harness.store.screenAudioPartURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioPartURL, seconds: 60)

        let partData = try Data(contentsOf: screenAudioPartURL)
        let probed = await MobileSegmentDuration.probeContainerDuration(at: screenAudioPartURL)
        XCTAssertNotNil(probed)
        let probedDuration = try XCTUnwrap(probed)
        XCTAssertGreaterThan(probedDuration, 0)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])

        let payloadAudio = await harness.engine.payloadFileURL(itemID: segmentID, partID: "audio")
        let payloadAudioURL = try XCTUnwrap(payloadAudio)
        let payloadAudioData = try Data(contentsOf: payloadAudioURL)
        XCTAssertEqual(payloadAudioData, partData)
    }

    // MARK: - AC8

    func testAC8ScreencastAlreadyFinalizedMoveErrorRetainsActiveThenRetries() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioURL, seconds: 60)

        // Mark screencast finalized
        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "screen.mp4",
                bytes: 1024,
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            ),
            source: .screencast,
            manifest: &manifest,
            in: activeDir,
            now: endedAt
        )

        harness.store.testMoveItemError = NSError(domain: "test", code: -100, userInfo: nil)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        // Still in active, no failure.json, no tombstone, audio undeclared, screen-audio.m4a intact
        XCTAssertTrue(harness.store.fileExists(activeDir))
        let failureURL = harness.store.failureURL(in: activeDir)
        XCTAssertFalse(harness.store.fileExists(failureURL))
        let tombstoneURL = harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(segmentID.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstoneURL.path))
        XCTAssertTrue(harness.store.fileExists(screenAudioURL))
        let intermediateManifest = try harness.store.readManifest(in: activeDir)
        XCTAssertEqual(intermediateManifest.audio.state, .notDeclared)

        // Second pass: clear hook
        harness.store.testMoveItemError = nil
        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])
    }

    func testAC8ScreencastAlreadyFinalizedWriteManifestErrorRetainsActive() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: screenAudioURL, seconds: 60)

        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "screen.mp4",
                bytes: 1024,
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            ),
            source: .screencast,
            manifest: &manifest,
            in: activeDir,
            now: endedAt
        )

        harness.store.testWriteManifestError = NSError(domain: "test", code: -101, userInfo: nil)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        // Throws on promotion writeManifest -> caught by outer handler -> remains in active
        XCTAssertTrue(harness.store.fileExists(activeDir))

        // Second pass: clear hook
        harness.store.testWriteManifestError = nil
        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])
    }

    func testAC8InterruptedAudioM4aOnDiskDeclaredAndResolved() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let audioURL = harness.store.audioURL(in: activeDir)

        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeReadableAudio(at: audioURL, seconds: 60)

        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "screen.mp4",
                bytes: 1024,
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            ),
            source: .screencast,
            manifest: &manifest,
            in: activeDir,
            now: endedAt
        )

        // audio is not declared in manifest, but audio.m4a is on disk (interrupted rename)
        XCTAssertEqual(manifest.audio.state, .notDeclared)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])
        XCTAssertEqual(snapshot.manifest.observerIngest?.modeRawValue, "meeting")
    }

    // MARK: - AC9

    func testExistingAudioWins() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio, .screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenPartURL = harness.store.screenPartURL(in: activeDir)
        let audioURL = harness.store.audioURL(in: activeDir)
        let screenAudioURL = harness.store.screenAudioURL(in: activeDir)

        try Data(repeating: 0xAA, count: 1024).write(to: screenPartURL)
        let originalAudioData = Data(repeating: 0x11, count: 5000)
        try originalAudioData.write(to: audioURL)
        let originalScreenAudioData = Data(repeating: 0x22, count: 2000)
        try originalScreenAudioData.write(to: screenAudioURL)

        let audioResolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: 5000,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            mode: .meeting
        )
        try harness.store.writeOutcome(audioResolution, source: .audio, manifest: &manifest, in: activeDir, now: endedAt)

        // Write fresh liveness so active directory is preserved during first finalize
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: UUID(),
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: endedAt,
            acceptedFrameCount: 1,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            liveness,
            to: MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: activeDir)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        // While active, screen-audio.m4a is neither renamed nor deleted next to intact audio.m4a
        XCTAssertTrue(harness.store.fileExists(screenAudioURL))
        XCTAssertTrue(harness.store.fileExists(audioURL))
        XCTAssertEqual(try Data(contentsOf: audioURL), originalAudioData)
        XCTAssertEqual(try Data(contentsOf: screenAudioURL), originalScreenAudioData)

        // Advance past rotation ceiling so screencast becomes terminal and segment enqueues
        self.clock.advance(by: MobileSegmentDuration.rotationCeiling + 10)
        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        _ = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })

        // Audio payload in transfer matches original audio.m4a
        let payloadAudio = await harness.engine.payloadFileURL(itemID: segmentID, partID: "audio")
        let payloadAudioURL = try XCTUnwrap(payloadAudio)
        let payloadAudioData = try Data(contentsOf: payloadAudioURL)
        XCTAssertEqual(payloadAudioData, originalAudioData)
    }

    func testAC9AudioNonArtifactPreservesExtensionFile() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        for audioState in [MobileSegmentResolutionState.noArtifact, .failedToFinalize] {
            let segmentID = UUID()
            let startedAt = self.clock.now()
            let endedAt = startedAt.addingTimeInterval(60)

            var manifest = MobileSegmentManifest(
                segmentID: segmentID,
                startedAt: startedAt,
                openedWithSources: [.audio, .screencast],
                activeSourceSetVersion: 1
            )
            let activeDir = try harness.store.createActive(manifest: manifest)

            let screenURL = harness.store.screenURL(in: activeDir)
            let screenAudioURL = harness.store.screenAudioURL(in: activeDir)

            try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
            try Data(repeating: 0x22, count: 2000).write(to: screenAudioURL)

            let audioResolution = MobileSegmentSourceResolution(
                state: audioState,
                reason: "test",
                stage: "test",
                lastAttemptAt: endedAt
            )
            try harness.store.writeOutcome(audioResolution, source: .audio, manifest: &manifest, in: activeDir, now: endedAt)

            await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
            if audioState == .noArtifact {
                let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
                XCTAssertEqual(snapshot.manifest.payloadParts.map(\.partID), ["screencast"])
            }
        }
    }

    func testAC9RealEngineAndBroadcastSessionReAnchorPromotion() async throws {
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        try store.ensureRoot()

        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration()
        )
        try await transferHarness.engine.start()

        let uploader = MobileSegmentUploader(
            transferEngine: transferHarness.engine,
            store: store,
            clock: self.clock
        )

        let engine = MobileSegmentEngine(
            uploader: uploader,
            clock: self.clock
        )

        var publishedHandoff: MobileSegmentScreencastHandoffRecord?
        engine.screencastRolloverHandler = { handoff in
            publishedHandoff = handoff
            return true
        }

        let sessionClock = TestSessionClock(initialDate: self.clock.now())
        let sessionID = UUID()
        let session = ScreencastBroadcastSession(
            rootURL: self.tempDirectory,
            writer: TestBroadcastWriter(),
            audioWriter: ScreencastBroadcastAudioWriter(),
            clock: { sessionClock.now() },
            availableBytes: { _ in 100_000_000 },
            postChanged: {},
            finishWithError: { _ in }
        )

        let initialHandoff = try await engine.startScreencast(at: self.clock.now())
        let initialDir = store.segmentDirectoryURL(.active, segmentID: initialHandoff.segmentID)
        try Data(repeating: 0xAA, count: 1024).write(to: store.screenURL(in: initialDir))
        try MobileSegmentTestFixtures.writeReadableAudio(at: store.screenAudioURL(in: initialDir), seconds: 5)
        session.broadcastStarted(sessionID: sessionID)
        self.clock.advance(by: 1.0)
        sessionClock.advance(by: 1.0)
        session.tick()

        // Append audio into window 0
        let sample = self.makePCMSampleBuffer(pts: CMTime(value: 0, timescale: 16000))
        session.processSampleBuffer(sample, kind: .audioMic)
        self.clock.advance(by: 5.0)
        sessionClock.advance(by: 5.0)

        // startAudio republishes handoff with new anchor (window 1)
        _ = try await engine.startAudio(mode: ObserverMode.meeting)
        _ = publishedHandoff
        self.clock.advance(by: 1.0)
        sessionClock.advance(by: 1.0)
        session.tick()

        // Next mic sample opens new directory
        session.processSampleBuffer(sample, kind: .audioMic)

        // Finalize window 0
        await uploader.finalizeActiveSegment(segmentID: initialHandoff.segmentID, endedAt: self.clock.now())

        let snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let window0Snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == initialHandoff.segmentID })
        XCTAssertTrue(window0Snapshot.manifest.payloadParts.contains { $0.partID == "audio" })
    }

    // MARK: - AC10

    func testAC10PromotedAudioDoesNotAlterSegmentDurationOrName() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        // Fixture A: promoted 40s screen-audio.m4a
        let idA = UUID()
        let manifestA = MobileSegmentManifest(
            segmentID: idA,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let dirA = try harness.store.createActive(manifest: manifestA)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: dirA))
        try MobileSegmentTestFixtures.writeReadableAudio(at: harness.store.screenAudioURL(in: dirA), seconds: 40)
        await harness.uploader.finalizeActiveSegment(segmentID: idA, endedAt: endedAt)

        // Fixture B: no mic
        let idB = UUID()
        let manifestB = MobileSegmentManifest(
            segmentID: idB,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let dirB = try harness.store.createActive(manifest: manifestB)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: dirB))
        await harness.uploader.finalizeActiveSegment(segmentID: idB, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapA = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == idA })
        let snapB = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == idB })

        XCTAssertEqual(snapA.manifest.observerIngest?.durationS, snapB.manifest.observerIngest?.durationS)
        XCTAssertEqual(snapA.manifest.observerIngest?.segment, snapB.manifest.observerIngest?.segment)
    }

    func testAC10ReFinalizeAfterMoveActivePreservesDurationAndSegment() async throws {
        let harness = self.makeHarness(withTransferEngine: false)

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: activeDir))
        try MobileSegmentTestFixtures.writeReadableAudio(at: harness.store.screenAudioURL(in: activeDir), seconds: 40)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let pendingDir = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let initialManifest = try harness.store.readManifest(in: pendingDir)

        _ = try harness.store.move(segmentID: segmentID, from: .pending, to: .active)
        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let reFinalizedManifest = try harness.store.readManifest(in: pendingDir)
        XCTAssertEqual(reFinalizedManifest.durationS, initialManifest.durationS)
        XCTAssertEqual(reFinalizedManifest.segment, initialManifest.segment)
    }

    func testAC10AppAudioFinalizedDurationPreserved() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio, .screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: activeDir))
        try Data(repeating: 0x11, count: 4000).write(to: harness.store.audioURL(in: activeDir))

        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "audio.m4a",
                bytes: 4000,
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 42,
                mode: .meeting
            ),
            source: .audio,
            manifest: &manifest,
            in: activeDir,
            now: endedAt
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(snapshot.manifest.observerIngest?.durationS, 42)
        XCTAssertEqual(snapshot.manifest.observerIngest?.segment, ChunkSidecar.segmentString(for: startedAt, durationSeconds: 42))
    }

    func testAC10PromotedEnqueueSourcesAndPartsOrdering() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: activeDir))
        try MobileSegmentTestFixtures.writeReadableAudio(at: harness.store.screenAudioURL(in: activeDir), seconds: 30)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })

        XCTAssertEqual(snapshot.manifest.observerIngest?.sources, ["audio", "screencast"])
        XCTAssertEqual(snapshot.manifest.payloadParts.map(\.partID), ["audio", "screencast"])
    }

    // MARK: - AC11

    func testAC11FailedToFinalizeScreencastSurvivorAudioEnqueued() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)
        try MobileSegmentTestFixtures.writeReadableAudio(at: harness.store.screenAudioURL(in: activeDir), seconds: 60)

        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .failedToFinalize,
                reason: "screen_error",
                stage: "test",
                lastAttemptAt: endedAt
            ),
            source: .screencast,
            manifest: &manifest,
            in: activeDir,
            now: endedAt
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        // Goes to failed lifecycle because screencast hasFinalizeFailure
        let failedDir = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(harness.store.fileExists(failedDir))

        // Resolve finalize failure (dead screencast removed) and resumeFromDisk
        _ = try await harness.uploader.resolveFinalizeFailure(
            segmentID: segmentID,
            directory: failedDir,
            lifecycle: .failed
        )
        await harness.uploader.resumeFromDisk()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(snapshot.manifest.payloadParts.map(\.partID), ["audio"])
    }

    // MARK: - AC12

    func testAC12SidecarEndedAtCappedToCeiling() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(40)
        let lateEndedAt = startedAt.addingTimeInterval(3 * 3600)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: activeDir))

        let sidecar = MobileSegmentScreencastWindowSidecar(
            schemaVersion: 1,
            sessionID: UUID(),
            revision: 1,
            windowIndex: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
        try MobileSegmentScreencastJSONStore.write(
            sidecar,
            to: MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: activeDir)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: lateEndedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(snapshot.manifest.observerIngest?.durationS, 40)
        XCTAssertLessThanOrEqual(snapshot.manifest.observerIngest?.durationS ?? 0, 300)
    }

    func testAC12SidecarEndedAtNilUsesProbedScreenDuration() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let lateEndedAt = startedAt.addingTimeInterval(3600)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        // Write readable video or audio fixture for probeContainerDuration
        try MobileSegmentTestFixtures.writeReadableAudio(at: harness.store.screenURL(in: activeDir), seconds: 120)

        let sidecar = MobileSegmentScreencastWindowSidecar(
            schemaVersion: 1,
            sessionID: UUID(),
            revision: 1,
            windowIndex: 0,
            startedAt: startedAt,
            endedAt: nil
        )
        try MobileSegmentScreencastJSONStore.write(
            sidecar,
            to: MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: activeDir)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: lateEndedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(snapshot.manifest.observerIngest?.durationS, 120)
    }

    func testAC12NoSidecarElapsedNoCeiling() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(3600)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)
        try Data(repeating: 0xAA, count: 1024).write(to: harness.store.screenURL(in: activeDir))

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })
        XCTAssertEqual(snapshot.manifest.observerIngest?.durationS, 3600)
    }

    // MARK: - AC5 Discard

    func testDiscardUnplayablePart() async throws {
        let harness = self.makeHarness()
        try await harness.engine.start()

        let segmentID = UUID()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)

        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let activeDir = try harness.store.createActive(manifest: manifest)

        let screenURL = harness.store.screenURL(in: activeDir)
        let screenAudioPartURL = harness.store.screenAudioPartURL(in: activeDir)
        try Data(repeating: 0xAA, count: 1024).write(to: screenURL)
        try MobileSegmentTestFixtures.writeFtypOnlyAudio(at: screenAudioPartURL)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID })

        XCTAssertEqual(snapshot.manifest.payloadParts.map(\.partID), ["screencast"])
        XCTAssertFalse(harness.store.fileExists(screenAudioPartURL))
        XCTAssertFalse(harness.store.fileExists(harness.store.audioURL(in: activeDir)))
    }

    // MARK: - Helpers

    private func makePCMSampleBuffer(
        sampleRate: Float64 = 16000.0,
        channels: UInt32 = 1,
        frameCount: Int = 1600,
        pts: CMTime
    ) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(formatStatus, noErr)
        guard let formatDesc else { fatalError("failed format description") }

        let byteCount = frameCount * Int(asbd.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, noErr)
        guard let blockBuffer else { fatalError("failed block buffer") }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frameCount), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr)
        guard let sampleBuffer else { fatalError("failed sample buffer") }
        return sampleBuffer
    }
}

private final class TestBroadcastWriter: ScreencastBroadcastWriting, @unchecked Sendable {
    var isOpen = false
    var openedHandoff: MobileSegmentScreencastHandoffRecord?
    var acceptedFrameCount = 0
    var droppedFrameCount: Int = 0

    func open(rootURL: URL, handoff: MobileSegmentScreencastHandoffRecord, now: Date) throws {
        self.isOpen = true
        self.openedHandoff = handoff
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, now: Date) {
        guard self.isOpen else { return }
        self.acceptedFrameCount += 1
    }

    func finish(now: Date) -> ScreencastBroadcastWriterOutcome {
        self.isOpen = false
        return self.acceptedFrameCount > 0 ? .completed : .noVideo
    }

    func writeLiveness(now: Date, force: Bool) throws {}
}

private final class TestSessionClock: @unchecked Sendable {
    var currentDate: Date

    init(initialDate: Date) {
        self.currentDate = initialDate
    }

    func now() -> Date {
        self.currentDate
    }

    func advance(by seconds: TimeInterval) {
        self.currentDate = self.currentDate.addingTimeInterval(seconds)
    }

    func set(to date: Date) {
        self.currentDate = date
    }
}
