// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentUploaderTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        MobileSegmentUploaderURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentUploaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        MobileSegmentUploaderURLProtocol.reset()
        super.tearDown()
    }

    func testMixedSegmentUploadsOneMultipartWithAudioAndLocationFiles() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio, .location])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("mixed multipart upload") {
            MobileSegmentUploaderURLProtocol.callCount == 1
        }

        let body = try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.first)
        XCTAssertEqual(self.multipartValue(named: "platform", in: body), "ios")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#"name="files"; filename="audio.m4a""#))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#"name="files"; filename="location.jsonl""#))
        XCTAssertEqual((try self.multipartMeta(in: body)["sources"] as? [String])?.sorted(), ["audio", "location"])
    }

    func testMobileSegmentTaskDescriptionIncludesEpochAndCreatedAtThroughTransport() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        let harness = self.makeHarness(
            connected: true,
            activeEpochProvider: { 9 }
        )
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio, .location])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        let descriptions = await harness.transport.sessionTaskDescriptionsForTesting().compactMap { $0 }
        let description = try XCTUnwrap(descriptions.first)
        let json = try self.taskDescriptionJSON(description)
        XCTAssertEqual(json["kind"] as? String, "mobile-segment")
        XCTAssertEqual(json["source_type"] as? String, "observer-audio")
        XCTAssertEqual(json["segment_id"] as? String, segmentID.uuidString)
        XCTAssertEqual(self.uint64Value(json["epoch"]), 9)
        XCTAssertNotNil(json["created_at"] as? NSNumber)

        uploadRelease.signal()
        try await self.waitFor("descriptor upload cleanup") {
            MobileSegmentUploaderURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path)
        }
    }

    func testOldManifestWithoutScreencastDecodesAsNotDeclared() throws {
        let segmentID = UUID()
        let json = """
        {
          "active_source_set_version": 1,
          "audio": { "state": "finalized_artifact", "artifact_filename": "audio.m4a" },
          "created_at": "2026-06-03T12:00:00Z",
          "location": { "state": "not_declared" },
          "opened_with_sources": ["audio"],
          "schema": "app.solstone.mobile-segment/1",
          "segment_id": "\(segmentID.uuidString)",
          "started_at": "2026-06-03T12:00:00Z",
          "updated_at": "2026-06-03T12:01:00Z",
          "upload": "pending"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(MobileSegmentManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.screencast.state, .notDeclared)
    }

    func testFinalizeConsumesRecorderAudioDurationWithoutCeilingClamp() async throws {
        let harness = self.makeHarness(connected: false)
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(600)
        let segmentID = try harness.uploader.openSegment(sources: [.audio], startedAt: startedAt, sourceSetVersion: 1)
        let audioURL = harness.uploader.activeAudioURL(segmentID: segmentID)
        try Data("live-audio".utf8).write(to: audioURL, options: .atomic)
        try harness.uploader.recordAudioFinalized(
            segmentID: segmentID,
            finalized: ObserverRecordedChunk(url: audioURL, duration: 360),
            startedAt: startedAt,
            endedAt: endedAt,
            mode: .meeting,
            minimumDuration: 0.1
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let manifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID))
        XCTAssertEqual(manifest.audio.durationS, 360)
        XCTAssertEqual(manifest.durationS, 360)
        XCTAssertEqual(manifest.segment, ChunkSidecar.segmentString(for: startedAt, durationSeconds: 360))
    }

    func testPublicScreencastOnlyFinalizeUploadsScreenPartAndSourceMetadata() async throws {
        let author = self.makeHarness(connected: false)
        let segmentID = try await self.createPublicFinalizedSegment(uploader: author.uploader, sources: [.screencast])
        let sender = self.makeHarness(connected: true)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await sender.uploader.resumeFromDisk()
        try await self.waitFor("screencast multipart upload") {
            MobileSegmentUploaderURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: sender.store.segmentDirectoryURL(.pending, segmentID: segmentID).path)
        }

        let body = try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.first)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains(#"name="files"; filename="screen.mp4""#))
        XCTAssertTrue(bodyString.contains("Content-Type: video/mp4"))
        XCTAssertFalse(bodyString.contains(#"filename="audio.m4a""#))
        XCTAssertFalse(bodyString.contains(#"filename="location.jsonl""#))
        XCTAssertEqual((try self.multipartMeta(in: body)["sources"] as? [String])?.sorted(), ["screencast"])
    }

    func testPublicMixedFinalizeUploadsAudioLocationAndScreenParts() async throws {
        let author = self.makeHarness(connected: false)
        _ = try await self.createPublicFinalizedSegment(uploader: author.uploader, sources: [.audio, .location, .screencast])
        let sender = self.makeHarness(connected: true)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await sender.uploader.resumeFromDisk()
        try await self.waitFor("mixed screencast multipart upload") {
            MobileSegmentUploaderURLProtocol.callCount == 1
        }

        let body = try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.first)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains(#"name="files"; filename="audio.m4a""#))
        XCTAssertTrue(bodyString.contains(#"name="files"; filename="location.jsonl""#))
        XCTAssertTrue(bodyString.contains(#"name="files"; filename="screen.mp4""#))
        XCTAssertEqual((try self.multipartMeta(in: body)["sources"] as? [String])?.sorted(), ["audio", "location", "screencast"])
    }

    func testSingleSourceSegmentsUploadOnlyTheirOwnArtifact() async throws {
        let harness = self.makeHarness(connected: true)
        let audioSegmentID = UUID()
        let locationSegmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: audioSegmentID, store: harness.store, sources: [.audio])
        _ = try self.createFinalizedActiveSegment(segmentID: locationSegmentID, store: harness.store, sources: [.location])
        _ = try harness.store.move(segmentID: audioSegmentID, from: .active, to: .pending)
        _ = try harness.store.move(segmentID: locationSegmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("single-source multipart uploads") {
            MobileSegmentUploaderURLProtocol.callCount == 2
        }

        let bodies = MobileSegmentUploaderURLProtocol.capturedBodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(bodies.filter { $0.contains(#"filename="audio.m4a""#) && !$0.contains(#"filename="location.jsonl""#) }.count, 1)
        XCTAssertEqual(bodies.filter { !$0.contains(#"filename="audio.m4a""#) && $0.contains(#"filename="location.jsonl""#) }.count, 1)
    }

    func testResumeAndRetryTripMaintenanceCheckpointsForLargeBacklogs() async throws {
        let cooperator = MaintenanceCooperator(chunkSize: 2)
        let harness = self.makeHarness(connected: false, cooperator: cooperator)
        for _ in 0..<5 {
            let segmentID = UUID()
            _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
            _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        }
        for _ in 0..<5 {
            let segmentID = UUID()
            _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.location])
            _ = try harness.store.move(segmentID: segmentID, from: .active, to: .failed)
        }

        await harness.uploader.resumeFromDisk()
        await harness.uploader.retryFailed(respectingCooldown: false)

        XCTAssertGreaterThan(cooperator.checkpointCount, 0)
    }

    func testFailedMixedUploadKeepsArtifactsAndRetryResendsBothParts() async throws {
        let harness = self.makeHarness(connected: true, maxAttempts: 2)
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio, .location])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("try later".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("mixed upload exhaustion") {
            harness.uploader.failedCount == 1 && MobileSegmentUploaderURLProtocol.callCount == 2
        }

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: failedDirectory).path))
        XCTAssertNotNil(harness.store.loadFailure(in: failedDirectory))
        _ = try harness.store.readManifest(in: failedDirectory)

        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await harness.uploader.retryFailed(respectingCooldown: false)
        try await self.waitFor("mixed retry upload") {
            MobileSegmentUploaderURLProtocol.callCount == 3
        }

        let retryBody = String(decoding: try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.last), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(retryBody.contains(#"filename="location.jsonl""#))
    }

    func testFailedScreencastRetryResendsScreenPart() async throws {
        let harness = self.makeHarness(connected: true, maxAttempts: 1)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("try later".utf8)
            )
        }

        let segmentID = try await self.createPublicFinalizedSegment(uploader: harness.uploader, sources: [.screencast])
        try await self.waitFor("screencast failure") {
            harness.uploader.failedCount == 1 && MobileSegmentUploaderURLProtocol.callCount == 1
        }
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenURL(in: failedDirectory).path))

        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await harness.uploader.retryFailed(respectingCooldown: false)
        try await self.waitFor("screencast retry") {
            MobileSegmentUploaderURLProtocol.callCount == 2
        }

        let retryBody = String(decoding: try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.last), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="screen.mp4""#))
        XCTAssertTrue(retryBody.contains("Content-Type: video/mp4"))
    }

    func testRetryFailedRespectingCooldownSkipsRecentThenAllowsAfterWindow() async throws {
        let port = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let harness = self.makeHarness(
            connected: true,
            maxAttempts: 1,
            localPortProvider: { port.withLock { $0 } }
        )
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("try later".utf8)
            )
        }
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("initial mobile failure") {
            harness.uploader.failedCount == 1
        }
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        try harness.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "recent failure",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 1,
                stage: "test",
                lastAttemptAt: self.clock.now()
            ),
            in: failedDirectory
        )

        port.withLock { $0 = nil }
        await harness.uploader.retryFailed(respectingCooldown: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))

        self.clock.advance(by: 31)
        await harness.uploader.retryFailed(respectingCooldown: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
    }

    func testRetryFailedBypassIgnoresRecentCooldown() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        let activeDirectory = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        var manifest = try harness.store.readManifest(in: activeDirectory)
        manifest.upload = .failed
        try harness.store.writeManifest(manifest, in: activeDirectory)
        try harness.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "recent failure",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 1,
                stage: "test",
                lastAttemptAt: self.clock.now()
            ),
            in: activeDirectory
        )
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .failed)

        await harness.uploader.retryFailed(respectingCooldown: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
    }

    func testMobileReconnectRequeueCapsAndMovesToFailed() async throws {
        MobileSegmentUploaderURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        let sleeps = UploaderRecordedSleep()
        let harness = self.makeHarness(
            connected: true,
            maxAttempts: 5,
            retryDelays: [1],
            requeueMaxDeferral: 0,
            sleep: { delay in await sleeps.sleep(delay) }
        )
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        for expected in 1..<5 {
            await sleeps.waitForSleepCount(expected)
            try await self.waitFor("mobile requeue attempt \(expected)") {
                harness.transport.mobileSegmentRequeueAttemptCountForTesting(segmentID: segmentID) == expected
            }
            XCTAssertEqual(harness.uploader.failedCount, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
            sleeps.releaseNext()
        }

        try await self.waitFor("mobile requeue cap failure") {
            harness.uploader.failedCount == 1
        }
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let failure = try XCTUnwrap(harness.store.loadFailure(in: failedDirectory))
        XCTAssertEqual(failure.reason, "requeue_cap_exceeded")
        XCTAssertEqual(failure.transportError, "requeue_cap_exceeded")
        XCTAssertEqual(failure.stage, "reconnect-requeued")
        XCTAssertEqual(harness.transport.retryTaskCountForTesting(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))

        sleeps.releaseAll()
    }

    func testMobileReconnectRequeueHeldNilPortRearmsToCapAndRetryFailedRedrives() async throws {
        let firstRequestShouldCancel = OSAllocatedUnfairLock<Bool>(initialState: true)
        MobileSegmentUploaderURLProtocol.handler = { request in
            if firstRequestShouldCancel.withLock({ value in
                if value {
                    value = false
                    return true
                }
                return false
            }) {
                throw URLError(.cancelled)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let sleeps = UploaderRecordedSleep()
        let harness = self.makeHarness(
            connected: true,
            retryDelays: [0],
            localPortProvider: { localPort.withLock { $0 } },
            requeueMaxDeferral: 0,
            sleep: { delay in await sleeps.sleep(delay) }
        )
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        for expected in 1..<5 {
            try await self.waitFor("mobile held requeue attempt \(expected)") {
                sleeps.recordedDelays().count >= expected
                    && harness.transport.mobileSegmentRequeueAttemptCountForTesting(segmentID: segmentID) == expected
                    && harness.transport.retryTaskCountForTesting() == 1
            }
            if expected == 1 {
                localPort.withLock { $0 = nil }
            }
            sleeps.releaseNext()
        }

        try await self.waitFor("mobile held requeue cap failure") {
            harness.uploader.failedCount == 1
        }
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let failure = try XCTUnwrap(harness.store.loadFailure(in: failedDirectory))
        XCTAssertEqual(failure.reason, "requeue_cap_exceeded")
        XCTAssertEqual(failure.transportError, "requeue_cap_exceeded")
        XCTAssertEqual(failure.stage, "reconnect-requeued")
        XCTAssertEqual(harness.transport.retryTaskCountForTesting(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))

        localPort.withLock { $0 = 7071 }
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await harness.uploader.retryFailed(respectingCooldown: false)
        await harness.uploader.resumeFromDisk()

        try await self.waitFor("mobile failed re-drive") {
            MobileSegmentUploaderURLProtocol.callCount == 2
                && harness.uploader.lastUploadAt != nil
                && harness.uploader.failedCount == 0
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        sleeps.releaseAll()
    }

    func testMobileReconnectRequeueDiagnosticsDistinguishRequeueCounterFromCapAttempt() async throws {
        MobileSegmentUploaderURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let log = DiagnosticLog()
        let sleeps = UploaderRecordedSleep()
        let harness = self.makeHarness(
            connected: true,
            maxAttempts: 5,
            retryDelays: [0],
            localPortProvider: { localPort.withLock { $0 } },
            diagnosticLog: log,
            requeueMaxDeferral: 0,
            sleep: { delay in await sleeps.sleep(delay) }
        )
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        for expected in 1..<5 {
            try await self.waitFor("mobile diagnostic requeue attempt \(expected)") {
                sleeps.recordedDelays().count >= expected
                    && harness.transport.mobileSegmentRequeueAttemptCountForTesting(segmentID: segmentID) == expected
            }
            if expected == 1 {
                localPort.withLock { $0 = nil }
            }
            sleeps.releaseNext()
        }

        try await self.waitFor("mobile diagnostic cap failure") {
            harness.uploader.failedCount == 1
        }

        let reconnectEvents = self.uploadEvents(in: log).filter { $0.message.hasSuffix("upload reconnect-requeued") }
        let requeueEvents = reconnectEvents.filter { $0.severity == .info }
        XCTAssertEqual(requeueEvents.count, 4)
        for expected in 1..<5 {
            let event = try XCTUnwrap(requeueEvents.first { ($0.detail ?? "").contains("requeueAttempt=\(expected)") })
            let detail = event.detail ?? ""
            XCTAssertTrue(detail.contains("segmentID=\(segmentID.uuidString)"))
            XCTAssertFalse(detail.contains("chunkID="))
            XCTAssertFalse(detail.contains("attempt=\(expected)/5"))
        }
        let capEvent = try XCTUnwrap(reconnectEvents.first { $0.severity == .error })
        XCTAssertTrue((capEvent.detail ?? "").contains("attempt=1/5"))
        XCTAssertFalse((capEvent.detail ?? "").contains("requeueAttempt="))
        sleeps.releaseAll()
    }

    func testMobileReconnectRequeueAttemptsAndBackoffEscalate() async throws {
        MobileSegmentUploaderURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        let log = DiagnosticLog()
        let sleeps = UploaderRecordedSleep()
        let harness = self.makeHarness(
            connected: true,
            maxAttempts: 1,
            retryDelays: [2, 4, 8],
            diagnosticLog: log,
            requeueMaxDeferral: 0,
            sleep: { delay in await sleeps.sleep(delay) }
        )
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        for expected in 1...3 {
            await sleeps.waitForSleepCount(expected)
            try await self.waitFor("mobile requeue diagnostic \(expected)") {
                harness.transport.mobileSegmentRequeueAttemptCountForTesting(segmentID: segmentID) == expected
            }
            if expected < 3 {
                sleeps.releaseNext()
            }
        }

        let events = self.uploadEvents(in: log).filter { $0.message.hasSuffix("upload reconnect-requeued") }
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains { ($0.detail ?? "").contains("requeueAttempt=1") })
        XCTAssertTrue(events.contains { ($0.detail ?? "").contains("requeueAttempt=2") })
        XCTAssertTrue(events.contains { ($0.detail ?? "").contains("requeueAttempt=3") })
        XCTAssertEqual(sleeps.recordedDelays(), [2, 4, 8])
        XCTAssertEqual(harness.transport.mobileSegmentAttemptCountForTesting(segmentID: segmentID), 0)

        harness.uploader.dropSegment(segmentID: segmentID)
        sleeps.releaseAll()
    }

    func testMobileReconnectRequeuePortGateReDrivesAfterMaxDeferral() async throws {
        let shouldCancel = OSAllocatedUnfairLock<Bool>(initialState: true)
        MobileSegmentUploaderURLProtocol.handler = { request in
            if shouldCancel.withLock({ value in
                if value {
                    value = false
                    return true
                }
                return false
            }) {
                throw URLError(.cancelled)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let nextPort = OSAllocatedUnfairLock<Int>(initialState: 7070)
        let sleepDurations = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let harness = self.makeHarness(
            connected: true,
            retryDelays: [0],
            localPortProvider: {
                nextPort.withLock { value in
                    value += 1
                    return value
                }
            },
            requeueStabilityPoll: 1,
            requeueStabilityWindow: 2,
            requeueMaxDeferral: 3,
            sleep: { delay in sleepDurations.withLock { durations in durations.append(delay) } }
        )
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        try await self.waitFor("mobile bounded re-drive") {
            MobileSegmentUploaderURLProtocol.callCount == 2 && harness.uploader.lastUploadAt != nil
        }

        XCTAssertEqual(sleepDurations.withLock { $0 }, [0, 1, 1, 1])
        XCTAssertEqual(harness.uploader.failedCount, 0)
    }

    func testMissingFinalizedScreencastFailsWithStatusOnlyScheduleReason() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.screencast])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        try FileManager.default.removeItem(at: harness.store.screenURL(in: pendingDirectory))

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("missing screencast schedule failure") {
            harness.uploader.failedCount == 1
        }

        XCTAssertEqual(
            harness.uploader.lastError,
            "mobile segment schedule failed segment=\(segmentID.uuidString) stage=schedule"
        )
        XCTAssertEqual(MobileSegmentUploaderURLProtocol.callCount, 0)
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let failure = try XCTUnwrap(harness.store.loadFailure(in: failedDirectory))
        XCTAssertEqual(failure.reason, "schedule_failed")
        XCTAssertEqual(failure.stage, "schedule")
        XCTAssertNil(failure.transportError)
        XCTAssertFalse(failure.reason.contains("/"))
        XCTAssertFalse(harness.uploader.lastError?.contains("/") ?? true)
    }

    func testResumeFailsPendingBundleWithUnresolvedDeclaredSourceBeforeUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let activeDirectory = try self.createMixedActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            locationResolution: nil
        )
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedDirectory.path))

        let manifest = try harness.store.readManifest(in: failedDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.state, .failedToFinalize)
        XCTAssertEqual(manifest.location.reason, "missing terminal outcome marker")
        XCTAssertEqual(harness.uploader.failedCount, 1)

        let requestBodyURL = harness.transportRoot
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestBodyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory.path))
    }

    func testRecordLocationFinalizeRemovedRemovesLiveLocationFiles() throws {
        let harness = self.makeHarness()
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(30)
        let segmentID = try harness.uploader.openSegment(
            sources: [.location],
            startedAt: startedAt,
            sourceSetVersion: 1
        )
        let directory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        try harness.uploader.appendLocationLiveState(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        )
        try harness.uploader.writeLocationLiveness(
            segmentID: segmentID,
            sourceSetVersion: 1,
            lastSeenAt: startedAt,
            fixCount: 0,
            visitCount: 0,
            gap: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: directory).path))

        try harness.uploader.recordLocationFinalizeRemoved(
            segmentID: segmentID,
            endedAt: endedAt,
            reason: "location finalize failed"
        )

        let manifest = try harness.store.readManifest(in: directory)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: directory).path))
    }

    func testRecordLocationFinalizeRemovedAllowsAudioSiblingToPending() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        _ = try self.createMixedActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            locationResolution: nil
        )
        let endedAt = self.clock.now().addingTimeInterval(60)

        try harness.uploader.recordLocationFinalizeRemoved(
            segmentID: segmentID,
            endedAt: endedAt,
            reason: "location finalize failed"
        )
        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
    }

    func testFinalizeLiveLocationPartialSalvageRecordsReason() async throws {
        let harness = self.makeHarness()
        let startedAt = self.clock.now().addingTimeInterval(-120)
        let endedAt = self.clock.now()
        let segmentID = try harness.uploader.openSegment(sources: [.location], startedAt: startedAt, sourceSetVersion: 1)
        let directory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let firstFix = LocationFix(
            t: startedAt.addingTimeInterval(30),
            lat: 37.1,
            lon: -122.0,
            hAcc: 12,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
        let secondFix = LocationFix(
            t: startedAt.addingTimeInterval(90),
            lat: 37.2,
            lon: -122.0,
            hAcc: 12,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
        try harness.uploader.appendLocationLiveState(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        )
        try harness.uploader.appendLocationLiveFix(segmentID: segmentID, fix: firstFix)
        try harness.store.appendData(Data("not json\n".utf8), to: harness.store.locationPartURL(in: directory))
        try harness.uploader.appendLocationLiveFix(segmentID: segmentID, fix: secondFix)

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.reason, "location_live_partial_salvage")
        XCTAssertEqual(manifest.location.fixCount, 2)
    }

    func testDeleteLocationLocalStateRedactsFailedLocationAndPreservesAudioUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        _ = try self.createMixedActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            locationResolution: MobileSegmentSourceResolution(
                state: .failedToFinalize,
                reason: "location finalize failed",
                stage: "source-finalize",
                lastAttemptAt: self.clock.now()
            )
        )
        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        try harness.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "source artifact failed to finalize",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 0,
                stage: "source-finalize",
                lastAttemptAt: self.clock.now()
            ),
            in: activeDirectory
        )
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .failed)

        await harness.uploader.deleteLocationLocalState()

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))

        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertEqual(manifest.location.reason, "location_removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))

        let requestBodyURL = harness.transportRoot
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        let requestBody = try String(contentsOf: requestBodyURL, encoding: .utf8)
        XCTAssertTrue(requestBody.contains("filename=\"audio.m4a\""))
        XCTAssertFalse(requestBody.contains("filename=\"location.jsonl\""))
    }

    func testRemovedScreencastIsOmittedFromRebuiltMultipart() async throws {
        let harness = self.makeHarness()
        let segmentID = try await self.createPublicFinalizedSegment(uploader: harness.uploader, sources: [.audio, .screencast])

        await harness.uploader.redactScreencastFacet(segmentID: segmentID)

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.screencast.state, .removed)
        let requestBodyURL = harness.transportRoot
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        let requestBody = try String(contentsOf: requestBodyURL, encoding: .utf8)
        XCTAssertTrue(requestBody.contains("filename=\"audio.m4a\""))
        XCTAssertFalse(requestBody.contains("filename=\"screen.mp4\""))
        let bodyData = try Data(contentsOf: requestBodyURL)
        XCTAssertEqual((try self.multipartMeta(in: bodyData)["sources"] as? [String])?.sorted(), ["audio"])
    }

    func testScreencastStatusAndCopyStringsAreStatusOnly() {
        let strings = [
            "screencast_removed",
            "screencast_partial_artifact",
            "unrecoverable_lost_data",
            "location_no_local_data",
            "audio_no_local_data",
            "schedule_failed",
            "ignored undeclared screencast artifact segment=00000000-0000-0000-0000-000000000000 source=screencast",
            "mobile segment finalize failed segment=00000000-0000-0000-0000-000000000000 stage=segment-finalize",
            "mobile segment resume failed stage=resume",
            "mobile segment retry failed stage=retry",
            "mobile segment location redaction failed segment=00000000-0000-0000-0000-000000000000 source=location",
            "mobile segment screencast redaction failed segment=00000000-0000-0000-0000-000000000000 source=screencast",
            "mobile segment schedule failed segment=00000000-0000-0000-0000-000000000000 stage=schedule",
            "mobile segment delivery cleanup failed segment=00000000-0000-0000-0000-000000000000 stage=cleanup",
            "mobile segment failure cleanup failed segment=00000000-0000-0000-0000-000000000000 stage=failure-cleanup",
            SourceVocabulary.onThisPhoneDropScreencastDescriptor,
            SourceVocabulary.onThisPhoneSourceName(for: .screencast),
        ]
        let bannedFragments = [
            "/",
            "capture",
            "record",
            "recording",
            "watch",
            "monitor",
            "track",
            "collect",
            "keeper",
            "assistant",
            "server",
            "service",
            "transcript",
            "ocr",
        ]

        for string in strings {
            let lowercased = string.lowercased()
            for banned in bannedFragments {
                XCTAssertFalse(lowercased.contains(banned), "\(string) contains \(banned)")
            }
        }
    }
}

private extension MobileSegmentUploaderTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let transport: ObserverUploader
        let store: MobileSegmentStore
        let transportRoot: URL
    }

    func makeHarness(
        connected: Bool = false,
        maxAttempts: Int = 5,
        retryDelays: [UInt64] = [0],
        localPortProvider: (@Sendable @MainActor () -> Int?)? = nil,
        activeEpochProvider: @escaping @Sendable @MainActor () -> UInt64? = { 1 },
        diagnosticLog: DiagnosticLog? = nil,
        requeueStabilityPoll: UInt64 = 1,
        requeueStabilityWindow: UInt64 = 2,
        requeueMaxDeferral: UInt64 = 6,
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in },
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) -> Harness {
        let transportRoot = self.tempDirectory.appendingPathComponent("transport", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentUploaderURLProtocol.self]
        let transport = ObserverUploader(
            cacheRootURL: transportRoot,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { connected },
            localPortProvider: localPortProvider ?? { connected ? 7071 : nil },
            activeEpochProvider: activeEpochProvider,
            diagnosticLog: diagnosticLog,
            retryDelays: retryDelays,
            maxAttempts: maxAttempts,
            requeueStabilityPoll: requeueStabilityPoll,
            requeueStabilityWindow: requeueStabilityWindow,
            requeueMaxDeferral: requeueMaxDeferral,
            sleep: sleep,
            startPathMonitor: false
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            uploader: MobileSegmentUploader(transport: transport, store: store, clock: self.clock, cooperator: cooperator),
            transport: transport,
            store: store,
            transportRoot: transportRoot
        )
    }

    func createMixedActiveSegment(
        segmentID: UUID,
        store: MobileSegmentStore,
        locationResolution: MobileSegmentSourceResolution?
    ) throws -> URL {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio, .location],
            activeSourceSetVersion: 1
        )
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending

        let directory = try store.createActive(manifest: manifest)
        try Data("fake-audio".utf8).write(to: store.audioURL(in: directory), options: .atomic)
        let audioResolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: store.fileSize(at: store.audioURL(in: directory)),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            mode: .meeting
        )
        try store.writeOutcome(audioResolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
        manifest = try store.readManifest(in: directory)

        if let locationResolution {
            try store.writeOutcome(locationResolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
        }

        manifest = try store.readManifest(in: directory)
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending
        try store.writeManifest(manifest, in: directory)
        return directory
    }

    func createFinalizedActiveSegment(
        segmentID: UUID,
        store: MobileSegmentStore,
        sources: Set<MobileSegmentSource>
    ) throws -> URL {
        let startedAt = self.clock.now()
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
        manifest.upload = .pending
        let directory = try store.createActive(manifest: manifest)

        if sources.contains(.audio) {
            let audioURL = store.audioURL(in: directory)
            try Data("fake-audio".utf8).write(to: audioURL, options: .atomic)
            let audioResolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "audio.m4a",
                bytes: store.fileSize(at: audioURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60,
                mode: .meeting
            )
            try store.writeOutcome(audioResolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
            manifest = try store.readManifest(in: directory)
        }

        if sources.contains(.location) {
            let locationURL = store.locationURL(in: directory)
            try Data(#"{"schema":"solstone.location.segment/1","fix_count":1}"#.utf8)
                .write(to: locationURL, options: .atomic)
            let locationResolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "location.jsonl",
                bytes: store.fileSize(at: locationURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60,
                fixCount: 1
            )
            try store.writeOutcome(locationResolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
        }

        if sources.contains(.screencast) {
            manifest = try store.readManifest(in: directory)
            let screenURL = store.screenURL(in: directory)
            try Data("fake-screen".utf8).write(to: screenURL, options: .atomic)
            let screencastResolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "screen.mp4",
                bytes: store.fileSize(at: screenURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            )
            try store.writeOutcome(screencastResolution, source: .screencast, manifest: &manifest, in: directory, now: endedAt)
        }

        manifest = try store.readManifest(in: directory)
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending
        try store.writeManifest(manifest, in: directory)
        return directory
    }

    func createPublicFinalizedSegment(
        uploader: MobileSegmentUploader,
        sources: Set<MobileSegmentSource>
    ) async throws -> UUID {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        let segmentID = try uploader.openSegment(sources: sources, startedAt: startedAt, sourceSetVersion: 1)

        if sources.contains(.audio) {
            let audioURL = uploader.activeAudioURL(segmentID: segmentID)
            try Data("fake-audio".utf8).write(to: audioURL, options: .atomic)
            try uploader.recordAudioFinalized(
                segmentID: segmentID,
                finalized: ObserverRecordedChunk(url: audioURL, duration: 60),
                startedAt: startedAt,
                endedAt: endedAt,
                mode: .meeting,
                minimumDuration: 0.1
            )
        }

        if sources.contains(.location) {
            let fix = LocationFix(
                t: startedAt,
                lat: 0,
                lon: 0,
                hAcc: 1,
                alt: nil,
                vAcc: nil,
                speed: nil,
                course: nil,
                stationary: false
            )
            try uploader.recordLocationFinalized(
                segmentID: segmentID,
                batch: LocationSegmentBatch(
                    tier: .balanced,
                    accuracy: .full,
                    segmentStart: startedAt,
                    coveredSeconds: 60,
                    fixes: [fix],
                    visits: [],
                    gap: false
                ),
                endedAt: endedAt,
                reason: nil
            )
        }

        if sources.contains(.screencast) {
            let screenURL = uploader.activeScreencastURL(segmentID: segmentID)
            try Data("fake-screen".utf8).write(to: screenURL, options: .atomic)
            try uploader.recordScreencastFinalized(
                segmentID: segmentID,
                artifactURL: screenURL,
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            )
        }

        await uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)
        return segmentID
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

    func uploadEvents(in log: DiagnosticLog) -> [DiagnosticEvent] {
        log.events.filter { $0.category == .upload }
    }

    func taskDescriptionJSON(_ description: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(description.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func uint64Value(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        return number.uint64Value
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private final class MobileSegmentUploaderURLProtocol: URLProtocol, @unchecked Sendable {
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
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-observer-key-abc")
        Self.callCountBox.withLock { $0 += 1 }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentUploaderURLProtocol handler not set")
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
