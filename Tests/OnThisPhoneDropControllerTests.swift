// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OnThisPhoneDropControllerTests: XCTestCase {
    func testRequestDropCommitsOnceAfterTimerFires() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("one")
        }
        await sleeper.waitForPending(1)

        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(controller.pendingIDs, Set(["one"]))
        XCTAssertEqual(controller.surfaced?.id, "one")

        sleeper.fireNext()
        await probe.waitForCount(1)

        XCTAssertEqual(probe.ids, ["one"])
        XCTAssertEqual(controller.pendingIDs, [])
        XCTAssertNil(controller.surfaced)

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 1)
    }

    func testUndoBeforeTimerFiresNeverCommits() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("one")
        }
        await sleeper.waitForPending(1)

        controller.undo(itemID: "one")
        XCTAssertEqual(controller.pendingIDs, [])
        XCTAssertNil(controller.surfaced)

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 0)
    }

    func testUndoNewestResurfacesPreviousWithoutResettingTimer() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "first", descriptor: "first") {
            probe.record("first")
        }
        await sleeper.waitForPending(1)

        controller.requestDrop(itemID: "second", descriptor: "second") {
            probe.record("second")
        }
        await sleeper.waitForPending(2)
        XCTAssertEqual(controller.surfaced?.id, "second")

        controller.undo(itemID: "second")
        XCTAssertEqual(controller.surfaced?.id, "first")
        XCTAssertEqual(controller.pendingIDs, Set(["first"]))

        sleeper.fire(at: 0)
        await probe.waitForCount(1)
        XCTAssertEqual(probe.ids, ["first"])

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 1)
    }

    func testNonSurfacedEntryCommitsAndClearsWithoutResurfacing() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "first", descriptor: "first") {
            probe.record("first")
        }
        controller.requestDrop(itemID: "second", descriptor: "second") {
            probe.record("second")
        }
        await sleeper.waitForPending(2)
        XCTAssertEqual(controller.surfaced?.id, "second")

        sleeper.fire(at: 0)
        await probe.waitForCount(1)
        XCTAssertEqual(probe.ids, ["first"])
        XCTAssertEqual(controller.pendingIDs, Set(["second"]))
        XCTAssertEqual(controller.surfaced?.id, "second")

        sleeper.fireNext()
        await probe.waitForCount(2)
        XCTAssertEqual(probe.ids, ["first", "second"])
        XCTAssertEqual(controller.pendingIDs, [])
    }

    func testDuplicateUnfinishedIDIsIgnored() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("first")
        }
        await sleeper.waitForPending(1)

        controller.requestDrop(itemID: "one", descriptor: "second") {
            probe.record("second")
        }
        await Task.yield()
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertEqual(controller.surfaced?.descriptor, "first")

        sleeper.fireNext()
        await probe.waitForCount(1)
        XCTAssertEqual(probe.ids, ["first"])
        XCTAssertEqual(probe.count, 1)
    }

    func testCancelAllClearsPendingAndCancelsTimers() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("one")
        }
        await sleeper.waitForPending(1)

        controller.cancelAll()
        XCTAssertEqual(controller.pendingIDs, [])
        XCTAssertNil(controller.surfaced)

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 0)
    }

    func testMakeDropCommitReturnsClosureForValidIDsAndNilForInvalidIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneDropControllerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("Observer", isDirectory: true),
            startPathMonitor: false
        )
        let locationUploader = LocationUploader(
            cacheRootURL: root.appendingPathComponent("Location", isDirectory: true),
            startPathMonitor: false
        )
        let sessionID = UUID()
        let shareID = UUID()

        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: shareID.uuidString, sourceKind: .share),
            importQueue: importQueue,
            observerUploader: observerUploader,
            locationUploader: locationUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            locationUploader: locationUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "location:20260603-110000_300", sourceKind: .location),
            importQueue: importQueue,
            observerUploader: observerUploader,
            locationUploader: locationUploader
        ))
        XCTAssertNil(makeDropCommit(
            for: Self.item(id: "audio:not-a-uuid:chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            locationUploader: locationUploader
        ))
    }

    private static func item(id: String, sourceKind: OnThisPhoneSourceKind) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id,
            sourceKind: sourceKind,
            sendState: .savedOnThisPhone,
            contentType: "application/octet-stream",
            filename: "item.bin",
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: nil
        )
    }
}

@MainActor
private final class TestSleeper: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func sleep(for duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            self.continuations.append(continuation)
        }
        try Task.checkCancellation()
    }

    func waitForPending(_ count: Int) async {
        while self.continuations.count < count {
            await Task.yield()
        }
    }

    func fireNext() {
        self.fire(at: 0)
    }

    func fire(at index: Int) {
        guard self.continuations.indices.contains(index) else { return }
        let continuation = self.continuations.remove(at: index)
        continuation.resume()
    }
}

@MainActor
private final class CommitProbe {
    private(set) var ids: [String] = []

    var count: Int {
        self.ids.count
    }

    func record(_ id: String) {
        self.ids.append(id)
    }

    func waitForCount(_ count: Int) async {
        while self.ids.count < count {
            await Task.yield()
        }
    }
}
