// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class MobileSegmentEngineTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentEngineTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Self.date(hour: 9, minute: 0, second: 0))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        super.tearDown()
    }

    func testSourceSetChangeFinalizesOldWindowAndOpensOneMixedSegment() async throws {
        let harness = self.makeHarness()
        await harness.engine.startLocation(tier: .balanced, accuracy: .full)
        harness.engine.recordLocationFix(Self.fix(at: self.clock.now()))
        self.clock.advance(by: 75)

        let audioURL = try await harness.engine.startAudio(mode: .meeting)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.deletingLastPathComponent().path))
        let pending = try harness.store.list(.pending)
        let active = try harness.store.list(.active)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(active.count, 1)

        let finalized = try harness.store.readManifest(in: try XCTUnwrap(pending.first))
        XCTAssertEqual(finalized.openedWithSources, [.location])
        XCTAssertEqual(finalized.location.state, .finalizedArtifact)
        XCTAssertEqual(finalized.location.fixCount, 1)
        XCTAssertEqual(finalized.durationS, 75)
        XCTAssertEqual(finalized.day, Self.dayString(for: finalized.startedAt))
        XCTAssertEqual(finalized.segment, ChunkSidecar.segmentString(for: finalized.startedAt, durationSeconds: 75))

        let current = try harness.store.readManifest(in: try XCTUnwrap(active.first))
        XCTAssertEqual(Set(current.openedWithSources), [.audio, .location])
    }

    func testSourceStartDuringAudioFinalizationCoalescesIntoOneFollowUpBoundary() async throws {
        let harness = self.makeHarness()
        let gate = AsyncGate()
        var rotateURLs: [URL] = []
        var currentAudioURL: URL?
        harness.engine.rotateAudio = { nextURL in
            rotateURLs.append(nextURL)
            let finalizedURL = try XCTUnwrap(currentAudioURL)
            try Data("next-audio-\(rotateURLs.count)".utf8).write(to: nextURL, options: .atomic)
            currentAudioURL = nextURL
            if rotateURLs.count == 1 {
                await gate.wait()
                return ObserverRecordedChunk(url: finalizedURL, duration: 300)
            }
            return ObserverRecordedChunk(url: finalizedURL, duration: 1)
        }

        let initialAudioURL = try await harness.engine.startAudio(mode: .meeting)
        currentAudioURL = initialAudioURL
        try Data("first-audio".utf8).write(to: initialAudioURL, options: .atomic)
        await self.yieldToMainActor()
        self.clock.advance(by: 300)
        await self.yieldToMainActor()
        await gate.waitUntilParked()

        self.clock.advance(by: 1)
        await harness.engine.startLocation(tier: .balanced, accuracy: .full)
        harness.engine.recordLocationFix(Self.fix(at: self.clock.now()))
        gate.release()
        try await self.waitFor("coalesced follow-up boundary") {
            (try? harness.store.list(.pending).count) == 2
                && (try? harness.store.list(.active).count) == 1
        }

        XCTAssertEqual(rotateURLs.count, 2)
        let pending = try harness.store.list(.pending)
        let manifests = try pending.map { try harness.store.readManifest(in: $0) }
        XCTAssertEqual(manifests.filter { $0.audio.state == .finalizedArtifact }.count, 2)
        XCTAssertTrue(manifests.allSatisfy { $0.location.state == .notDeclared })

        let active = try XCTUnwrap(try harness.store.list(.active).first)
        let activeManifest = try harness.store.readManifest(in: active)
        XCTAssertEqual(Set(activeManifest.openedWithSources), [.audio, .location])

        await harness.engine.stopLocation()
        try await self.waitFor("location follow-up finalization") {
            (try? harness.store.list(.pending).count) == 3
                && (try? harness.store.list(.active).count) == 1
        }
        let finalizedAfterStop = try harness.store.list(.pending).map { try harness.store.readManifest(in: $0) }
        let mixedLocationSegments = finalizedAfterStop.filter {
            Set($0.openedWithSources) == [.audio, .location]
                && $0.location.state == .finalizedArtifact
                && $0.location.fixCount == 1
        }
        XCTAssertEqual(mixedLocationSegments.count, 1)
        XCTAssertEqual(rotateURLs.count, 3)
    }

    func testStableSourceSetRollsEvery300SecondsWithAdjacentWindows() async throws {
        let harness = self.makeHarness()
        await harness.engine.startLocation(tier: .light, accuracy: .full)
        harness.engine.recordLocationFix(Self.fix(at: self.clock.now()))
        await self.yieldToMainActor()

        self.clock.advance(by: 300)
        try await self.waitFor("first location rollover") {
            (try? harness.store.list(.pending).count) == 1
                && (try? harness.store.list(.active).count) == 1
        }

        let pending = try XCTUnwrap(try harness.store.list(.pending).first)
        let active = try XCTUnwrap(try harness.store.list(.active).first)
        let finalized = try harness.store.readManifest(in: pending)
        let current = try harness.store.readManifest(in: active)

        XCTAssertEqual(finalized.openedWithSources, [.location])
        XCTAssertEqual(current.openedWithSources, [.location])
        XCTAssertEqual(finalized.durationS, 300)
        XCTAssertEqual(current.startedAt, finalized.startedAt.addingTimeInterval(300))
    }

    func testLocationMutatorsAppendLiveLogAndRefreshLiveness() async throws {
        let harness = self.makeHarness()
        await harness.engine.startLocation(tier: .balanced, accuracy: .full)
        let activeDirectory = try XCTUnwrap(try harness.store.list(.active).first)
        let segmentID = try XCTUnwrap(UUID(uuidString: activeDirectory.lastPathComponent))

        self.clock.advance(by: 5)
        harness.engine.updateLocation(tier: .full, accuracy: .reduced)
        let fix = Self.fix(at: self.clock.now())
        harness.engine.recordLocationFix(fix)
        self.clock.advance(by: 5)
        let visit = LocationVisit(
            arrival: self.clock.now().addingTimeInterval(-2),
            departure: self.clock.now(),
            lat: 37.5,
            lon: -122.2,
            hAcc: 18
        )
        harness.engine.recordLocationVisit(visit)
        harness.engine.recordLocationGap()

        let liveData = try harness.store.readData(at: harness.store.locationPartURL(in: activeDirectory))
        let recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: liveData)
        XCTAssertEqual(recovered.tier, .full)
        XCTAssertEqual(recovered.accuracy, .reduced)
        XCTAssertEqual(recovered.fixes, [fix])
        XCTAssertEqual(recovered.visits, [visit])
        XCTAssertTrue(recovered.gap)

        let livenessData = try harness.store.readData(at: harness.store.locationLivenessURL(in: activeDirectory))
        let liveness = try MobileSegmentLocationWriter.decoder().decode(
            MobileSegmentLocationSegmentLiveness.self,
            from: livenessData
        )
        XCTAssertEqual(liveness.segmentID, segmentID)
        XCTAssertEqual(liveness.sourceSetVersion, 1)
        XCTAssertEqual(liveness.fixCount, 1)
        XCTAssertEqual(liveness.visitCount, 1)
        XCTAssertTrue(liveness.gap)
    }

    func testAudioFinalizerFailureCreatesFailedMarkerAndNoUploadRequest() async throws {
        let harness = self.makeHarness()
        harness.engine.rotateAudio = { _ in
            throw TestError.audioFinalizeFailed
        }
        let audioURL = try await harness.engine.startAudio(mode: .meeting)
        try Data("audio".utf8).write(to: audioURL, options: .atomic)
        await self.yieldToMainActor()

        self.clock.advance(by: 300)
        try await self.waitFor("failed audio finalization") {
            (try? harness.store.list(.failed).count) == 1
        }

        let failed = try XCTUnwrap(try harness.store.list(.failed).first)
        let manifest = try harness.store.readManifest(in: failed)
        XCTAssertEqual(manifest.audio.state, .failedToFinalize)
        XCTAssertEqual(manifest.audio.stage, "source-finalize")
        XCTAssertTrue(manifest.audio.reason?.contains("audioFinalizeFailed") == true)
        XCTAssertEqual(try harness.store.list(.pending).count, 0)
    }

    func testBoundaryCreateFailureKeepsOldSegmentOpenAndStopFinalizesIt() async throws {
        let harness = self.makeHarness()
        let audioURL = try await harness.engine.startAudio(mode: .meeting)
        try Data("old-audio".utf8).write(to: audioURL, options: .atomic)
        guard case .open(let oldSegmentID, let oldSources, _) = harness.engine.state else {
            XCTFail("expected old segment to be open")
            return
        }
        XCTAssertEqual(oldSources, [.audio])
        try await self.waitFor("initial rotation timer") {
            self.clock.pendingSleeperCount == 1
        }

        let activeRoot = harness.store.directoryURL(.active)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: activeRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activeRoot.path)
        }

        await harness.engine.startLocation(tier: .balanced, accuracy: .full)

        guard case .open(let segmentID, let sources, _) = harness.engine.state else {
            XCTFail("expected old segment to remain open")
            return
        }
        XCTAssertEqual(segmentID, oldSegmentID)
        XCTAssertEqual(sources, [.audio])
        try await self.waitFor("rotation timer restarted after create failure") {
            self.clock.pendingSleeperCount >= 2
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activeRoot.path)
        await harness.engine.stopAudio(finalized: ObserverRecordedChunk(url: audioURL, duration: 42))

        try await self.waitFor("old segment finalizes after create failure") {
            (try? harness.store.list(.pending).count) == 1
                && (try? harness.store.list(.active).count) == 0
        }
        let finalizedDirectory = try XCTUnwrap(try harness.store.list(.pending).first)
        let finalized = try harness.store.readManifest(in: finalizedDirectory)
        XCTAssertEqual(finalized.segmentID, oldSegmentID)
        XCTAssertEqual(finalized.audio.state, .finalizedArtifact)
        XCTAssertEqual(finalized.audio.durationS, 42)
    }
}

private extension MobileSegmentEngineTests {
    struct Harness {
        let engine: MobileSegmentEngine
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    enum TestError: Error {
        case audioFinalizeFailed
    }

    func makeHarness() -> Harness {
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        return Harness(
            engine: MobileSegmentEngine(uploader: uploader, clock: self.clock),
            uploader: uploader,
            store: store
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

    func yieldToMainActor() async {
        await Task.yield()
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

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

@MainActor
private final class AsyncGate {
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var isParked = false
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if self.isReleased {
                continuation.resume()
                return
            }
            self.isParked = true
            self.parkedContinuation?.resume()
            self.parkedContinuation = nil
            self.waitContinuation = continuation
        }
    }

    func waitUntilParked() async {
        guard !self.isParked else { return }
        await withCheckedContinuation { continuation in
            self.parkedContinuation = continuation
        }
    }

    func release() {
        self.isReleased = true
        self.waitContinuation?.resume()
        self.waitContinuation = nil
        self.parkedContinuation?.resume()
        self.parkedContinuation = nil
    }
}
