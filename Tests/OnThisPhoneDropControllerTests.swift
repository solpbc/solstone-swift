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
        let omiUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("OmiObserver", isDirectory: true),
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("WatchObserver", isDirectory: true),
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let sessionID = UUID()
        let shareID = UUID()
        let segmentID = UUID()

        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: shareID.uuidString, sourceKind: .share),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "omi:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "mobile-segment:\(segmentID.uuidString):location", sourceKind: .location),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNil(makeDropCommit(
            for: Self.item(id: "audio:not-a-uuid:chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
    }

    func testAudioDropCommitRoutesOnlyToOwningUploader() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneDropRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerRoot = root.appendingPathComponent("Observer", isDirectory: true)
        let omiRoot = root.appendingPathComponent("OmiObserver", isDirectory: true)
        let watchRoot = root.appendingPathComponent("WatchObserver", isDirectory: true)
        let observerUploader = ObserverUploader(cacheRootURL: observerRoot, startPathMonitor: false)
        let omiUploader = ObserverUploader(
            cacheRootURL: omiRoot,
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchUploader = ObserverUploader(
            cacheRootURL: watchRoot,
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let sessionID = UUID()
        let chunkID = "shared-chunk"
        let observerFailedAudio = try Self.writeFailedPair(root: observerRoot, sessionID: sessionID, chunkID: chunkID)
        let omiFailedAudio = try Self.writeFailedPair(root: omiRoot, sessionID: sessionID, chunkID: chunkID)

        let omiCommit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: "omi:\(sessionID.uuidString):\(chunkID)", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        omiCommit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: observerFailedAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: omiFailedAudio.path))

        let observerCommit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):\(chunkID)", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        observerCommit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: observerFailedAudio.path))
    }

    func testWatchAudioDropAlsoRemovesStagingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneWatchDropTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("Observer", isDirectory: true),
            startPathMonitor: false
        )
        let omiUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("OmiObserver", isDirectory: true),
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchRoot = root.appendingPathComponent("WatchObserver", isDirectory: true)
        let watchUploader = ObserverUploader(
            cacheRootURL: watchRoot,
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let sessionID = UUID()
        let chunkID = sessionID.uuidString
        let watchFailedAudio = try Self.writeFailedPair(root: watchRoot, sessionID: sessionID, chunkID: chunkID)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let stagedDirectory = try Self.writeStagedWatchSegment(stagingRoot: stagingRoot, id: sessionID)
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            watchUploader: watchUploader,
            watchRegistration: Self.watchRegistration(),
            localPortProvider: { 7071 },
            tempDirectoryURL: root.appendingPathComponent("watch-drain-temp", isDirectory: true)
        )

        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: "watch:\(sessionID.uuidString):\(chunkID)", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            omiUploader: omiUploader,
            watchUploader: watchUploader,
            mobileSegmentUploader: mobileSegmentUploader,
            removeWatchStaging: drain.removeStaged
        ))
        commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: watchFailedAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
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

    @MainActor
    private static func mobileSegmentUploader(root: URL) -> MobileSegmentUploader {
        let transport = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("MobileSegmentTransport", isDirectory: true),
            isJournalConfigured: { false },
            localPortProvider: { nil },
            startPathMonitor: false
        )
        return MobileSegmentUploader(
            transport: transport,
            store: MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true)),
            clock: MockObserverClock()
        )
    }

    private static func writeFailedPair(root: URL, sessionID: UUID, chunkID: String) throws -> URL {
        let failedDirectory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("failed", isDirectory: true)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        let audioURL = failedDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        try Data("audio".utf8).write(to: audioURL)
        try Data("{}".utf8).write(to: failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        return audioURL
    }

    @MainActor
    private static func writeStagedWatchSegment(stagingRoot: URL, id: UUID) throws -> URL {
        let directory = stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = WatchSegmentManifest(
            id: id,
            day: "20260603",
            segment: "120000_300",
            startedAt: Date(timeIntervalSince1970: 1_780_444_800),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .finalized,
            failureReason: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(WatchSegmentBundleCodec.manifestFilename, isDirectory: false),
            options: .atomic
        )
        try Data("audio".utf8).write(
            to: directory.appendingPathComponent(WatchSegmentBundleCodec.audioFilename, isDirectory: false),
            options: .atomic
        )
        return directory
    }

    @MainActor
    private static func watchRegistration() -> ObserverRegistration {
        ObserverRegistration(
            hostname: "test-phone",
            version: "0.1.0",
            streamType: "watch",
            label: "watch",
            loadKey: { "watch-handle-xyz" },
            saveKey: { _ in },
            deleteKey: {},
            loadPrefix: { nil },
            savePrefix: { _ in },
            deletePrefix: {}
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
