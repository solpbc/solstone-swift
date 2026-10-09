// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class PhoneAudioWriterCompositionTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAudioComposition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func failedFixture(store: MobileSegmentStore) throws -> (UUID, URL) {
        let id = UUID()
        let now = Date()
        var manifest = MobileSegmentManifest(segmentID: id, startedAt: now.addingTimeInterval(-600),
            openedWithSources: [.audio], activeSourceSetVersion: 1)
        let active = try store.createActive(manifest: manifest)
        let audio = store.audioURL(in: active)
        try Data([0x41]).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-400)], ofItemAtPath: audio.path)
        try store.writeAudioWriterReceipt(PhoneAudioWriterReceipt(segmentID: id, phase: .writing, acceptedFrames: 0), in: active)
        try store.writeOutcome(MobileSegmentSourceResolution(state: .failedToFinalize, reason: "audio_finalize_failed"),
            source: .audio, manifest: &manifest, in: active, now: now)
        return (id, try store.move(segmentID: id, from: .active, to: .failed))
    }

    func testMissingMarkerAndBrokenMarkerHaveDifferentRecoverySemantics() throws {
        let root = try self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSegmentStore(rootURL: root)
        let id = UUID()
        XCTAssertEqual(store.readAudioWriterReceipt(in: root, expectedSegmentID: id), .absent)
        let marker = store.audioWriterReceiptURL(in: root)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root.appendingPathComponent("missing-target"))
        XCTAssertEqual(store.readAudioWriterReceipt(in: root, expectedSegmentID: id), .unusable)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("audio-writer.json"))
        store.testAudioWriterReceiptProbeError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertEqual(store.readAudioWriterReceipt(in: root, expectedSegmentID: id), .unusable)
    }

    func testOwnershipAcquiredDuringInspectionDefersOnlyTheOwnedSegment() async throws {
        let root = try self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSegmentStore(rootURL: root)
        let (ownedID, ownedDirectory) = try self.failedFixture(store: store)
        let (otherID, otherDirectory) = try self.failedFixture(store: store)
        defer { PhoneAudioWriterLease.release(ownedID) }
        let uploader = MobileSegmentUploader(store: store, audioInspector: PhoneAudioInspector { _ in
            await MainActor.run { PhoneAudioWriterLease.acquire(ownedID) }
            return .duration(1)
        })
        let ownedResult = try await uploader.resolveFinalizeFailure(segmentID: ownedID, directory: ownedDirectory, lifecycle: .failed)
        XCTAssertEqual(ownedResult, .deferred)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(in: ownedDirectory)), Data([0x41]))
        XCTAssertEqual(store.audioInterruptionCount(), 0)
        let otherResult = try await uploader.resolveFinalizeFailure(segmentID: otherID, directory: otherDirectory, lifecycle: .failed)
        XCTAssertEqual(otherResult, .repend)
        XCTAssertEqual(store.audioInterruptionCount(), 1)
    }

    func testRecoveryRestoresPrefixRetainedAcrossCancellationExit() async throws {
        let root = try self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSegmentStore(rootURL: root)
        let (id, directory) = try self.failedFixture(store: store)
        let audio = store.audioURL(in: directory)
        try FileManager.default.moveItem(at: audio, to: audio.appendingPathExtension("retained"))
        let uploader = MobileSegmentUploader(store: store, audioInspector: PhoneAudioInspector { _ in .duration(1) })
        let resolution = try await uploader.resolveFinalizeFailure(segmentID: id, directory: directory, lifecycle: .failed)
        XCTAssertEqual(resolution, .repend)
        let pending = store.segmentDirectoryURL(.pending, segmentID: id)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(in: pending)), Data([0x41]))
        XCTAssertEqual(store.audioInterruptionCount(), 1)
    }

    func testTerminalFailedOutcomeDoesNotMoveAnOwnedActiveDirectory() async throws {
        let root = try self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSegmentStore(rootURL: root)
        let id = UUID()
        var manifest = MobileSegmentManifest(segmentID: id, startedAt: Date().addingTimeInterval(-600),
            openedWithSources: [.audio], activeSourceSetVersion: 1)
        let active = try store.createActive(manifest: manifest)
        try Data([0x41]).write(to: store.audioURL(in: active))
        try store.writeOutcome(MobileSegmentSourceResolution(state: .failedToFinalize, reason: "audio_finalize_failed"),
            source: .audio, manifest: &manifest, in: active, now: Date())
        PhoneAudioWriterLease.acquire(id)
        defer { PhoneAudioWriterLease.release(id) }
        let uploader = MobileSegmentUploader(store: store)
        await uploader.finalizeActiveSegment(segmentID: id, endedAt: Date())
        XCTAssertTrue(store.fileExists(active))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(in: active)), Data([0x41]))
        XCTAssertTrue(try store.list(.failed).isEmpty)
        XCTAssertTrue(try store.list(.pending).isEmpty)
    }
}
