// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class LocationUploaderTests: XCTestCase {
    private var tempDirectory: URL!
    private let fixedTimeZone = TimeZone(identifier: "America/Chicago")!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocationUploaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        LocationUploaderURLProtocol.handler = nil
        LocationUploaderURLProtocol.callCount = 0
        LocationUploaderURLProtocol.capturedBodies = []
        LocationUploaderURLProtocol.cancelledCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        LocationUploaderURLProtocol.handler = nil
        LocationUploaderURLProtocol.callCount = 0
        LocationUploaderURLProtocol.capturedBodies = []
        LocationUploaderURLProtocol.cancelledCount = 0
        super.tearDown()
    }

    func testBackgroundSessionIdentifierInvariant() {
        XCTAssertEqual(LocationUploader.backgroundSessionIdentifier, "app.solstone.swift.location-upload")
    }

    @MainActor
    func testDefaultCacheRootInvariantAndZeroArgConstruction() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocationUploaderURLProtocol.self]
        _ = LocationUploader(
            sessionConfiguration: configuration,
            ensureRegistered: { "test-location-key-abc" },
            localPortProvider: { 7071 },
            startPathMonitor: false,
            timeZone: self.fixedTimeZone
        )
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Location", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try? FileManager.default.removeItem(at: root)

        _ = LocationUploader()
    }

    @MainActor
    func testSerializationShapeIncludesExplicitNullsAndVisitLines() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader()

        await uploader.enqueue(self.makeBatch())

        let body = try await self.waitForCapturedBody()
        let jsonl = try self.extractFilePart(named: "location.jsonl", from: body)
        let jsonlString = String(decoding: jsonl, as: UTF8.self)
        XCTAssertTrue(jsonlString.hasSuffix("\n"))
        let lines = jsonlString.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last, "")

        let objects = try lines.dropLast().map { line -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }

        let header = objects[0]
        XCTAssertEqual(Set(header.keys), ["schema", "kind", "source", "platform", "tier", "accuracy", "fix_count", "gap"])
        XCTAssertEqual(header["schema"] as? String, "solstone.location.segment/1")
        XCTAssertEqual(header["kind"] as? String, "location")
        XCTAssertEqual(header["source"] as? String, "location")
        XCTAssertEqual(header["platform"] as? String, "ios")
        XCTAssertEqual(header["tier"] as? String, "balanced")
        XCTAssertEqual(header["accuracy"] as? String, "full")
        XCTAssertEqual(header["fix_count"] as? Int, 2)
        XCTAssertEqual(header["gap"] as? Bool, true)

        let firstFix = objects[1]
        let fixKeys: Set<String> = ["schema", "t", "lat", "lon", "h_acc", "alt", "v_acc", "speed", "course", "stationary"]
        XCTAssertEqual(Set(firstFix.keys), fixKeys)
        XCTAssertEqual(firstFix["schema"] as? String, "solstone.location.fix/1")
        XCTAssertEqual(firstFix["t"] as? String, "2024-04-20T16:00:00Z")
        XCTAssertEqual(firstFix["lat"] as? Double, 39.7392)
        XCTAssertEqual(firstFix["lon"] as? Double, -104.9903)
        XCTAssertEqual(firstFix["h_acc"] as? Double, 25)
        XCTAssertTrue(firstFix.keys.contains("alt"))
        XCTAssertTrue(firstFix["alt"] is NSNull)
        XCTAssertTrue(firstFix.keys.contains("v_acc"))
        XCTAssertTrue(firstFix["v_acc"] is NSNull)
        XCTAssertTrue(firstFix.keys.contains("speed"))
        XCTAssertTrue(firstFix["speed"] is NSNull)
        XCTAssertTrue(firstFix.keys.contains("course"))
        XCTAssertTrue(firstFix["course"] is NSNull)
        XCTAssertEqual(firstFix["stationary"] as? Bool, false)

        let secondFix = objects[2]
        XCTAssertEqual(Set(secondFix.keys), fixKeys)
        XCTAssertEqual(secondFix["t"] as? String, "2024-04-20T16:01:00Z")
        XCTAssertEqual(secondFix["alt"] as? Double, 1609)
        XCTAssertEqual(secondFix["v_acc"] as? Double, 12)
        XCTAssertEqual(secondFix["speed"] as? Double, 1.5)
        XCTAssertEqual(secondFix["course"] as? Double, 180)
        XCTAssertEqual(secondFix["stationary"] as? Bool, true)

        let visit = objects[3]
        XCTAssertEqual(Set(visit.keys), ["schema", "arrival", "departure", "lat", "lon", "h_acc"])
        XCTAssertEqual(visit["schema"] as? String, "solstone.location.visit/1")
        XCTAssertEqual(visit["arrival"] as? String, "2024-04-20T16:02:00Z")
        XCTAssertTrue(visit.keys.contains("departure"))
        XCTAssertTrue(visit["departure"] is NSNull)
        XCTAssertEqual(visit["lat"] as? Double, 39.7392)
        XCTAssertEqual(visit["lon"] as? Double, -104.9903)
        XCTAssertEqual(visit["h_acc"] as? Double, 25)
    }

    @MainActor
    func testVisitOnlyBatchUploadsWithZeroFixCount() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader()
        let batch = self.makeBatch(fixes: [])

        await uploader.enqueue(batch)

        let body = try await self.waitForCapturedBody()
        let jsonl = String(decoding: try self.extractFilePart(named: "location.jsonl", from: body), as: UTF8.self)
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let visit = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(header["fix_count"] as? Int, 0)
        XCTAssertEqual(visit["schema"] as? String, "solstone.location.visit/1")
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 1)
    }

    @MainActor
    func testMultipartFieldsAndMidnightStartDay() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader()
        let start = try self.dateInFixedTimeZone(year: 2026, month: 6, day: 2, hour: 23, minute: 58, second: 0)

        await uploader.enqueue(self.makeBatch(segmentStart: start, coveredSeconds: 300))

        let body = try await self.waitForCapturedBody()
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(bodyString.contains(#"name="meta""#))
        XCTAssertFalse(bodyString.contains(#""stream""#))
        XCTAssertEqual(try self.extractField("platform", from: bodyString), "ios")
        XCTAssertEqual(try self.extractField("day", from: bodyString), "20260602")
        XCTAssertEqual(try self.extractField("segment", from: bodyString), "235800_300")
        XCTAssertTrue(bodyString.contains(#"name="files[]"; filename="location.jsonl""#))
    }

    @MainActor
    func testJSONLPartBytesAreStableAcrossRetry() async throws {
        LocationUploaderURLProtocol.handler = { request in
            let statusCode = LocationUploaderURLProtocol.callCount == 0 ? 500 : 200
            return (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data(statusCode == 500 ? "server error".utf8 : "ok".utf8)
            )
        }
        let uploader = self.makeUploader(retryDelays: [0], maxAttempts: 2)

        await uploader.enqueue(self.makeBatch())

        try await self.waitFor("retry success") {
            LocationUploaderURLProtocol.callCount == 2 && uploader.pendingCount == 0
        }
        let bodies = LocationUploaderURLProtocol.capturedBodies
        XCTAssertEqual(bodies.count, 2)
        let first = try self.extractFilePart(named: "location.jsonl", from: bodies[0])
        let second = try self.extractFilePart(named: "location.jsonl", from: bodies[1])
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testDuplicateResponseIsSuccessAndCleansPending() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"duplicate","existing_segment":"235800_300"}"#.utf8)
            )
        }
        let uploader = self.makeUploader()

        await uploader.enqueue(self.makeBatch())

        try await self.waitFor("duplicate success") {
            uploader.pendingCount == 0 && uploader.failedCount == 0 && uploader.lastUploadAt != nil
        }
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 1)
    }

    @MainActor
    func testRepeatedFailuresMoveSegmentToFailedDirectory() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("server error".utf8)
            )
        }
        let uploader = self.makeUploader(retryDelays: [0, 0], maxAttempts: 3)

        await uploader.enqueue(self.makeBatch())

        try await self.waitFor("failed move") {
            uploader.failedCount == 1
        }
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 3)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertTrue((uploader.lastError ?? "").contains("HTTP 500"))
        let failedURL = self.tempDirectory
            .appendingPathComponent("failed", isDirectory: true)
            .appendingPathComponent("20240420-094000_300.jsonl", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
    }

    @MainActor
    func testJournalUnconfiguredLeavesPendingSegmentWithoutAttemptsOrRetry() async throws {
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let registrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let uploader = self.makeUploader(
            ensureRegistered: {
                registrationCalls.withLock { $0 += 1 }
                throw LocationUploaderError.registrationUnavailable
            },
            isJournalConfigured: { false },
            localPortProvider: { 7071 },
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )
        uploader.lastError = "stale"

        await uploader.enqueue(self.makeBatch())
        await uploader.resumeFromDisk()
        await uploader.resumeFromDisk()

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertEqual(try self.directoryEntries(status: "failed"), [])
        XCTAssertNil(uploader.lastError)
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 0)
        XCTAssertEqual(registrationCalls.withLock { $0 }, 0)
        XCTAssertEqual(sleepCalls.withLock { $0 }, 0)
    }

    @MainActor
    func testNilPortHoldsThenFlushesWhenPortAppears() async throws {
        let localPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let sleepCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader(
            isJournalConfigured: { true },
            localPortProvider: { localPort.withLock { $0 } },
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )
        uploader.lastError = "stale"

        await uploader.enqueue(self.makeBatch())

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastError)
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 0)
        XCTAssertEqual(sleepCalls.withLock { $0 }, 0)

        localPort.withLock { $0 = 7071 }
        await uploader.resumeFromDisk()

        try await self.waitFor("nil-port location flush") {
            uploader.pendingCount == 0 && LocationUploaderURLProtocol.callCount == 1
        }
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastError)
    }

    @MainActor
    func testResumeFromDiskUploadsOnceAndSecondResumeDoesNothing() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let pendingURL = self.tempDirectory
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("20260602-235800_300.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data(#"{"schema":"manual"}"#.utf8) + Data([0x0A])).write(to: pendingURL)
        let uploader = self.makeUploader()

        await uploader.resumeFromDisk()

        try await self.waitFor("resume upload") {
            LocationUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0 && uploader.lastUploadAt != nil
        }
        await uploader.resumeFromDisk()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 1)
    }

    @MainActor
    func testResumeFromDiskIgnoresStrayUploadRequestBody() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let pendingDirectory = self.tempDirectory.appendingPathComponent("pending", isDirectory: true)
        let fileID = "20260602-235800_300"
        let pendingURL = pendingDirectory.appendingPathComponent("\(fileID).jsonl", isDirectory: false)
        let strayUploadURL = pendingDirectory.appendingPathComponent("\(fileID).upload", isDirectory: false)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try (Data(#"{"schema":"manual"}"#.utf8) + Data([0x0A])).write(to: pendingURL)
        try Data("stale request body".utf8).write(to: strayUploadURL)
        let uploader = self.makeUploader()

        await uploader.resumeFromDisk()

        try await self.waitFor("resume upload ignoring request body") {
            LocationUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0
        }
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastError)
        let failedUploadURL = self.tempDirectory
            .appendingPathComponent("failed", isDirectory: true)
            .appendingPathComponent("\(fileID).upload", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedUploadURL.path))
    }

    @MainActor
    func testReachabilitySatisfiedTriggersDrain() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let pendingURL = self.tempDirectory
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("20260602-235800_300.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data(#"{"schema":"manual"}"#.utf8) + Data([0x0A])).write(to: pendingURL)
        let uploader = self.makeUploader()

        uploader.handlePathStatus(.satisfied)

        try await self.waitFor("reachability drain") {
            LocationUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0
        }
    }

    @MainActor
    func testEnqueueWriteFailureSetsLastErrorAndDoesNotUpload() async throws {
        let fileRoot = self.tempDirectory.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("root file".utf8).write(to: fileRoot)
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let uploader = self.makeUploader(cacheRootURL: fileRoot)

        await uploader.enqueue(self.makeBatch())

        XCTAssertNotNil(uploader.lastError)
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 0)
        XCTAssertEqual(uploader.pendingCount, 0)
    }

    @MainActor
    func testRetryFailedMovesFrozenBytesBackToPendingAndUploads() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let original = Data(#"{"schema":"manual","value":1}"#.utf8) + Data([0x0A])
        let failedURL = self.tempDirectory
            .appendingPathComponent("failed", isDirectory: true)
            .appendingPathComponent("20260602-235800_300.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: failedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: failedURL)
        let uploader = self.makeUploader()
        XCTAssertEqual(uploader.failedCount, 1)

        await uploader.retryFailed()

        try await self.waitFor("retry failed upload") {
            LocationUploaderURLProtocol.callCount == 1 && uploader.pendingCount == 0 && uploader.failedCount == 0
        }
        let uploaded = try self.extractFilePart(named: "location.jsonl", from: try XCTUnwrap(LocationUploaderURLProtocol.capturedBodies.first))
        XCTAssertEqual(uploaded, original)
    }

    @MainActor
    func testDropItemRemovesLocalArtifactsAndDoesNotRegisterOrUpload() throws {
        let fileID = "20260602-235800_300"
        let pending = try self.writeLocationFile(status: "pending", filename: "\(fileID).jsonl")
        let pendingUpload = try self.writeLocationFile(status: "pending", filename: "\(fileID).upload", data: Data("body".utf8))
        let failed = try self.writeLocationFile(status: "failed", filename: "\(fileID).jsonl")
        let uploader = self.makeUploader(ensureRegistered: {
            XCTFail("dropItem should not register")
            throw LocationUploaderError.registrationUnavailable
        })

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(uploader.failedCount, 1)
        uploader.dropItem(fileID: fileID)

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingUpload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 0)
    }

    @MainActor
    func testDropItemCancelsInFlightUploadAndLeavesDeleteGuardUntouched() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        let uploadCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        LocationUploaderURLProtocol.handler = { request in
            let call = uploadCalls.withLock { value in
                value += 1
                return value
            }
            if call == 1 {
                uploadStarted.signal()
                _ = uploadRelease.wait(timeout: .now() + 2)
                return (Self.response(for: request, statusCode: 500), Data("late failure".utf8))
            }
            return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
        }
        let uploader = self.makeUploader(retryDelays: [0])
        let firstFileID = "20240420-094000_300"

        await uploader.enqueue(self.makeBatch())
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        uploader.dropItem(fileID: firstFileID)
        uploadRelease.signal()
        try await self.waitFor("drop cancellation") {
            LocationUploaderURLProtocol.cancelledCount >= 1
        }
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(uploader.lastError)
        await uploader.enqueue(self.makeBatch(segmentStart: Date(timeIntervalSince1970: 1_713_625_200)))
        try await self.waitFor("post-drop enqueue") {
            LocationUploaderURLProtocol.callCount >= 2 && uploader.pendingCount == 0
        }
    }

    @MainActor
    func testDeleteLocationSourceConfirmedReceiptClearsLocalStateAndUsesLocationEndpoint() async throws {
        try self.writeLocationFile(status: "pending", filename: "20260602-235800_300.jsonl")
        try self.writeLocationFile(status: "pending", filename: "20260602-235800_300.upload", data: Data("body".utf8))
        try self.writeLocationFile(status: "failed", filename: "20260601-120000_60.jsonl")
        try self.writeLocationFile(status: "failed", filename: "20260601-120000_60.upload", data: Data("body".utf8))
        LocationUploaderURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/app/observer/source/location")
            return (Self.response(for: request, statusCode: 200), Self.deleteReceipt(days: 12))
        }
        let uploader = self.makeUploader()

        let result = await uploader.deleteLocationSource()

        guard case .confirmed(let receipt, let localNotRemoved) = result else {
            XCTFail("Expected confirmed result")
            return
        }
        XCTAssertEqual(receipt.removed.days, 12)
        XCTAssertTrue(localNotRemoved.isEmpty)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertTrue(try self.directoryEntries(status: "pending").isEmpty)
        XCTAssertTrue(try self.directoryEntries(status: "failed").isEmpty)
        uploader.finishDelete()
    }

    @MainActor
    func testDeleteLocationSourceNotRemovedIssuesArePartial() async throws {
        LocationUploaderURLProtocol.handler = { request in
            (
                Self.response(for: request, statusCode: 200),
                Self.deleteReceipt(
                    days: 3,
                    notRemoved: #"{"what":"history","plain_reason":"history rows stayed"}"#
                )
            )
        }
        let uploader = self.makeUploader()

        let result = await uploader.deleteLocationSource()

        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.notRemovedIssues.map(\.plainReason), ["history rows stayed"])
        uploader.finishDelete()
    }

    @MainActor
    func testDeleteLocationSourceNotConfirmedResetsGuardAndPreservesPending() async throws {
        let pendingURL = try self.writeLocationFile(status: "pending", filename: "20260602-235800_300.jsonl")
        let registrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        LocationUploaderURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (Self.response(for: request, statusCode: 200), Data("garbage".utf8))
        }
        let uploader = self.makeUploader(
            ensureRegistered: {
                let call = registrationCalls.withLock { value in
                    value += 1
                    return value
                }
                if call == 1 {
                    return "test-location-key-abc"
                }
                throw LocationUploaderError.registrationUnavailable
            }
        )

        let result = await uploader.deleteLocationSource()

        XCTAssertEqual(result, .notConfirmed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertEqual(uploader.pendingCount, 1)
        await uploader.enqueue(self.makeBatch(segmentStart: Date(timeIntervalSince1970: 1_713_624_600)))
        XCTAssertEqual(uploader.pendingCount, 2)
    }

    @MainActor
    func testDeleteLocationSourceUnreachablePreservesLocalState() async throws {
        let failedURL = try self.writeLocationFile(status: "failed", filename: "20260601-120000_60.jsonl")
        LocationUploaderURLProtocol.handler = { _ in
            throw LocationUploaderTestError.transport
        }
        let uploader = self.makeUploader()

        let result = await uploader.deleteLocationSource()

        guard case .unreachable = result else {
            XCTFail("Expected unreachable result")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertEqual(uploader.failedCount, 1)
    }

    @MainActor
    func testDeleteLocationSourceNonSuccessStatusIsUnreachable() async throws {
        let failedURL = try self.writeLocationFile(status: "failed", filename: "20260601-120000_60.jsonl")
        LocationUploaderURLProtocol.handler = { request in
            (Self.response(for: request, statusCode: 500), Data("failed".utf8))
        }
        let uploader = self.makeUploader()

        let result = await uploader.deleteLocationSource()

        guard case .unreachable(let reason) = result else {
            XCTFail("Expected unreachable result")
            return
        }
        XCTAssertEqual(reason, "HTTP 500")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertEqual(uploader.failedCount, 1)
    }

    @MainActor
    func testDeleteLocationSourceCancelsInFlightUploadAndDropsLateCompletion() async throws {
        let uploadStarted = DispatchSemaphore(value: 0)
        let uploadRelease = DispatchSemaphore(value: 0)
        LocationUploaderURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Self.response(for: request, statusCode: 200), Self.deleteReceipt(days: 1))
            }

            uploadStarted.signal()
            _ = uploadRelease.wait(timeout: .now() + 2)
            return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
        }
        let uploader = self.makeUploader()

        await uploader.enqueue(self.makeBatch())
        XCTAssertEqual(uploadStarted.wait(timeout: .now() + 2), .success)

        let result = await uploader.deleteLocationSource()
        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertGreaterThanOrEqual(LocationUploaderURLProtocol.cancelledCount, 1)
        uploadRelease.signal()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
        XCTAssertNil(uploader.lastUploadAt)
        uploader.finishDelete()
    }

    @MainActor
    func testDeleteGuardsBlockNewResumeAndRetryWorkUntilFinished() async throws {
        LocationUploaderURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Self.response(for: request, statusCode: 200), Self.deleteReceipt(days: 1))
            }
            return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
        }
        let uploader = self.makeUploader()
        let result = await uploader.deleteLocationSource()
        XCTAssertTrue(result.shouldFlipOff)
        let deleteCallCount = LocationUploaderURLProtocol.callCount

        await uploader.enqueue(self.makeBatch())
        XCTAssertTrue(try self.directoryEntries(status: "pending").isEmpty)
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, deleteCallCount)

        let pendingURL = try self.writeLocationFile(status: "pending", filename: "20260602-235800_300.jsonl")
        await uploader.resumeFromDisk()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, deleteCallCount)

        let failedURL = try self.writeLocationFile(status: "failed", filename: "20260601-120000_60.jsonl")
        await uploader.retryFailed()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, deleteCallCount)

        try FileManager.default.removeItem(at: pendingURL)
        try FileManager.default.removeItem(at: failedURL)
        uploader.finishDelete()

        await uploader.enqueue(self.makeBatch(segmentStart: Date(timeIntervalSince1970: 1_713_625_200)))
        try await self.waitFor("post-delete enqueue") {
            LocationUploaderURLProtocol.callCount > deleteCallCount && uploader.pendingCount == 0
        }
    }

    @MainActor
    func testDeleteLocationSourceClearsOnlyLocationRoot() async throws {
        let locationRoot = self.tempDirectory.appendingPathComponent("location", isDirectory: true)
        let siblingRoot = self.tempDirectory.appendingPathComponent("import-queue", isDirectory: true)
        let siblingFile = siblingRoot
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("sibling.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: siblingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: siblingFile)
        try self.writeLocationFile(root: locationRoot, status: "pending", filename: "20260602-235800_300.jsonl")
        try self.writeLocationFile(root: locationRoot, status: "pending", filename: "20260602-235800_300.upload", data: Data("body".utf8))
        try self.writeLocationFile(root: locationRoot, status: "failed", filename: "20260601-120000_60.jsonl")
        try self.writeLocationFile(root: locationRoot, status: "failed", filename: "20260601-120000_60.upload", data: Data("body".utf8))
        LocationUploaderURLProtocol.handler = { request in
            (Self.response(for: request, statusCode: 200), Self.deleteReceipt(days: 4))
        }
        let uploader = self.makeUploader(cacheRootURL: locationRoot)

        let result = await uploader.deleteLocationSource()

        XCTAssertTrue(result.shouldFlipOff)
        XCTAssertTrue(try self.directoryEntries(root: locationRoot, status: "pending").isEmpty)
        XCTAssertTrue(try self.directoryEntries(root: locationRoot, status: "failed").isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingFile.path))
        uploader.finishDelete()
    }

    @MainActor
    func testDeleteGuardBlocksStopForDeleteFlush() async throws {
        let provider = MockLocationProvider()
        provider.capability = .whenInUse(accuracy: .full)
        LocationUploaderURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (Self.response(for: request, statusCode: 200), Self.deleteReceipt(days: 1))
            }
            XCTFail("Flush should not upload during delete")
            return (Self.response(for: request, statusCode: 200), Data("ok".utf8))
        }
        let uploader = self.makeUploader()
        let manager = LocationManager(
            provider: provider,
            uploader: uploader,
            clock: MockObserverClock(),
            defaults: nil
        )
        await manager.start(tier: .light)
        provider.emitFix(MockLocationProvider.fix())
        try await Task.sleep(for: .milliseconds(20))

        let result = await uploader.deleteLocationSource()
        XCTAssertTrue(result.shouldFlipOff)
        await manager.stopForDelete()

        XCTAssertEqual(manager.sourceState, .off)
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(LocationUploaderURLProtocol.callCount, 1)
        uploader.finishDelete()
    }

    @MainActor private func makeUploader(
        cacheRootURL: URL? = nil,
        retryDelays: [UInt64] = [0],
        maxAttempts: Int = 5,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = { "test-location-key-abc" },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { 7071 },
        sleep: @escaping @Sendable (UInt64) async -> Void = { _ in }
    ) -> LocationUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocationUploaderURLProtocol.self]
        let deleteConfiguration = URLSessionConfiguration.ephemeral
        deleteConfiguration.protocolClasses = [LocationUploaderURLProtocol.self]
        return LocationUploader(
            cacheRootURL: cacheRootURL ?? self.tempDirectory,
            sessionConfiguration: configuration,
            deleteSessionConfiguration: deleteConfiguration,
            ensureRegistered: ensureRegistered,
            isJournalConfigured: isJournalConfigured,
            localPortProvider: localPortProvider,
            retryDelays: retryDelays,
            maxAttempts: maxAttempts,
            sleep: sleep,
            startPathMonitor: false,
            timeZone: self.fixedTimeZone
        )
    }

    private func makeBatch(
        segmentStart: Date = Date(timeIntervalSince1970: 1_713_624_000),
        coveredSeconds: Int = 300,
        fixes: [LocationFix]? = nil,
        visits: [LocationVisit]? = nil
    ) -> LocationSegmentBatch {
        LocationSegmentBatch(
            tier: .balanced,
            accuracy: .full,
            segmentStart: segmentStart,
            coveredSeconds: coveredSeconds,
            fixes: fixes ?? [
                LocationFix(
                    t: Date(timeIntervalSince1970: 1_713_628_800),
                    lat: 39.7392,
                    lon: -104.9903,
                    hAcc: 25,
                    alt: nil,
                    vAcc: nil,
                    speed: nil,
                    course: nil,
                    stationary: false
                ),
                LocationFix(
                    t: Date(timeIntervalSince1970: 1_713_628_860),
                    lat: 39.7393,
                    lon: -104.9904,
                    hAcc: 20,
                    alt: 1609,
                    vAcc: 12,
                    speed: 1.5,
                    course: 180,
                    stationary: true
                ),
            ],
            visits: visits ?? [
                LocationVisit(
                    arrival: Date(timeIntervalSince1970: 1_713_628_920),
                    departure: nil,
                    lat: 39.7392,
                    lon: -104.9903,
                    hAcc: 25
                ),
            ],
            gap: true
        )
    }

    private func dateInFixedTimeZone(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.fixedTimeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = self.fixedTimeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(calendar.date(from: components))
    }

    private func writeLocationFile(
        root: URL? = nil,
        status: String,
        filename: String,
        data: Data = Data(#"{"schema":"manual"}"#.utf8) + Data([0x0A])
    ) throws -> URL {
        let directory = (root ?? self.tempDirectory).appendingPathComponent(status, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url)
        return url
    }

    private func directoryEntries(root: URL? = nil, status: String) throws -> [URL] {
        let directory = (root ?? self.tempDirectory).appendingPathComponent(status, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private static func deleteReceipt(
        days: Int? = nil,
        notConfirmed: String? = nil,
        notRemoved: String? = nil
    ) -> Data {
        let daysJSON = days.map { #","days":\#($0)"# } ?? ""
        let notConfirmedJSON = notConfirmed.map { "[\($0)]" } ?? "[]"
        let notRemovedJSON = notRemoved.map { "[\($0)]" } ?? "[]"
        return Data(
            """
            {"target":{"stream":"location","journal":"test"},"removed":{"originals":0,"segments":0,"in_segment_derived":0,"index_chunks":0,"stream_identity":0,"history_rows":0\(daysJSON)},"not_confirmed":\(notConfirmedJSON),"not_removed":\(notRemovedJSON),"backup_hosted":"not confirmed"}
            """.utf8
        )
    }

    @MainActor private func waitForCapturedBody() async throws -> Data {
        try await self.waitFor("captured body") {
            !LocationUploaderURLProtocol.capturedBodies.isEmpty
        }
        return try XCTUnwrap(LocationUploaderURLProtocol.capturedBodies.first)
    }

    private func extractField(_ name: String, from body: String) throws -> String {
        let marker = "Content-Disposition: form-data; name=\"\(name)\""
        let markerRange = try XCTUnwrap(body.range(of: marker))
        let afterMarker = body[markerRange.upperBound...]
        let separator = try XCTUnwrap(afterMarker.range(of: "\r\n\r\n"))
        let valueStart = separator.upperBound
        let valueEnd = try XCTUnwrap(afterMarker[valueStart...].range(of: "\r\n--")?.lowerBound)
        return String(afterMarker[valueStart..<valueEnd])
    }

    private func extractFilePart(named filename: String, from body: Data) throws -> Data {
        let bodyString = String(decoding: body, as: UTF8.self)
        let marker = "Content-Disposition: form-data; name=\"files[]\"; filename=\"\(filename)\""
        let markerRange = try XCTUnwrap(bodyString.range(of: marker))
        let afterMarker = bodyString[markerRange.upperBound...]
        let separator = try XCTUnwrap(afterMarker.range(of: "\r\n\r\n"))
        let valueStart = separator.upperBound
        let valueEnd = try XCTUnwrap(afterMarker[valueStart...].range(of: "\r\n--")?.lowerBound)
        return Data(afterMarker[valueStart..<valueEnd].utf8)
    }

    @MainActor private func waitFor(_ label: String, timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
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

private enum LocationUploaderTestError: Error {
    case transport
}

private final class LocationUploaderURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private static let cancelledCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }
    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }
    static var capturedBodies: [Data] {
        get { self.bodiesBox.withLock { $0 } }
        set { self.bodiesBox.withLock { $0 = newValue } }
    }
    static var cancelledCount: Int {
        get { self.cancelledCountBox.withLock { $0 } }
        set { self.cancelledCountBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-location-key-abc")
        let body = Self.bodyData(from: self.request)
        Self.bodiesBox.withLock { $0.append(body) }
        guard let handler = Self.handler else {
            XCTFail("LocationUploaderURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            Self.callCountBox.withLock { $0 += 1 }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            Self.callCountBox.withLock { $0 += 1 }
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.cancelledCountBox.withLock { $0 += 1 }
    }

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
