// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class DayHomeBacklogTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        self.temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayHomeBacklogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.temporaryDirectory)
        self.temporaryDirectory = nil
        super.tearDown()
    }

    func testCaptureTotalsSumCaptureHoldersAndExcludeShare() async throws {
        TransferURLProtocol.reset()
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 404), Data("mobile failure".utf8))
        }
        defer { TransferURLProtocol.reset() }

        let harness = makeTransferCutoverHarness(
            rootURL: self.temporaryDirectory.appendingPathComponent("transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(
                .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
            ),
            maxConcurrent: 1
        )
        let mobileUploader = MobileSegmentUploader(
            transferEngine: harness.engine,
            store: MobileSegmentStore(rootURL: self.temporaryDirectory.appendingPathComponent("mobile", isDirectory: true)),
            clock: MockObserverClock()
        )
        let mobileHolder = MobileSegmentTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            uploader: mobileUploader
        )
        let shareHolder = ShareTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            store: ShareImportStore(
                cacheRootURL: self.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
            )
        )
        shareHolder.store.pendingCount = 2
        shareHolder.store.failedCount = 1

        try await harness.engine.start()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        _ = try await harness.engine.enqueue(
            manifest: Self.mobileManifest(itemID: UUID(), startedAt: startedAt),
            payloads: ["audio": Data("failed-mobile".utf8)]
        )
        try await transferTestWaitFor("mobile attention") {
            await MainActor.run { mobileHolder.failedCount == 1 }
        }

        await harness.engine.pause()
        _ = try await harness.engine.enqueue(
            manifest: Self.mobileManifest(itemID: UUID(), startedAt: startedAt.addingTimeInterval(60)),
            payloads: ["audio": Data("queued-mobile".utf8)]
        )
        try await transferTestWaitFor("mobile queued") {
            await MainActor.run { mobileHolder.pendingCount == 1 }
        }

        let captureTotals = captureUploadTotals(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch
        )
        XCTAssertEqual(captureTotals.pending, 1)
        XCTAssertEqual(captureTotals.failed, 1)

        let allTotals = uploadTotals(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: shareHolder
        )
        let captureTotal = captureTotals.pending + captureTotals.failed
        let allTotal = allTotals.pending + allTotals.failed
        let shareTotal = shareHolder.pendingCount + shareHolder.failedCount
        XCTAssertGreaterThan(allTotal, captureTotal)
        XCTAssertEqual(allTotal - captureTotal, shareTotal)
    }

    func testDayHomeBacklogReadsOnlyCaptureTotals() throws {
        let text = try String(
            contentsOf: StringLiteralGrepSupport.worktreeRoot()
                .appendingPathComponent("Sources/Home/DayHomeView.swift"),
            encoding: .utf8
        )
        let body = try Self.slice(
            in: text,
            from: "var backlogCount: WatchAwareBacklog {",
            to: "\n    var statusPillState: HomeStatusPillState"
        )

        XCTAssertTrue(body.contains("captureUploadTotals("))
        XCTAssertTrue(body.contains("mobileSegment: self.mobileSegmentTransferHolder"))
        XCTAssertTrue(body.contains("omi: self.omiUploaderHolder"))
        XCTAssertTrue(body.contains("watch: self.watchUploaderHolder"))
        XCTAssertTrue(body.contains("return .known(totals.pending + totals.failed)"))
        XCTAssertFalse(body.contains("shareTransferHolder"))
        XCTAssertFalse(body.contains("watchAwareBacklog("))
        XCTAssertFalse(body.contains("watchPipelineAssembly"))
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }

    private static func mobileManifest(itemID: UUID, startedAt: Date) -> TransferManifest {
        ObserverAudioTransferEnqueuer.makeManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.mobileSegment,
            platform: "ios",
            createdAt: startedAt,
            segment: "090000_60",
            day: "20260628",
            startedAt: startedAt,
            durationS: 60,
            sources: [MobileSegmentSource.audio.rawValue],
            chunkIndex: nil,
            sessionID: nil,
            modeRawValue: ObserverMode.meeting.rawValue,
            segmentID: UUID(),
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
    }
}
