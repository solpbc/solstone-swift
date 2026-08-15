// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchConnectivitySessionTests: XCTestCase {
    private final class HandlerBox: @unchecked Sendable {
        let handler: (any Error) -> Void
        init(_ handler: @escaping (any Error) -> Void) { self.handler = handler }
    }

    private struct StubSendError: Error {}

    func testSendMessageErrorHandlerRunsOffMainActorWithoutTrapping() throws {
        var captured: ((any Error) -> Void)?
        let session = LiveWatchConnectivitySession(messageSend: { _, errorHandler in
            captured = errorHandler
        })

        session.sendMessage(["kind": "ping"])

        let box = HandlerBox(try XCTUnwrap(captured))
        let done = expectation(description: "error handler completes off the main actor")
        DispatchQueue.global(qos: .background).async {
            box.handler(StubSendError())
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testFileTransferCompletionPreservesLegacyMetadataAsMissingOptionalTags() throws {
        let id = UUID()
        let fileURL = URL(fileURLWithPath: "/mock/legacy.watchrelay")

        let completion = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: ["id": id.uuidString],
            fileURL: fileURL,
            error: StubSendError()
        )

        XCTAssertEqual(completion.segmentID, id)
        XCTAssertEqual(completion.segmentIDState, .parseable)
        XCTAssertNil(completion.generation)
        XCTAssertEqual(completion.generationState, .missing)
        XCTAssertNil(completion.attemptID)
        XCTAssertEqual(completion.attemptIDState, .missing)
        XCTAssertNil(completion.attemptStartedAt)
        XCTAssertEqual(completion.attemptStartedAtState, .missing)
        XCTAssertEqual(completion.fileURL, fileURL)
        XCTAssertNotNil(completion.failure)
    }

    func testFileTransferCompletionParsesValidTaggedMetadata() throws {
        let id = UUID()
        let attemptID = UUID()
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let completion = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: [
                "id": id.uuidString,
                "generation": 0,
                "attempt_id": attemptID.uuidString,
                "attempt_started_at": ISO8601DateFormatter().string(from: startedAt),
            ],
            fileURL: URL(fileURLWithPath: "/mock/tagged.watchrelay"),
            error: nil
        )

        XCTAssertEqual(completion.segmentID, id)
        XCTAssertEqual(completion.segmentIDState, .parseable)
        XCTAssertEqual(completion.generation, 0)
        XCTAssertEqual(completion.generationState, .parseable)
        XCTAssertEqual(completion.attemptID, attemptID)
        XCTAssertEqual(completion.attemptIDState, .parseable)
        XCTAssertEqual(completion.attemptStartedAt, startedAt)
        XCTAssertEqual(completion.attemptStartedAtState, .parseable)
    }

    func testFileTransferCompletionClassifiesMalformedOptionalTagsWithoutChangingSegment() throws {
        let id = UUID()
        let completion = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: [
                "id": id.uuidString,
                "generation": "zero",
                "attempt_id": "not-a-uuid",
                "attempt_started_at": "not-a-date",
            ],
            fileURL: URL(fileURLWithPath: "/mock/malformed.watchrelay"),
            error: nil
        )

        XCTAssertEqual(completion.segmentID, id)
        XCTAssertEqual(completion.segmentIDState, .parseable)
        XCTAssertNil(completion.generation)
        XCTAssertEqual(completion.generationState, .unparseable)
        XCTAssertNil(completion.attemptID)
        XCTAssertEqual(completion.attemptIDState, .unparseable)
        XCTAssertNil(completion.attemptStartedAt)
        XCTAssertEqual(completion.attemptStartedAtState, .unparseable)
    }

    func testOutstandingObservationsDistinguishSameSegmentObjectsByRuntimeToken() throws {
        let id = UUID()
        let session = MockWatchConnectivitySession()
        session.seedOutstandingTransfer(id: id, attemptID: UUID())
        session.seedOutstandingTransfer(id: id, attemptID: UUID())

        let observations = session.outstandingFileTransfers

        XCTAssertEqual(observations.map(\.runtimeToken.value), [0, 1])
        XCTAssertEqual(observations.map(\.snapshot.segmentID), [id, id])
        XCTAssertNotEqual(observations[0].attemptID, observations[1].attemptID)
    }
}
