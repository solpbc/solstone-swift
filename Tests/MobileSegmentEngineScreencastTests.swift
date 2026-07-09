// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class MobileSegmentEngineScreencastTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentEngineScreencastTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Self.date(hour: 10, minute: 0, second: 0))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        super.tearDown()
    }

    func testStartScreencastUnionsCurrentSources() async throws {
        for priorSources in Self.priorSourceSets {
            let harness = self.makeHarness()
            try await self.open(sources: priorSources, harness: harness)
            self.clock.advance(by: 10)

            let handoff = try await harness.engine.startScreencast(at: self.clock.now())

            let activeDirectory = try XCTUnwrap(try harness.store.list(.active).first)
            let manifest = try harness.store.readManifest(in: activeDirectory)
            XCTAssertEqual(Set(manifest.openedWithSources), priorSources.union([.screencast]))
            XCTAssertEqual(handoff.segmentID.uuidString, activeDirectory.lastPathComponent)
            XCTAssertEqual(Set(handoff.sourceSet), priorSources.union([.screencast]))
            XCTAssertEqual(handoff.screenFinalRelativePath, MobileSegmentScreencastPaths.screenRelativePath(segmentID: handoff.segmentID))
        }
    }

    func testStopScreencastSubtractsOnlyScreencast() async throws {
        for remainingSources in Self.priorSourceSets {
            let harness = self.makeHarness()
            try await self.open(sources: remainingSources, harness: harness)
            self.clock.advance(by: 10)
            let handoff = try await harness.engine.startScreencast(at: self.clock.now())
            try harness.uploader.recordScreencastNoArtifact(
                segmentID: handoff.segmentID,
                startedAt: handoff.startedAt,
                endedAt: self.clock.now(),
                durationS: 0,
                reason: "test_no_video"
            )

            self.clock.advance(by: 5)
            try await harness.engine.stopScreencast(at: self.clock.now())

            let activeDirectories = try harness.store.list(.active)
            if remainingSources.isEmpty {
                XCTAssertTrue(activeDirectories.isEmpty)
            } else {
                let activeDirectory = try XCTUnwrap(activeDirectories.first)
                let manifest = try harness.store.readManifest(in: activeDirectory)
                XCTAssertEqual(Set(manifest.openedWithSources), remainingSources)
            }
        }
    }

    func testTimerRolloverKeepsScreencastInStableSourceSet() async throws {
        let harness = self.makeHarness()
        var publishedHandoffs: [MobileSegmentScreencastHandoffRecord] = []
        harness.engine.screencastRolloverHandler = { handoff in
            publishedHandoffs.append(handoff)
        }
        try await self.open(sources: [.audio, .location], harness: harness)
        self.clock.advance(by: 10)
        let closingHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        let closingDirectory = harness.store.segmentDirectoryURL(.active, segmentID: closingHandoff.segmentID)
        try Data("live-screen".utf8).write(to: harness.store.screenPartURL(in: closingDirectory), options: .atomic)
        try self.writeScreencastLiveness(segmentID: closingHandoff.segmentID, store: harness.store, lastSeenAt: self.clock.now())
        await Task.yield()

        self.clock.advance(by: 295)
        try self.writeScreencastLiveness(segmentID: closingHandoff.segmentID, store: harness.store, lastSeenAt: self.clock.now())
        self.clock.advance(by: 5)
        try await self.waitFor("screencast rollover") {
            (try? harness.store.list(.active).count) == 2
                && publishedHandoffs.count == 1
        }
        let activeIDs = try harness.store.list(.active).map(\.lastPathComponent).sorted()
        let pendingIDs = try harness.store.list(.pending).map(\.lastPathComponent).sorted()
        let failedIDs = try harness.store.list(.failed).map(\.lastPathComponent).sorted()
        let rolloverState = "active=\(activeIDs) pending=\(pendingIDs) failed=\(failedIDs) published=\(publishedHandoffs.map(\.segmentID.uuidString))"
        XCTAssertEqual(activeIDs.count, 2, rolloverState)
        XCTAssertEqual(publishedHandoffs.count, 1, rolloverState)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: closingDirectory.appendingPathComponent("manifest.json").path),
            "closing active manifest missing \(rolloverState)"
        )

        let closingManifest = try harness.store.readManifest(in: closingDirectory)
        XCTAssertEqual(closingManifest.screencast.state, .unresolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: closingHandoff.segmentID).path))
        let nextHandoff = try XCTUnwrap(publishedHandoffs.first)
        XCTAssertNotEqual(nextHandoff.segmentID, closingHandoff.segmentID)
        XCTAssertEqual(Set(nextHandoff.sourceSet), [.audio, .location, .screencast])
        let nextDirectory = harness.store.segmentDirectoryURL(.active, segmentID: nextHandoff.segmentID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nextDirectory.appendingPathComponent("manifest.json").path),
            "next active manifest missing \(rolloverState)"
        )
        let nextManifest = try harness.store.readManifest(in: nextDirectory)
        XCTAssertEqual(Set(nextManifest.openedWithSources), [.audio, .location, .screencast])
    }
}

private extension MobileSegmentEngineScreencastTests {
    struct Harness {
        let engine: MobileSegmentEngine
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    static let priorSourceSets: [Set<MobileSegmentSource>] = [
        [],
        [.audio],
        [.location],
        [.audio, .location],
    ]

    func makeHarness() -> Harness {
        let root = self.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true))
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: self.clock)
        return Harness(engine: engine, uploader: uploader, store: store)
    }

    func open(sources: Set<MobileSegmentSource>, harness: Harness) async throws {
        var currentAudioURL: URL?
        harness.engine.rotateAudio = { nextURL in
            if let finalizedURL = currentAudioURL {
                try Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
                let finalized = ObserverRecordedChunk(url: finalizedURL, duration: 1)
                currentAudioURL = nextURL
                return finalized
            }
            try Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
            currentAudioURL = nextURL
            return nil
        }

        if sources.contains(.audio) {
            currentAudioURL = try await harness.engine.startAudio(mode: .meeting)
            if let currentAudioURL {
                try Data("audio".utf8).write(to: currentAudioURL, options: .atomic)
            }
        }
        if sources.contains(.location) {
            await harness.engine.startLocation(tier: .balanced, accuracy: .full)
            harness.engine.recordLocationFix(Self.fix(at: self.clock.now()))
        }
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

    static func fix(at date: Date) -> LocationFix {
        LocationFix(
            t: date,
            lat: 37.3349,
            lon: -122.0090,
            hAcc: 12,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
    }

    static func date(hour: Int, minute: Int, second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 6
        components.day = 28
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.calendar!.date(from: components)!
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
}
