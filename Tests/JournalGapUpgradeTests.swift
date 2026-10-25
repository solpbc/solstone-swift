// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import SPLTunnel
import os
import XCTest

/// The first completed pass opens the gate and copies the old interruption evidence once.
@MainActor
final class JournalGapUpgradeTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: MobileSegmentStore!
    private var clock: MockObserverClock!
    private var ownedCacheFiles: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalGapUpgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        self.clock = MockObserverClock(now: Date())
        self.ownedCacheFiles = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        for url in self.ownedCacheFiles {
            try? FileManager.default.removeItem(at: url)
        }
        self.store = nil
        self.clock = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testLegacyEvidenceIsImportedOnceAndCachesFilesRemain() async throws {
        let stamp = Self.internet.string(from: Date())
        let appGroupID = UUID()
        let cachesID = UUID()
        let tombstoneID = UUID()
        let manifestID = UUID()
        let appGroupFile = try self.writeInterruption(segmentID: appGroupID, reason: "audio_capture_unfinished", stamp: stamp, root: self.store.rootURL)
        let cachesFile = try self.writeInterruption(segmentID: cachesID, reason: "audio_writer_failed", stamp: stamp, root: self.cachesRoot())
        let tombstone = try self.writeTombstone(segmentID: tombstoneID, stamp: stamp, root: self.store.rootURL)
        let manifest = try self.writeManifest(segmentID: manifestID, stamp: stamp, root: self.cachesRoot())
        let malformed = self.store.audioInterruptionDirectory().appendingPathComponent("malformed.json")
        try Data("{".utf8).write(to: malformed)

        let uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
        await uploader.resumeFromDisk()
        let events = uploader.journalEvents
        guard case .complete(let imported, let skipped) = events.readImportMarker() else {
            return XCTFail("import did not complete")
        }
        XCTAssertGreaterThanOrEqual(imported, 4)
        XCTAssertGreaterThanOrEqual(skipped, 1)
        for segmentID in [appGroupID, cachesID, tombstoneID, manifestID] {
            XCTAssertEqual(try self.legacyCount(segmentID, in: events), 1)
        }
        XCTAssertTrue(events.isGateOpen)
        for url in [appGroupFile, cachesFile, tombstone, manifest, malformed] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }

        await uploader.resumeFromDisk()
        for segmentID in [appGroupID, cachesID, tombstoneID, manifestID] {
            XCTAssertEqual(try self.legacyCount(segmentID, in: events), 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.cachesRoot().path))
    }

    func testFailedImportDoesNotHoldTheGate() async throws {
        let audio = self.store.audioInterruptionDirectory()
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-directory".utf8).write(to: audio)
        let uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
        await uploader.resumeFromDisk()
        XCTAssertEqual(uploader.journalEvents.readImportMarker(), .failed(reason: "import failed"))
        XCTAssertTrue(uploader.journalEvents.isGateOpen)
    }

    func testLossWrittenBeforeTheGateIsSeen() throws {
        let uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
        let segmentID = UUID()
        try uploader.journalEvents.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.clock.now(),
            now: self.clock.now()
        )
        let id = JournalEventStore.lossID(segmentID: segmentID, source: .audio)
        XCTAssertFalse(uploader.journalEvents.isGateOpen)
        XCTAssertTrue(uploader.journalEvents.isSeen(id: id))
        XCTAssertEqual(JournalGapNotice.read(store: uploader.journalEvents, now: self.clock.now()), .absent)
    }

    func testCancelThenALaterCompletionOpensTheGateOnce() async throws {
        let opened = try self.store.createActive(manifest: MobileSegmentManifest(
            segmentID: UUID(),
            startedAt: self.clock.now().addingTimeInterval(-3_600),
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        ))
        _ = opened
        let segmentID = try self.store.readManifest(in: opened).segmentID
        _ = try self.store.move(segmentID: segmentID, from: .active, to: .pending)
        let canceller = ResumeCanceller()
        let uploader = MobileSegmentUploader(
            store: self.store,
            clock: self.clock,
            cooperator: MaintenanceCooperator(chunkSize: 1, onCheckpoint: { canceller.cancel() })
        )
        let task = Task { await uploader.resumeFromDisk() }
        canceller.task = task
        await task.value
        XCTAssertFalse(uploader.journalEvents.isGateOpen)

        let completed = MobileSegmentUploader(store: self.store, clock: self.clock)
        await completed.resumeFromDisk()
        XCTAssertTrue(completed.journalEvents.isGateOpen)
        let gate = try Data(contentsOf: completed.journalEvents.rootURL.appendingPathComponent("gate.json"))
        await completed.resumeFromDisk()
        XCTAssertEqual(try Data(contentsOf: completed.journalEvents.rootURL.appendingPathComponent("gate.json")), gate)
    }

    func testResumeCatchOpensTheGate() async throws {
        let uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
        let active = self.store.directoryURL(.active)
        try FileManager.default.removeItem(at: active)
        try Data("not-a-directory".utf8).write(to: active)
        await uploader.resumeFromDisk()
        XCTAssertTrue(uploader.journalEvents.isGateOpen)
    }

    func testLossAfterTheGateOpensShows() async throws {
        let uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
        await uploader.resumeFromDisk()
        XCTAssertTrue(uploader.journalEvents.isGateOpen)
        try uploader.journalEvents.recordLoss(
            segmentID: UUID(),
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.clock.now(),
            now: self.clock.now()
        )
        uploader.refreshCounts()
        XCTAssertTrue(uploader.journalGapNotice.isShowing)
        XCTAssertEqual(uploader.journalGapNotice.dayLine, SourceVocabulary.journalGapToday)
    }

    func testSameJournalMarksNothingAndADifferentJournalMarksEveryEvent() throws {
        let pairingA = Self.pairing(instanceID: "journal-a")
        let pairingB = Self.pairing(instanceID: "journal-b")
        let identityA = try XCTUnwrap(journalVersionMetadataIdentity(for: pairingA))
        let identityB = try XCTUnwrap(journalVersionMetadataIdentity(for: pairingB))
        XCTAssertNotEqual(identityA, identityB)

        let events = JournalEventStore(rootURL: self.tempDirectory.appendingPathComponent("JournalEvents", isDirectory: true))
        let config = self.makeConfig(pairing: nil)
        config.attachJournalEvents(events)
        XCTAssertEqual(events.readIdentity(), "unknown")

        try events.openGate(now: self.clock.now())
        let segmentID = UUID()
        try events.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.clock.now(),
            now: self.clock.now()
        )
        try events.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: nil,
            now: self.clock.now(),
            writerFault: true
        )
        let lossID = JournalEventStore.lossID(segmentID: segmentID, source: .audio)
        config.applyMigratedPairing(pairingA)
        XCTAssertEqual(events.readIdentity(), identityA)
        XCTAssertFalse(events.isSeen(id: lossID))

        config.applyMigratedPairing(pairingA)
        XCTAssertEqual(events.readIdentity(), identityA)
        XCTAssertFalse(events.isSeen(id: lossID))

        config.applyMigratedPairing(pairingB)
        XCTAssertEqual(events.readIdentity(), identityB)
        guard case .events(let rows) = events.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertTrue(events.isSeen(id: row.id))
        }
    }

    func testFailedSeenWriteKeepsThePreviousJournalIdentity() throws {
        let events = JournalEventStore(rootURL: self.tempDirectory.appendingPathComponent("JournalEvents", isDirectory: true))
        let pairingA = Self.pairing(instanceID: "journal-a")
        let pairingB = Self.pairing(instanceID: "journal-b")
        let identityA = try XCTUnwrap(journalVersionMetadataIdentity(for: pairingA))
        try events.writeIdentity(identityA)
        try events.openGate(now: self.clock.now())
        try events.recordLoss(
            segmentID: UUID(),
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: nil,
            now: self.clock.now()
        )
        let seen = events.rootURL.appendingPathComponent("seen", isDirectory: false)
        try Data("blocked".utf8).write(to: seen)
        let config = self.makeConfig(pairing: nil)
        config.attachJournalEvents(events)
        config.applyMigratedPairing(pairingB)
        XCTAssertEqual(events.readIdentity(), identityA)
    }

    // MARK: - Helpers

    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func cachesRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true)
    }

    private func writeInterruption(segmentID: UUID, reason: String, stamp: String, root: URL) throws -> URL {
        let url = root
            .appendingPathComponent("interruptions", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).json")
        try self.writeOwned(Self.legacyJSON(segmentID: segmentID, reason: reason, stamp: stamp), to: url, underCaches: root == self.cachesRoot())
        return url
    }

    private func writeTombstone(segmentID: UUID, stamp: String, root: URL) throws -> URL {
        let url = root
            .appendingPathComponent("tombstones", isDirectory: true)
            .appendingPathComponent("empty", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).json")
        try self.writeOwned(
            Self.legacyJSON(segmentID: segmentID, reason: "audio_undecodable_container", stamp: stamp),
            to: url,
            underCaches: false
        )
        return url
    }

    private func writeManifest(segmentID: UUID, stamp: String, root: URL) throws -> URL {
        let url = root
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent(segmentID.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let body = """
        {"segment_id":"\(segmentID.uuidString)","audio":{"reason":"audio_undecodable_container","last_attempt_at":"\(stamp)"}}
        """
        try self.writeOwned(Data(body.utf8), to: url, underCaches: true)
        return url
    }

    private func writeOwned(_ data: Data, to url: URL, underCaches: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if underCaches {
            self.ownedCacheFiles.append(url)
            self.ownedCacheFiles.append(url.deletingLastPathComponent())
        }
    }

    private static func legacyJSON(segmentID: UUID, reason: String, stamp: String) -> Data {
        Data(#"{"segment_id":"\#(segmentID.uuidString)","reason":"\#(reason)","recorded_at":"\#(stamp)"}"#.utf8)
    }

    private func legacyCount(_ segmentID: UUID, in events: JournalEventStore) throws -> Int {
        guard case .events(let rows) = events.readEvents() else {
            XCTFail("journal events unreadable")
            return 0
        }
        return rows.filter { $0.kind == .legacy && $0.segmentID == segmentID.uuidString }.count
    }

    private func makeConfig(pairing: StoredPairing?) -> AppConfig {
        let box = OSAllocatedUnfairLock<StoredPairing?>(initialState: pairing)
        let confirmation = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: .memory(),
            loadPairing: { box.withLock { $0 } },
            savePairing: { value in box.withLock { $0 = value } },
            deletePairing: { box.withLock { $0 = nil } },
            deletePushKey: {}
        )
        let root = self.tempDirectory!
        let endpoints = root.appendingPathComponent("endpoints-\(UUID().uuidString).json")
        return AppConfig(
            confirmationStore: confirmation,
            store: credentials,
            endpointCache: EndpointCache(fileURL: endpoints),
            appGroupMirror: AppGroupMirror(rootURLProvider: { root })
        )
    }

    private static func pairing(instanceID: String) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "Journal",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:" + String(repeating: "a", count: 64),
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "unused",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private final class ResumeCanceller: @unchecked Sendable {
    var task: Task<Void, Never>?
    func cancel() { self.task?.cancel() }
}
