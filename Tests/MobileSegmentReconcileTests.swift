// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentReconcileTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        MobileSegmentReconcileURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentReconcileTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        MobileSegmentReconcileURLProtocol.reset()
        super.tearDown()
    }

    func testResumeReconcilesActiveDirectoriesDeterministicallyWithoutDuplicateUpload() async throws {
        let harness = self.makeHarness()
        let finalizedWithFile = UUID()
        let finalizedMissingFile = UUID()
        let noArtifact = UUID()
        let unresolvedNoMarker = UUID()
        let uncleanAudio = UUID()

        try self.writeActiveAudio(segmentID: finalizedWithFile, store: harness.store, state: .finalizedArtifact, includeFile: true)
        try self.writeActiveAudio(segmentID: finalizedMissingFile, store: harness.store, state: .finalizedArtifact, includeFile: false)
        try self.writeActiveAudio(segmentID: noArtifact, store: harness.store, state: .noArtifact, includeFile: false)
        try self.writeActiveAudio(segmentID: unresolvedNoMarker, store: harness.store, state: .unresolved, includeFile: false)
        try self.writeActiveAudio(segmentID: uncleanAudio, store: harness.store, state: .unresolved, includeFile: true)
        MobileSegmentReconcileURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("first reconcile uploads") {
            MobileSegmentReconcileURLProtocol.callCount == 2
        }
        await harness.uploader.resumeFromDisk()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: finalizedWithFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: uncleanAudio).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: finalizedMissingFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: unresolvedNoMarker).path))
        XCTAssertEqual(try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.failed, segmentID: finalizedMissingFile)).audio.state, .finalizedArtifact)
        XCTAssertEqual(try harness.store.list(.active).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(noArtifact.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(unresolvedNoMarker.uuidString).json").path))
    }

    func testResumeReconcileAudioUsesReadableContainerDuration() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-3_600)
        let directory = try self.writeActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            sources: [.audio],
            startedAt: startedAt
        )
        try self.writeReadableAudio(at: harness.store.audioURL(in: directory), seconds: 12)

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.durationS ?? 0, 12, accuracy: 0.25)
        XCTAssertEqual(manifest.durationS ?? 0, 12, accuracy: 0.25)
        XCTAssertEqual(manifest.segment, ChunkSidecar.segmentString(for: startedAt, durationSeconds: 12))
    }

    func testResumeReconcileAudioClampsReadableContainerOverCeiling() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-3_600)
        let directory = try self.writeActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            sources: [.audio],
            startedAt: startedAt
        )
        try self.writeReadableAudio(at: harness.store.audioURL(in: directory), seconds: 301)

        await harness.uploader.resumeFromDisk()

        let manifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID))
        XCTAssertEqual(manifest.audio.durationS, 300)
        XCTAssertEqual(manifest.durationS, 300)
        XCTAssertEqual(manifest.segment, ChunkSidecar.segmentString(for: startedAt, durationSeconds: 300))
    }

    func testResumeReconcileUnreadableAudioBoundsElapsedFallback() async throws {
        let harness = self.makeHarness(connected: false)
        let hoursOldID = UUID()
        let ninetySecondID = UUID()
        let futureID = UUID()
        let hoursOld = self.clock.now().addingTimeInterval(-3_600)
        let ninetySecondsOld = self.clock.now().addingTimeInterval(-90)
        let future = self.clock.now().addingTimeInterval(10)
        let hoursDirectory = try self.writeActiveSegment(segmentID: hoursOldID, store: harness.store, sources: [.audio], startedAt: hoursOld)
        let ninetyDirectory = try self.writeActiveSegment(segmentID: ninetySecondID, store: harness.store, sources: [.audio], startedAt: ninetySecondsOld)
        let futureDirectory = try self.writeActiveSegment(segmentID: futureID, store: harness.store, sources: [.audio], startedAt: future)
        try Data("audio-\(hoursOldID.uuidString)".utf8).write(to: harness.store.audioURL(in: hoursDirectory), options: .atomic)
        try Data("audio-\(ninetySecondID.uuidString)".utf8).write(to: harness.store.audioURL(in: ninetyDirectory), options: .atomic)
        try Data("audio-\(futureID.uuidString)".utf8).write(to: harness.store.audioURL(in: futureDirectory), options: .atomic)

        await harness.uploader.resumeFromDisk()

        let hoursManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: hoursOldID))
        let ninetyManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: ninetySecondID))
        let futureManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: futureID))
        XCTAssertEqual(hoursManifest.audio.durationS, 300)
        XCTAssertEqual(hoursManifest.durationS, 300)
        XCTAssertEqual(hoursManifest.segment, ChunkSidecar.segmentString(for: hoursOld, durationSeconds: 300))
        XCTAssertEqual(ninetyManifest.audio.durationS, 90)
        XCTAssertEqual(ninetyManifest.durationS, 90)
        XCTAssertEqual(ninetyManifest.segment, ChunkSidecar.segmentString(for: ninetySecondsOld, durationSeconds: 90))
        XCTAssertEqual(futureManifest.audio.durationS, 1)
        XCTAssertEqual(futureManifest.durationS, 1)
        XCTAssertEqual(futureManifest.segment, ChunkSidecar.segmentString(for: future, durationSeconds: 1))
    }

    func testResumeReconcileUploadedMetadataUsesBoundedSegmentKey() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-3_600)
        let directory = try self.writeActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio], startedAt: startedAt)
        try Data("audio-\(segmentID.uuidString)".utf8).write(to: harness.store.audioURL(in: directory), options: .atomic)
        MobileSegmentReconcileURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("bounded metadata upload") {
            MobileSegmentReconcileURLProtocol.callCount == 1
        }

        let body = try XCTUnwrap(MobileSegmentReconcileURLProtocol.capturedBodies.first)
        let meta = try self.multipartMeta(in: body)
        XCTAssertEqual(meta["segment"] as? String, ChunkSidecar.segmentString(for: startedAt, durationSeconds: 300))
        XCTAssertEqual(meta["duration_s"] as? Double, 300)
    }

    func testResumeReconcileScreencastBoundsElapsedFallback() async throws {
        let harness = self.makeHarness(connected: false)
        let hoursOldID = UUID()
        let futureID = UUID()
        let hoursOld = self.clock.now().addingTimeInterval(-3_600)
        let future = self.clock.now().addingTimeInterval(10)
        let hoursDirectory = try self.writeActiveSegment(segmentID: hoursOldID, store: harness.store, sources: [.screencast], startedAt: hoursOld)
        let futureDirectory = try self.writeActiveSegment(segmentID: futureID, store: harness.store, sources: [.screencast], startedAt: future)
        try Data("screen-\(hoursOldID.uuidString)".utf8).write(to: harness.store.screenURL(in: hoursDirectory), options: .atomic)
        try Data("screen-\(futureID.uuidString)".utf8).write(to: harness.store.screenURL(in: futureDirectory), options: .atomic)

        await harness.uploader.resumeFromDisk()

        let hoursManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: hoursOldID))
        let futureManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: futureID))
        XCTAssertEqual(hoursManifest.resolution(for: .screencast).durationS, 300)
        XCTAssertEqual(futureManifest.resolution(for: .screencast).durationS, 1)
    }

    func testResumeReconcileLocationCanonicalArtifactBoundsElapsedFallback() async throws {
        let harness = self.makeHarness(connected: false)
        let hoursOldID = UUID()
        let futureID = UUID()
        let hoursOld = self.clock.now().addingTimeInterval(-3_600)
        let future = self.clock.now().addingTimeInterval(10)
        let hoursDirectory = try self.writeActiveSegment(segmentID: hoursOldID, store: harness.store, sources: [.location], startedAt: hoursOld)
        let futureDirectory = try self.writeActiveSegment(segmentID: futureID, store: harness.store, sources: [.location], startedAt: future)
        try Data("location-\(hoursOldID.uuidString)".utf8).write(to: harness.store.locationURL(in: hoursDirectory), options: .atomic)
        try Data("location-\(futureID.uuidString)".utf8).write(to: harness.store.locationURL(in: futureDirectory), options: .atomic)

        await harness.uploader.resumeFromDisk()

        let hoursManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: hoursOldID))
        let futureManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: futureID))
        XCTAssertEqual(hoursManifest.resolution(for: .location).durationS, 300)
        XCTAssertEqual(futureManifest.resolution(for: .location).durationS, 1)
        XCTAssertEqual(hoursManifest.location.state, .finalizedArtifact)
        XCTAssertEqual(hoursManifest.location.artifactFilename, "location.jsonl")
    }

    func testFinalizeActiveSegmentPrefersPersistedAudioDurationForSegmentName() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-3_600)
        let directory = try self.writeActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio], startedAt: startedAt)
        var manifest = try harness.store.readManifest(in: directory)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: 42,
            startedAt: startedAt,
            endedAt: self.clock.now(),
            durationS: 42,
            mode: .meeting
        )
        try harness.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: self.clock.now())
        try Data(repeating: 0, count: 42).write(to: harness.store.audioURL(in: directory), options: .atomic)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let found = try XCTUnwrap(harness.store.findDirectory(segmentID: segmentID))
        let finalized = try harness.store.readManifest(in: found.url)
        XCTAssertEqual(finalized.durationS, 42)
        XCTAssertEqual(finalized.segment, ChunkSidecar.segmentString(for: startedAt, durationSeconds: 42))
        XCTAssertEqual(finalized.audio.durationS, 42)
    }

    func testResumeReconcilesUnresolvedScreencastWithScreenFileToPendingBundle() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .screen)

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.screencast.state, .finalizedArtifact)
        XCTAssertEqual(manifest.screencast.artifactFilename, "screen.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenURL(in: pendingDirectory).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testResumeReconcilesScreencastPartOnlyToFinalizeFailureWithoutUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)

        await harness.uploader.resumeFromDisk()

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testFreshLiveScreencastPartIsNotFailed() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.resumeFromDisk()

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.screencast.state, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenPartURL(in: activeDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testStaleScreencastPartFails() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-11)
        )

        await harness.uploader.resumeFromDisk()

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
                .path
        ))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testFinalizeActiveSegmentDefersFreshLiveScreencastPart() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.screencast.state, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenPartURL(in: activeDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
    }

    func testFinalizeActiveSegmentFailsStaleScreencastPart() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-11)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: failedDirectory)
        XCTAssertEqual(manifest.screencast.state, .failedToFinalize)
        XCTAssertEqual(manifest.screencast.reason, "screencast_partial_artifact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.active, segmentID: segmentID).path))
    }

    func testFreshLiveLocationPartIsNotFailed() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.liveLocation.writeActiveLocationPart(segmentID: segmentID, store: harness.store)
        try self.liveLocation.writeLocationLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.resumeFromDisk()

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.location.state, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: activeDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: activeDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testStaleLiveLocationPartRecoversToCanonicalArtifact() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        try self.liveLocation.writeActiveLocationPart(segmentID: segmentID, store: harness.store)
        try self.liveLocation.writeLocationLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-121)
        )

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.artifactFilename, "location.jsonl")
        XCTAssertEqual(manifest.location.fixCount, 1)
        let canonicalData = try harness.store.readData(at: harness.store.locationURL(in: pendingDirectory))
        let header = try MobileSegmentLocationWriter.loadSnapshotHeader(from: canonicalData)
        XCTAssertEqual(header.fixCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: pendingDirectory).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testFinalizeActiveSegmentDefersFreshLiveLocationPart() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.liveLocation.writeActiveLocationPart(segmentID: segmentID, store: harness.store)
        try self.liveLocation.writeLocationLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.location.state, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: activeDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
    }

    func testFinalizeActiveSegmentRecoversStaleLiveLocationPart() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        try self.liveLocation.writeActiveLocationPart(segmentID: segmentID, store: harness.store)
        try self.liveLocation.writeLocationLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-121)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.fixCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: pendingDirectory).path))
    }

    func testAudioUploadsWhenUnrecoverableLocationIsRemoved() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        let directory = try self.liveLocation.writeActiveLocation(segmentID: segmentID, store: harness.store, sources: [.audio, .location])
        try Data("audio-\(segmentID.uuidString)".utf8).write(to: harness.store.audioURL(in: directory), options: .atomic)
        MobileSegmentReconcileURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("audio upload after location removal") {
            MobileSegmentReconcileURLProtocol.callCount == 1
        }

        let body = String(decoding: try XCTUnwrap(MobileSegmentReconcileURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="audio.m4a""#))
        XCTAssertFalse(body.contains(#"filename="location.jsonl""#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
    }

    func testTornTrailingLocationLineRecoversCompleteRecords() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        try self.liveLocation.writeActiveLocationPart(segmentID: segmentID, store: harness.store, appendTornFix: true)
        try self.liveLocation.writeLocationLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-121)
        )

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.fixCount, 1)
        let canonicalData = try harness.store.readData(at: harness.store.locationURL(in: pendingDirectory))
        let header = try MobileSegmentLocationWriter.loadSnapshotHeader(from: canonicalData)
        XCTAssertEqual(header.fixCount, 1)
    }

    func testLocationLiveStateLastWinsTierAccuracy() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let directory = try self.liveLocation.writeActiveLocation(segmentID: segmentID, store: harness.store, startedAt: startedAt)
        try self.liveLocation.writeLocationPart(
            segmentID: segmentID,
            store: harness.store,
            directory: directory,
            startedAt: startedAt,
            tier: .light,
            accuracy: .reduced,
            fixes: [self.liveLocation.locationFix(at: startedAt.addingTimeInterval(60))]
        )
        try harness.store.appendData(
            try MobileSegmentLocationWriter.liveStateLine(
                segmentID: segmentID,
                segmentStart: startedAt,
                tier: .full,
                accuracy: .full,
                gap: false,
                recordedAt: startedAt.addingTimeInterval(90)
            ),
            to: harness.store.locationPartURL(in: directory)
        )
        try self.liveLocation.writeLocationLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-121)
        )

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let canonical = String(decoding: try harness.store.readData(at: harness.store.locationURL(in: pendingDirectory)), as: UTF8.self)
        let header = try XCTUnwrap(canonical.split(separator: "\n").first)
        XCTAssertTrue(header.contains(#""tier":"full""#))
        XCTAssertTrue(header.contains(#""accuracy":"full""#))
    }

    func testTwoActiveLocationDirsDeferFreshAndRecoverStaleIndependently() async throws {
        let harness = self.makeHarness(connected: false)
        let freshSegmentID = UUID()
        let staleSegmentID = UUID()
        try self.liveLocation.writeActiveLocationPart(segmentID: freshSegmentID, store: harness.store)
        try self.liveLocation.writeLocationLiveness(segmentID: freshSegmentID, store: harness.store, lastSeenAt: self.clock.now())
        try self.liveLocation.writeActiveLocationPart(segmentID: staleSegmentID, store: harness.store)
        try self.liveLocation.writeLocationLiveness(
            segmentID: staleSegmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-121)
        )

        await harness.uploader.resumeFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.active, segmentID: freshSegmentID).path))
        let freshManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.active, segmentID: freshSegmentID))
        XCTAssertEqual(freshManifest.location.state, .unresolved)
        let stalePending = harness.store.segmentDirectoryURL(.pending, segmentID: staleSegmentID)
        let staleManifest = try harness.store.readManifest(in: stalePending)
        XCTAssertEqual(staleManifest.location.state, .finalizedArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: stalePending).path))
    }

    func testLocationDrainPileRemovesNoLiveLocationAndUnblocksAudio() async throws {
        let harness = self.makeHarness(connected: true)
        let unresolvedLocationID = UUID()
        let failedLocationID = UUID()
        let mixedID = UUID()
        _ = try self.liveLocation.writeActiveLocation(segmentID: unresolvedLocationID, store: harness.store)
        let failedDirectory = try self.liveLocation.writeActiveLocation(segmentID: failedLocationID, store: harness.store)
        var failedManifest = try harness.store.readManifest(in: failedDirectory)
        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .failedToFinalize,
                reason: "unclean relaunch unresolved source",
                stage: "reconcile",
                lastAttemptAt: self.clock.now().addingTimeInterval(-60)
            ),
            source: .location,
            manifest: &failedManifest,
            in: failedDirectory,
            now: self.clock.now().addingTimeInterval(-60)
        )
        let mixedDirectory = try self.liveLocation.writeActiveLocation(segmentID: mixedID, store: harness.store, sources: [.audio, .location])
        try Data("audio-\(mixedID.uuidString)".utf8).write(to: harness.store.audioURL(in: mixedDirectory), options: .atomic)
        MobileSegmentReconcileURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("drain pile audio upload") {
            MobileSegmentReconcileURLProtocol.callCount == 1
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(unresolvedLocationID.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(failedLocationID.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: unresolvedLocationID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: failedLocationID).path))
        let body = String(decoding: try XCTUnwrap(MobileSegmentReconcileURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="audio.m4a""#))
        XCTAssertFalse(body.contains(#"filename="location.jsonl""#))
    }

    func testDeclaredScreencastDoesNotUploadUntilTerminal() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.resumeFromDisk()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        XCTAssertEqual(try harness.store.readManifest(in: activeDirectory).screencast.state, .unresolved)
    }

    func testResumeDefersValidLeasedNextScreencastSegment() async throws {
        let harness = self.makeHarness(connected: true)
        let fromSegmentID = UUID()
        let nextSegmentID = UUID()
        try self.writeActiveScreencast(segmentID: nextSegmentID, store: harness.store, artifact: .none)
        try self.writeContinuationLease(
            fromSegmentID: fromSegmentID,
            nextSegmentID: nextSegmentID,
            store: harness.store,
            expiresAt: self.clock.now().addingTimeInterval(30)
        )

        await harness.uploader.resumeFromDisk()

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: nextSegmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.screencast.state, .unresolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: nextSegmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: nextSegmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testResumeIgnoresUndeclaredStrayScreenFileAndReportsDiagnostic() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: self.clock.now().addingTimeInterval(-60),
            openedWithSources: [],
            activeSourceSetVersion: 1
        )
        let directory = try harness.store.createActive(manifest: manifest)
        try Data("stray-screen".utf8).write(to: harness.store.screenURL(in: directory), options: .atomic)
        manifest = try harness.store.readManifest(in: directory)
        XCTAssertEqual(manifest.screencast.state, .notDeclared)

        await harness.uploader.resumeFromDisk()

        XCTAssertEqual(harness.uploader.lastError, "ignored undeclared screencast artifact segment=\(segmentID.uuidString) source=screencast")
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
                .path
        ))
    }
}

private extension MobileSegmentReconcileTests {
    enum ScreencastArtifact {
        case screen
        case part
        case none
    }

    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    var liveLocation: MobileSegmentLiveLocationTestSupport {
        MobileSegmentLiveLocationTestSupport(clock: self.clock)
    }

    func makeHarness(connected: Bool = true) -> Harness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentReconcileURLProtocol.self]
        let transport = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("transport", isDirectory: true),
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { connected },
            localPortProvider: { connected ? 7071 : nil },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            uploader: MobileSegmentUploader(transport: transport, store: store, clock: self.clock),
            store: store
        )
    }

    func writeActiveSegment(
        segmentID: UUID,
        store: MobileSegmentStore,
        sources: Set<MobileSegmentSource>,
        startedAt: Date
    ) throws -> URL {
        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: 1
        )
        return try store.createActive(manifest: manifest)
    }

    func writeReadableAudio(at url: URL, seconds: TimeInterval, sampleRate: Double = 16_000) throws {
        try MobileSegmentTestFixtures.writeReadableAudio(at: url, seconds: seconds, sampleRate: sampleRate)
    }

    func writeActiveAudio(segmentID: UUID, store: MobileSegmentStore, state: MobileSegmentResolutionState, includeFile: Bool) throws {
        let startedAt = self.clock.now().addingTimeInterval(-300)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        let directory = try store.createActive(manifest: manifest)
        if includeFile {
            try Data("audio-\(segmentID.uuidString)".utf8).write(to: store.audioURL(in: directory), options: .atomic)
        }
        switch state {
        case .finalizedArtifact:
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "audio.m4a",
                bytes: includeFile ? store.fileSize(at: store.audioURL(in: directory)) : 12,
                startedAt: startedAt,
                endedAt: self.clock.now(),
                durationS: 300,
                mode: .meeting
            )
            try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: self.clock.now())
        case .noArtifact:
            let resolution = MobileSegmentSourceResolution(
                state: .noArtifact,
                startedAt: startedAt,
                endedAt: self.clock.now(),
                durationS: 300,
                reason: "test_no_artifact",
                mode: .meeting
            )
            try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: self.clock.now())
        case .unresolved:
            break
        case .notDeclared, .failedToFinalize, .removed:
            XCTFail("Unsupported reconcile fixture state")
        }
    }

    func writeActiveScreencast(segmentID: UUID, store: MobileSegmentStore, artifact: ScreencastArtifact) throws {
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let directory = try store.createActive(manifest: manifest)
        switch artifact {
        case .screen:
            try Data("screen-\(segmentID.uuidString)".utf8).write(to: store.screenURL(in: directory), options: .atomic)
        case .part:
            try Data("partial-\(segmentID.uuidString)".utf8).write(to: store.screenPartURL(in: directory), options: .atomic)
        case .none:
            break
        }
    }

    func writeScreencastLiveness(segmentID: UUID, store: MobileSegmentStore, lastSeenAt: Date) throws {
        let directory = store.segmentDirectoryURL(.active, segmentID: segmentID)
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: UUID(),
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: lastSeenAt,
            acceptedFrameCount: 1,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            liveness,
            to: MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: directory)
        )
    }

    func writeContinuationLease(
        fromSegmentID: UUID,
        nextSegmentID: UUID,
        store: MobileSegmentStore,
        expiresAt: Date
    ) throws {
        let notBefore = self.clock.now().addingTimeInterval(-1)
        let lease = MobileSegmentScreencastContinuationLease(
            leaseID: UUID(),
            revision: 2,
            fromSegmentID: fromSegmentID,
            segmentID: nextSegmentID,
            sourceSetVersion: 2,
            sourceSet: [.audio, .location, .screencast],
            notBefore: notBefore,
            startsAt: notBefore,
            rolloverAfter: notBefore.addingTimeInterval(300),
            expiresAt: expiresAt,
            issuedAt: self.clock.now(),
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: nextSegmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: nextSegmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: nextSegmentID)
        )
        try MobileSegmentScreencastJSONStore.write(
            lease,
            to: MobileSegmentScreencastPaths.url(
                root: store.rootURL.deletingLastPathComponent(),
                relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: fromSegmentID)
            )
        )
    }

    func waitFor(_ label: String, timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

}

private final class MobileSegmentReconcileURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var callCount: Int {
        self.callCountBox.withLock { $0 }
    }

    static var capturedBodies: [Data] {
        self.bodiesBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.callCountBox.withLock { $0 = 0 }
        self.bodiesBox.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentReconcileURLProtocol handler not set")
            return
        }
        do {
            let (response, data) = try handler(self.request)
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
