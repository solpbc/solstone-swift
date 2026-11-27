// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CryptoKit
import Darwin
import Foundation
import os
import WebKit
import XCTest

@MainActor
final class JournalExportHostTests: XCTestCase {
    private let entryURL = URL(string: "http://127.0.0.1:54321/")!
    private let documentID = UUID().uuidString.lowercased()

    func testPackagedExportContractMatchesProvenanceAndAppInfoPlistPermitsExportBackgroundTask() throws {
        let loaded = try XCTUnwrap(JournalExportHostContract.load())
        XCTAssertEqual(loaded.contract.version, 2)
        XCTAssertEqual(loaded.contract.capability, "solstoneJournalHost")
        XCTAssertEqual(loaded.contract.start, "export.start")
        XCTAssertEqual(loaded.contract.status, "export.status")
        XCTAssertEqual(loaded.contract.pause, "export.pause")
        XCTAssertEqual(loaded.contract.resume, "export.resume")
        XCTAssertEqual(loaded.contract.cancel, "export.cancel")
        XCTAssertEqual(loaded.contract.reveal, "export.reveal")
        XCTAssertEqual(loaded.contract.deviceSpace, "export.device_space")
        XCTAssertEqual(loaded.contract.event, "solstone-journal-export-status")

        let info = Bundle(for: ExportBackgroundDownloadCoordinator.self)
        let permitted = info.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        XCTAssertTrue(
            permitted?.contains(ExportBackgroundDownloadCoordinator.taskIdentifierPrefix + ".*") == true,
            "ExportBackgroundDownloadCoordinator wildcard identifier must be in BGTaskSchedulerPermittedIdentifiers"
        )
    }

    func testAdapterAdvertisesExportTypesAlongsideImportTypes() throws {
        let manager = JournalExportTransferManager(platformName: "ios")
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: self.entryURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { self.entryURL },
            exportTransportKind: { "local" }
        ))
        let script = host.adapterScript
        XCTAssertTrue(script.contains("exportContract.start"))
        XCTAssertTrue(script.contains("exportContract.deviceSpace"))
        XCTAssertTrue(script.contains("\"export.start\""))
        XCTAssertTrue(script.contains("\"solstone-journal-export-status\""))
    }

    func testDeviceSpaceOmitsFreeBytesWhenProviderWithholdsCapacity() async throws {
        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in nil }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: self.entryURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { self.entryURL },
            exportTransportKind: { "local" }
        ))
        let reply = try await self.send(["type": "export.device_space", "id": "space-1"], to: host)
        XCTAssertEqual(reply["id"] as? String, "space-1")
        XCTAssertEqual(reply["platform"] as? String, "ios")
        XCTAssertNil(reply["free_bytes"])
    }

    func testStartStreamsVerifiesSHA256AndPreservesPreexistingFile() async throws {
        let count = 512 * 1024 + 313
        let bytes: [UInt8] = (0..<count).map { UInt8($0 & 0xff) }
        let payload = Data(bytes)
        let expectedSHA = Self.sha256Hex(payload)
        let exportID = "exp_ios_ok_1"
        let server = try IOSLoopbackExportServer(payload: payload, etag: "\"sha256-\(expectedSHA)\"")
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Preexisting document with the same name must stay intact.
        let existingURL = folder.appendingPathComponent("solstone-journal-2026-11-26.zip")
        let existingBytes = Data("preexisting-archive".utf8)
        try existingBytes.write(to: existingURL)

        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in nil }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        let reply = try await self.send([
            "type": "export.start",
            "id": "start-1",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "solstone-journal-2026-11-26.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": "\"sha256-\(expectedSHA)\"",
            "mode": "complete",
        ], to: host)
        XCTAssertEqual(reply["id"] as? String, "start-1")
        XCTAssertEqual(reply["export_id"] as? String, exportID)

        let terminal = try await self.waitForPhase(manager, in: ["saved", "error"])
        XCTAssertEqual(terminal.phase, "saved")
        XCTAssertTrue(terminal.verified)
        XCTAssertEqual(terminal.bytesWritten, Int64(payload.count))
        XCTAssertEqual(terminal.totalBytes, Int64(payload.count))

        // Existing file untouched; new verified export saved as unique sibling.
        XCTAssertEqual(try Data(contentsOf: existingURL), existingBytes)
        let savedURL = folder.appendingPathComponent("solstone-journal-2026-11-26 (2).zip")
        XCTAssertEqual(try Data(contentsOf: savedURL), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(in: folder, exportID: exportID).path))
    }

    func testStartRefusesWhenReportedVolumeSpaceIsBelowRequired() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-low-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let exportID = "exp_ios_low_1"
        let manager = JournalExportTransferManager(
            platformName: "ipados",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 1024 }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: self.entryURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { self.entryURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        let reply = try await self.send([
            "type": "export.start",
            "id": "low-1",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "solstone-journal-2026-11-26.zip",
            "size_bytes": 10_000_000,
            "sha256": String(repeating: "a", count: 64),
            "etag": "\"sha256-test\"",
        ], to: host)
        XCTAssertEqual(reply["phase"] as? String, "error")
        XCTAssertEqual(reply["platform"] as? String, "ipados")
        XCTAssertEqual(reply["error_code"] as? String, "insufficient_device_space")
        XCTAssertEqual((reply["available_bytes"] as? NSNumber)?.int64Value, 1024)
    }

    func testInterruptedDownloadResumesWithRangeAndIfRange() async throws {
        let count = 320 * 1024 + 97
        let bytes: [UInt8] = (0..<count).map { UInt8(($0 * 7) & 0xff) }
        let payload = Data(bytes)
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"sha256-\(expectedSHA)\""
        let exportID = "exp_ios_resume_1"
        let server = try IOSLoopbackExportServer(payload: payload, etag: etag, truncateFirstAttemptAt: 131_072)
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 100_000_000 }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        _ = try await self.send([
            "type": "export.start",
            "id": "res-start",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "solstone-journal-resume.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": etag,
        ], to: host)

        let paused = try await self.waitForPhase(manager, in: ["paused", "error"])
        XCTAssertEqual(paused.phase, "paused")
        XCTAssertEqual(paused.pauseReason, "disconnected")
        XCTAssertEqual(paused.bytesWritten, 131_072)

        _ = try await self.send([
            "type": "export.resume",
            "id": "res-go",
            "export_id": exportID,
        ], to: host)

        let saved = try await self.waitForPhase(manager, in: ["saved", "error"])
        XCTAssertEqual(saved.phase, "saved")
        XCTAssertTrue(saved.verified)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("solstone-journal-resume.zip")), payload)

        let requests = server.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].range, "bytes=131072-")
        XCTAssertEqual(requests[1].ifRange, etag)
    }

    func testErasure410RemovesPartAndReportsInvalidatedByErasure() async throws {
        let payload = Data("irrelevant".utf8)
        let expectedSHA = Self.sha256Hex(payload)
        let exportID = "exp_ios_gone_1"
        let server = try IOSLoopbackExportServer(
            payload: payload,
            etag: "\"sha256-\(expectedSHA)\"",
            fixedStatus: 410,
            fixedBody: Data("{\"code\":\"export_invalidated_by_erasure\"}".utf8)
        )
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 100_000_000 }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        _ = try await self.send([
            "type": "export.start",
            "id": "gone-start",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "solstone-journal-gone.zip",
            "size_bytes": 1024,
            "sha256": expectedSHA,
            "etag": "\"sha256-\(expectedSHA)\"",
        ], to: host)

        let failed = try await self.waitForPhase(manager, in: ["error", "saved"])
        XCTAssertEqual(failed.phase, "error")
        XCTAssertEqual(failed.errorCode, "export_invalidated_by_erasure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(in: folder, exportID: exportID).path))
    }

    func testSlowConsumer32MiBStreamCapsBufferedBytesViaBackpressure() async throws {
        let size = 32 * 1024 * 1024
        var payload = Data(count: size)
        payload.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<size {
                bytes[i] = UInt8((i &* 31 &+ (i >> 8)) & 0xff)
            }
        }
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"sha256-\(expectedSHA)\""
        let exportID = "exp_ios_32mb_backpressure"
        let server = try IOSLoopbackExportServer(payload: payload, etag: etag)
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-32mb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 512 * 1024 * 1024 },
            onChunkWritten: {
                try? await Task.sleep(for: .milliseconds(2))
            }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        _ = try await self.send([
            "type": "export.start",
            "id": "bp-1",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "large-32mb.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": etag,
        ], to: host)

        let terminal = try await self.waitForPhase(manager, in: ["saved", "error"], timeout: 60)
        XCTAssertEqual(terminal.phase, "saved")
        XCTAssertTrue(terminal.verified)
        XCTAssertLessThan(
            manager.lastMaxBufferedBytes,
            6 * 1024 * 1024,
            "bounded stream backpressure must cap peak buffered bytes well below the 32 MiB payload"
        )
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("large-32mb.zip")), payload)
    }

    func testResume206WithMismatchedETagRefusesAppendAndFailsCleanly() async throws {
        let count = 256 * 1024 + 41
        let payload = Data((0..<count).map { UInt8(($0 * 11) & 0xff) })
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"sha256-\(expectedSHA)\""
        let exportID = "exp_ios_etag_mismatch"
        let server = try IOSLoopbackExportServer(
            payload: payload,
            etag: etag,
            response206ETag: "\"sha256-stale-other\"",
            truncateFirstAttemptAt: 98_304
        )
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-etag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 100_000_000 }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        _ = try await self.send([
            "type": "export.start",
            "id": "etag-1",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "etag-test.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": etag,
        ], to: host)

        let paused = try await self.waitForPhase(manager, in: ["paused", "error"])
        XCTAssertEqual(paused.phase, "paused")

        _ = try await self.send([
            "type": "export.resume",
            "id": "etag-2",
            "export_id": exportID,
        ], to: host)

        let failed = try await self.waitForPhase(manager, in: ["error", "saved"])
        XCTAssertEqual(failed.phase, "error")
        XCTAssertEqual(failed.errorCode, "save_failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("etag-test.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(in: folder, exportID: exportID).path))
    }

    func testCancelDuringTransferPreventsStalePublishAndRemovesPart() async throws {
        let count = 2 * 1024 * 1024
        let payload = Data((0..<count).map { UInt8(($0 * 13) & 0xff) })
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"sha256-\(expectedSHA)\""
        let exportID = "exp_ios_cancel_race"
        let server = try IOSLoopbackExportServer(payload: payload, etag: etag)
        defer { server.stop() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 100_000_000 },
            onChunkWritten: {
                try? await Task.sleep(for: .milliseconds(25))
            }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        _ = try await self.send([
            "type": "export.start",
            "id": "can-1",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "cancelled.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": etag,
        ], to: host)

        try await Task.sleep(for: .milliseconds(40))
        let cancelled = try await self.send([
            "type": "export.cancel",
            "id": "can-2",
            "export_id": exportID,
        ], to: host)
        XCTAssertEqual(cancelled["phase"] as? String, "idle")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.snapshot.phase, "idle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancelled.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: JournalExportTransferManager.partURL(in: folder, exportID: exportID).path))
    }

    func testBackgroundDownloadCoordinatorSustainsTunnelAndPausesOnExpiration() async {
        XCTAssertTrue(isBackgroundTunnelSustained(
            locationSustaining: false,
            finishSyncingActive: false,
            exportDownloadActive: true
        ))

        let scheduling = SpyExportBgScheduling()
        let handle = SpyExportBgTaskHandle()
        var expirePauseCount = 0
        var phase = "transferring"

        let coordinator = ExportBackgroundDownloadCoordinator(
            activeTarget: {
                ExportBackgroundDownloadTarget(
                    exportID: "exp_bg_1",
                    filename: "solstone-journal-2026-11-26.zip",
                    bytesWritten: 65_536,
                    bytesTotal: 262_144,
                    phase: phase
                )
            },
            isConnected: { true },
            onExpirePause: {
                expirePauseCount += 1
                phase = "paused"
            },
            shouldDisconnectOnExit: { false },
            disconnect: {},
            scheduling: scheduling,
            clock: ImmediateExportBgClock(),
            settleInterval: .milliseconds(5)
        )

        coordinator.submitIfNeeded(target: ExportBackgroundDownloadTarget(
            exportID: "exp_bg_1",
            filename: "solstone-journal-2026-11-26.zip",
            bytesWritten: 0,
            bytesTotal: 262_144,
            phase: "transferring"
        ))
        XCTAssertTrue(scheduling.registeredIdentifier?.hasPrefix(ExportBackgroundDownloadCoordinator.taskIdentifierPrefix + ".") == true)

        let task = Task { @MainActor in
            await coordinator.runTask(handle)
        }
        await Task.yield()
        XCTAssertTrue(coordinator.isSustainingBackground)
        handle.fireExpiration()
        await task.value

        XCTAssertFalse(coordinator.isSustainingBackground)
        XCTAssertGreaterThanOrEqual(expirePauseCount, 1)
        XCTAssertEqual(coordinator.lastOutcome, .paused)
        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertEqual(handle.lastTitle, AppStrings.ios_app_exportbgsystempausedtitle())
    }

    func testBackgroundDownloadCoordinatorDistinguishesCompletedFromStopped() async {
        // 1. Clean completion ("saved" after active clears) -> .completed + "journal copy saved"
        let savedHandle = SpyExportBgTaskHandle()
        var savedActive: ExportBackgroundDownloadTarget? = ExportBackgroundDownloadTarget(
            exportID: "exp_bg_done",
            filename: "solstone-journal-2026-11-26.zip",
            bytesWritten: 262_144,
            bytesTotal: 262_144,
            phase: "verifying"
        )
        let savedCoordinator = ExportBackgroundDownloadCoordinator(
            activeTarget: { savedActive },
            isConnected: { true },
            onExpirePause: {},
            scheduling: SpyExportBgScheduling(),
            clock: ImmediateExportBgClock(),
            settleInterval: .milliseconds(5)
        )
        let savedTask = Task { @MainActor in
            await savedCoordinator.runTask(savedHandle)
        }
        await Task.yield()
        savedActive = nil
        savedCoordinator.handleProgress(ExportBackgroundDownloadTarget(
            exportID: "exp_bg_done",
            filename: "solstone-journal-2026-11-26.zip",
            bytesWritten: 262_144,
            bytesTotal: 262_144,
            phase: "saved"
        ))
        await savedTask.value
        XCTAssertEqual(savedCoordinator.lastOutcome, .completed)
        XCTAssertEqual(savedHandle.completedSuccess, true)
        XCTAssertEqual(savedHandle.lastTitle, AppStrings.ios_app_exportbgsystemdonetitle())

        // 2. Failure / cancellation ("error" / "idle") -> .stopped + "saving stopped"
        let failedHandle = SpyExportBgTaskHandle()
        var failedActive: ExportBackgroundDownloadTarget? = ExportBackgroundDownloadTarget(
            exportID: "exp_bg_fail",
            filename: "solstone-journal-2026-11-26.zip",
            bytesWritten: 16_384,
            bytesTotal: 262_144,
            phase: "transferring"
        )
        let failedCoordinator = ExportBackgroundDownloadCoordinator(
            activeTarget: { failedActive },
            isConnected: { true },
            onExpirePause: {},
            scheduling: SpyExportBgScheduling(),
            clock: ImmediateExportBgClock(),
            settleInterval: .milliseconds(5)
        )
        let failedTask = Task { @MainActor in
            await failedCoordinator.runTask(failedHandle)
        }
        await Task.yield()
        failedActive = nil
        failedCoordinator.handleProgress(ExportBackgroundDownloadTarget(
            exportID: "exp_bg_fail",
            filename: "solstone-journal-2026-11-26.zip",
            bytesWritten: 0,
            bytesTotal: 262_144,
            phase: "error"
        ))
        await failedTask.value
        XCTAssertEqual(failedCoordinator.lastOutcome, .stopped)
        XCTAssertEqual(failedHandle.completedSuccess, false)
        XCTAssertEqual(failedHandle.lastTitle, AppStrings.ios_app_exportbgsystemstoppedtitle())
    }

    private final class IOSAtomicOffsetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: Int64 = 0
        private var triggered = false

        func record(_ value: Int64) {
            self.lock.withLock { self.offset = value }
        }

        func value() -> Int64 {
            self.lock.withLock { self.offset }
        }

        func fireOnceAtOrAbove(_ threshold: Int64, offset value: Int64) -> Bool {
            self.lock.withLock {
                guard !self.triggered, value >= threshold else { return false }
                self.triggered = true
                self.offset = value
                return true
            }
        }
    }

    private static func makeSyntheticData(count: Int, mul: Int, add: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<count {
                ptr[i] = UInt8((i &* mul &+ add) & 0xFF)
            }
        }
        return data
    }

    func testSha256CancellationStopsPromptlyAndFreshSaveSucceeds() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-export-vc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1. Direct cooperative cancellation of sha256File on a physically written 16 MiB file.
        let bigFile = folder.appendingPathComponent("phys-16m.part")
        let sixteenMiB = 16 * 1024 * 1024
        try Self.makeSyntheticData(count: sixteenMiB, mul: 37, add: 13).write(to: bigFile)

        let directBox = IOSAtomicOffsetBox()
        let cancelFlag = IOSExportCancellationFlag()
        let directTask = Task.detached { () -> Result<String, Error> in
            do {
                let digest = try JournalExportTransferManager.sha256File(
                    at: bigFile,
                    shouldCancel: { cancelFlag.isCancelled },
                    onChunkRead: { offset in
                        directBox.record(offset)
                        if offset >= 256 * 1024 {
                            cancelFlag.cancel()
                            try? FileManager.default.removeItem(at: bigFile)
                        }
                    }
                )
                return .success(digest)
            } catch {
                return .failure(error)
            }
        }
        let directOutcome = await directTask.value
        switch directOutcome {
        case .success:
            XCTFail("expected CancellationError when cancelled after first 256 KiB")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        let observed = directBox.value()
        XCTAssertLessThanOrEqual(observed, 512 * 1024)

        // 2. Host cancel during verification preserves folder contents and allows a clean fresh save.
        let payload = Self.makeSyntheticData(count: 4 * 1024 * 1024, mul: 19, add: 3)
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"\(expectedSHA)\""
        let exportID = "exp_ios_vc_1"
        let server = try IOSLoopbackExportServer(payload: payload, etag: etag)
        defer { server.stop() }

        let existing = folder.appendingPathComponent("solstone-journal.zip")
        let sentinel = Data("keep-existing-ios".utf8)
        try sentinel.write(to: existing)

        let verifyBox = IOSAtomicOffsetBox()
        let enteredVerify = DispatchSemaphore(value: 0)
        let cancelIssued = DispatchSemaphore(value: 0)
        let manager = JournalExportTransferManager(
            platformName: "ios",
            prepareRequest: { _ in },
            volumeSpaceProbe: { _ in 10 * 1024 * 1024 * 1024 },
            onVerifyChunkRead: { offset in
                if verifyBox.fireOnceAtOrAbove(256 * 1024, offset: offset) {
                    enteredVerify.signal()
                    _ = cancelIssued.wait(timeout: .now() + .seconds(5))
                } else {
                    verifyBox.record(offset)
                }
            }
        )
        let host = try XCTUnwrap(JournalImportHost(
            entryURL: server.baseURL,
            intake: ExportTestFakeIntake(),
            exportTransferManager: manager,
            exportLiveBaseURL: { server.baseURL },
            exportTransportKind: { "local" },
            exportFolderPicker: { folder }
        ))

        let cancelDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = enteredVerify.wait(timeout: .now() + .seconds(10))
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    _ = manager.cancel(exportID: exportID)
                }
            }
            cancelIssued.signal()
            cancelDone.signal()
        }
        defer { cancelIssued.signal() }

        _ = try await self.send([
            "type": "export.start",
            "id": "ios-vc-1",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "solstone-journal.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": etag,
        ], to: host)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = cancelDone.wait(timeout: .now() + .seconds(10))
                cont.resume()
            }
        }
        let afterCancel = try await self.waitForPhase(manager, in: ["idle", "saved", "error"])
        XCTAssertEqual(afterCancel.phase, "idle")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let vcRead = verifyBox.value()
        XCTAssertEqual(vcRead, 256 * 1024)

        // Fresh save succeeds and publishes a non-colliding verified ZIP while preserving existing file.
        _ = try await self.send([
            "type": "export.start",
            "id": "ios-vc-2",
            "export_id": exportID,
            "download_path": "/app/export/api/ready/\(exportID)/download",
            "filename": "solstone-journal.zip",
            "size_bytes": payload.count,
            "sha256": expectedSHA,
            "etag": etag,
        ], to: host)
        let saved = try await self.waitForPhase(manager, in: ["saved", "error"])
        XCTAssertEqual(saved.phase, "saved")
        XCTAssertTrue(saved.verified)
        let published = folder.appendingPathComponent("solstone-journal (2).zip")
        XCTAssertEqual(try Data(contentsOf: published), payload)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRestartCreditsOnDiskPartialFromFirstAndLaterGenerationsUnderTightSpace() async throws {
        let sixteenMiB = 16 * 1024 * 1024
        let twelveMiB = 12 * 1024 * 1024
        let fiveMiB: Int64 = 5 * 1024 * 1024
        var payload = Data(count: sixteenMiB)
        payload.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<sixteenMiB {
                ptr[i] = UInt8((i &* 43 &+ 5) & 0xFF)
            }
        }
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"\(expectedSHA)\""

        for (label, exportID, partFilename) in [
            ("first_gen", "exp_ios_restart_g1", ".solstone-export-exp_ios_restart_g1-1.part"),
            ("later_gen", "exp_ios_restart_g2", ".solstone-export-exp_ios_restart_g2-3.part"),
        ] {
            let server = try IOSLoopbackExportServer(payload: payload, etag: etag)
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-export-restart-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let partial = folder.appendingPathComponent(partFilename)
            try payload.prefix(twelveMiB).write(to: partial)

            // 4 MiB free refuses with required_bytes == 5 MiB and keeps partial intact.
            let tightManager = JournalExportTransferManager(
                platformName: "ipados",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 4 * 1024 * 1024 }
            )
            let tightHost = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: tightManager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            let refused = try await self.send([
                "type": "export.start",
                "id": "tight-\(label)",
                "export_id": exportID,
                "download_path": "/app/export/api/ready/\(exportID)/download",
                "filename": "solstone-journal.zip",
                "size_bytes": sixteenMiB,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: tightHost)
            XCTAssertEqual(refused["phase"] as? String, "error")
            XCTAssertEqual(refused["error_code"] as? String, "insufficient_device_space")
            XCTAssertEqual((refused["required_bytes"] as? NSNumber)?.int64Value, fiveMiB)
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(server.recordedRequests().count, 0)

            // Fresh manager with exactly 5 MiB free credits the 12 MiB partial and resumes via Range + If-Range.
            let freshManager = JournalExportTransferManager(
                platformName: "ipados",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in fiveMiB }
            )
            let freshHost = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: freshManager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "resume-\(label)",
                "export_id": exportID,
                "download_path": "/app/export/api/ready/\(exportID)/download",
                "filename": "solstone-journal.zip",
                "size_bytes": sixteenMiB,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: freshHost)

            let saved = try await self.waitForPhase(freshManager, in: ["saved", "error"])
            XCTAssertEqual(saved.phase, "saved", "case \(label) failed: \(String(describing: saved.errorCode))")
            XCTAssertTrue(saved.verified)
            let outURL = folder.appendingPathComponent("solstone-journal.zip")
            XCTAssertEqual(try Data(contentsOf: outURL), payload)
            let reqs = server.recordedRequests()
            XCTAssertEqual(reqs.count, 1)
            XCTAssertEqual(reqs.first?.range, "bytes=\(twelveMiB)-")
            XCTAssertEqual(reqs.first?.ifRange, etag)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    func testFullLengthPartialProbesLiveEligibilityVerifiesLocallyAndRespectsErasure() async throws {
        let size = 4 * 1024 * 1024
        let payload = Self.makeSyntheticData(count: size, mul: 53, add: 11)
        let expectedSHA = Self.sha256Hex(payload)
        let etag = "\"\(expectedSHA)\""

        // 1. Live eligible full-length partial (quit during verification): 1-byte Range/If-Range probe,
        //    local SHA-256 verification, publish under 1 MiB headroom (no full refetch).
        do {
            let server = try IOSLoopbackExportServer(payload: payload, etag: etag)
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-exp-fullpart-ok-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let fullPart = folder.appendingPathComponent(".solstone-export-exp_full_ios_1-2.part")
            try payload.write(to: fullPart)

            let manager = JournalExportTransferManager(
                platformName: "ipados",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: manager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "ios-full-ok",
                "export_id": "exp_full_ios_1",
                "download_path": "/app/export/api/ready/exp_full_ios_1/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: host)

            let saved = try await self.waitForPhase(manager, in: ["saved", "error"])
            XCTAssertEqual(saved.phase, "saved")
            XCTAssertTrue(saved.verified)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("solstone-journal.zip")), payload)
            let reqs = server.recordedRequests()
            XCTAssertEqual(reqs.count, 1)
            XCTAssertEqual(reqs.first?.range, "bytes=\(size - 1)-\(size - 1)")
            XCTAssertEqual(reqs.first?.ifRange, etag)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }

        // 2. Full-length partial invalidated by Trash erasure (410): must delete partial and never publish.
        do {
            let server = try IOSLoopbackExportServer(
                payload: payload,
                etag: etag,
                fixedStatus: 410,
                fixedBody: Data(#"{"code":"export_invalidated_by_erasure"}"#.utf8)
            )
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-exp-fullpart-erased-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let fullPart = folder.appendingPathComponent(".solstone-export-exp_full_ios_2-1.part")
            try payload.write(to: fullPart)

            let manager = JournalExportTransferManager(
                platformName: "ios",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: manager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "ios-full-erased",
                "export_id": "exp_full_ios_2",
                "download_path": "/app/export/api/ready/exp_full_ios_2/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: host)

            let failed = try await self.waitForPhase(manager, in: ["error", "saved"])
            XCTAssertEqual(failed.phase, "error")
            XCTAssertEqual(failed.errorCode, "export_invalidated_by_erasure")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("solstone-journal.zip").path))
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    func testAdoptPartialPreservesSourceOnFailedRenameAndNeverDeletesNonRegularItems() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-exp-adopt-safe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let exportID = "exp_ios_adopt_1"
        let preferred = folder.appendingPathComponent(".solstone-export-\(exportID)-2.part")
        let staleRegular = folder.appendingPathComponent(".solstone-export-\(exportID)-1.part")
        let target = folder.appendingPathComponent(".solstone-export-\(exportID)-3.part")
        let matchingDir = folder.appendingPathComponent(".solstone-export-\(exportID)-10.part")
        let externalFile = folder.appendingPathComponent("keep-outside.txt")
        let matchingSymlink = folder.appendingPathComponent(".solstone-export-\(exportID)-9.part")

        let preferredBytes = Data("preferred-partial-bytes".utf8)
        try preferredBytes.write(to: preferred)
        try Data("stale-old".utf8).write(to: staleRegular)
        try FileManager.default.createDirectory(at: matchingDir, withIntermediateDirectories: true)
        try Data("outside-sentinel".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(at: matchingSymlink, withDestinationURL: externalFile)

        let adopted = JournalExportTransferManager.adoptOrCleanExistingPartials(
            in: folder,
            exportID: exportID,
            preferredSource: preferred,
            targetPartURL: target,
            renameFile: { _, _ in false }
        )

        XCTAssertEqual(adopted.lastPathComponent, preferred.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: preferred), preferredBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRegular.path))
        var dirStat = stat()
        XCTAssertTrue(matchingDir.path.withCString { Darwin.lstat($0, &dirStat) } == 0 && (dirStat.st_mode & S_IFMT) == S_IFDIR)
        var linkStat = stat()
        XCTAssertTrue(matchingSymlink.path.withCString { Darwin.lstat($0, &linkStat) } == 0 && (linkStat.st_mode & S_IFMT) == S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: externalFile), Data("outside-sentinel".utf8))
    }

    func testFolderPickerPresentsDocumentPickerAndRoutesPickAndCancel() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let chosenFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-picker-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosenFolder) }

        // 1. Accept path: real UIDocumentPickerViewController presented over rootVC delivers chosen folder.
        let picker = JournalExportFolderPicker()
        let pickTask = Task { @MainActor in
            await picker.present(over: rootVC)
        }
        var presented: UIDocumentPickerViewController?
        for _ in 0..<40 {
            if let vc = rootVC.presentedViewController as? UIDocumentPickerViewController {
                presented = vc
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let docPicker = try XCTUnwrap(presented, "expected UIDocumentPickerViewController to be presented")
        XCTAssertFalse(docPicker.allowsMultipleSelection)
        picker.documentPicker(docPicker, didPickDocumentsAt: [chosenFolder])
        let pickedURL = await pickTask.value
        XCTAssertEqual(pickedURL, chosenFolder)
        docPicker.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(50))

        // 2. Cancel path: cancelling the real document picker returns nil cleanly.
        let picker2 = JournalExportFolderPicker()
        let cancelTask = Task { @MainActor in
            await picker2.present(over: rootVC)
        }
        var presented2: UIDocumentPickerViewController?
        for _ in 0..<40 {
            if let vc = rootVC.presentedViewController as? UIDocumentPickerViewController {
                presented2 = vc
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let docPicker2 = try XCTUnwrap(presented2, "expected second UIDocumentPickerViewController to be presented")
        picker2.documentPickerWasCancelled(docPicker2)
        let cancelledURL = await cancelTask.value
        XCTAssertNil(cancelledURL)
        docPicker2.dismiss(animated: false)
    }

    func testFullLengthPartialHandlesRangeIgnoring200ForSameChangedAndAbsentETag() async throws {
        // 1. 16 MiB valid full partial + Range-ignoring 200 with SAME strong ETag:
        //    body cancelled at headers, local SHA-256 verified, published under 1 MiB headroom.
        do {
            let size = 16 * 1024 * 1024
            let payload = Self.makeSyntheticData(count: size, mul: 59, add: 17)
            let expectedSHA = Self.sha256Hex(payload)
            let etag = "\"\(expectedSHA)\""
            let server = try IOSLoopbackExportServer(
                payload: payload,
                etag: etag,
                ignoreRangeWithETag: .some(etag)
            )
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-exp-r200-same-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            try payload.write(to: folder.appendingPathComponent(".solstone-export-exp_ios_r200_same-1.part"))

            let manager = JournalExportTransferManager(
                platformName: "ipados",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: manager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "ios-r200-same",
                "export_id": "exp_ios_r200_same",
                "download_path": "/app/export/api/ready/exp_ios_r200_same/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: host)

            let saved = try await self.waitForPhase(manager, in: ["saved", "error"])
            XCTAssertEqual(saved.phase, "saved")
            XCTAssertTrue(saved.verified)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("solstone-journal.zip")), payload)
            let reqs = server.recordedRequests()
            XCTAssertEqual(reqs.count, 1)
            XCTAssertEqual(reqs.first?.range, "bytes=\(size - 1)-\(size - 1)")
            XCTAssertLessThan(server.totalBodyBytesSent(), 1 * 1024 * 1024)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }

        // 2. Corrupt full partial + Range-ignoring 200 with SAME strong ETag:
        //    local SHA-256 still catches corruption, deletes partial, never publishes.
        do {
            let size = 4 * 1024 * 1024
            let payload = Self.makeSyntheticData(count: size, mul: 61, add: 19)
            let expectedSHA = Self.sha256Hex(payload)
            let etag = "\"\(expectedSHA)\""
            var corrupt = payload
            corrupt[1024] ^= 0xFF
            let server = try IOSLoopbackExportServer(
                payload: payload,
                etag: etag,
                ignoreRangeWithETag: .some(etag)
            )
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-exp-r200-corrupt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            try corrupt.write(to: folder.appendingPathComponent(".solstone-export-exp_ios_r200_bad-1.part"))

            let manager = JournalExportTransferManager(
                platformName: "ios",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: manager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "ios-r200-bad",
                "export_id": "exp_ios_r200_bad",
                "download_path": "/app/export/api/ready/exp_ios_r200_bad/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: host)

            let failed = try await self.waitForPhase(manager, in: ["error", "saved"])
            XCTAssertEqual(failed.phase, "error")
            XCTAssertEqual(failed.errorCode, "checksum_mismatch")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("solstone-journal.zip").path))
            XCTAssertLessThan(server.totalBodyBytesSent(), 1 * 1024 * 1024)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }

        // 3. Full partial + Range-ignoring 200 with CHANGED strong ETag or WEAK ETag:
        //    cancelled at headers without downloading full archive, removes partial, fails export_copy_unconfirmed.
        for (label, serverETag) in [
            ("changed", "\"different-export-etag\""),
            ("weak", "W/\"same-weak-etag\""),
        ] {
            let size = 16 * 1024 * 1024
            let payload = Self.makeSyntheticData(count: size, mul: 67, add: 23)
            let expectedSHA = Self.sha256Hex(payload)
            let expectedETag = (label == "weak") ? "\"same-weak-etag\"" : "\"\(expectedSHA)\""
            let server = try IOSLoopbackExportServer(
                payload: payload,
                etag: expectedETag,
                ignoreRangeWithETag: .some(serverETag)
            )
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-exp-r200-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let exportID = "exp_ios_r200_\(label)"
            try payload.write(to: folder.appendingPathComponent(".solstone-export-\(exportID)-2.part"))

            let manager = JournalExportTransferManager(
                platformName: "ipados",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: manager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "ios-r200-\(label)",
                "export_id": exportID,
                "download_path": "/app/export/api/ready/\(exportID)/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": expectedSHA,
                "etag": expectedETag,
            ], to: host)

            let failed = try await self.waitForPhase(manager, in: ["error", "saved"])
            XCTAssertEqual(failed.phase, "error")
            XCTAssertEqual(failed.errorCode, "export_copy_unconfirmed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("solstone-journal.zip").path))
            XCTAssertLessThan(server.totalBodyBytesSent(), 1 * 1024 * 1024)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }

        // 4. Full partial + Range-ignoring 200 with ABSENT ETag:
        //    streams live 200 copy from byte 0, verifies SHA-256, and publishes verified live bytes.
        do {
            let size = 4 * 1024 * 1024
            let payload = Self.makeSyntheticData(count: size, mul: 71, add: 29)
            let expectedSHA = Self.sha256Hex(payload)
            let etag = "\"\(expectedSHA)\""
            var stalePartial = payload
            stalePartial[0] ^= 0xAA
            let server = try IOSLoopbackExportServer(
                payload: payload,
                etag: etag,
                ignoreRangeWithETag: .some(nil)
            )
            defer { server.stop() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-exp-r200-absent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            try stalePartial.write(to: folder.appendingPathComponent(".solstone-export-exp_ios_r200_absent-1.part"))

            let manager = JournalExportTransferManager(
                platformName: "ios",
                prepareRequest: { _ in },
                volumeSpaceProbe: { _ in 1 * 1024 * 1024 }
            )
            let host = try XCTUnwrap(JournalImportHost(
                entryURL: server.baseURL,
                intake: ExportTestFakeIntake(),
                exportTransferManager: manager,
                exportLiveBaseURL: { server.baseURL },
                exportTransportKind: { "local" },
                exportFolderPicker: { folder }
            ))
            _ = try await self.send([
                "type": "export.start",
                "id": "ios-r200-absent",
                "export_id": "exp_ios_r200_absent",
                "download_path": "/app/export/api/ready/exp_ios_r200_absent/download",
                "filename": "solstone-journal.zip",
                "size_bytes": size,
                "sha256": expectedSHA,
                "etag": etag,
            ], to: host)

            let saved = try await self.waitForPhase(manager, in: ["saved", "error"])
            XCTAssertEqual(saved.phase, "saved")
            XCTAssertTrue(saved.verified)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("solstone-journal.zip")), payload)
            XCTAssertEqual(server.totalBodyBytesSent(), size)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".part") } ?? []
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    // MARK: - Helpers

    private func send(_ message: [String: Any], to host: JournalImportHost) async throws -> [String: Any] {
        let envelope: [String: Any] = ["documentId": self.documentID, "message": message]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let replyText = try await host.handle(packet: raw).get()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(replyText.utf8)) as? [String: Any])
    }

    private func waitForPhase(_ manager: JournalExportTransferManager, in targets: Set<String>, timeout: TimeInterval = 10) async throws -> JournalExportStatusSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if targets.contains(manager.snapshot.phase) {
                return manager.snapshot
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for phase in \(targets); last phase was \(manager.snapshot.phase)")
        return manager.snapshot
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class ExportTestFakeIntake: JournalImportIntake {
    func take(_ providers: [any ShareItemProvider], names: [String], handoff: ShareImportHandoff) async -> JournalImportIntakeResult {
        JournalImportIntakeResult()
    }

    func state(of item: UUID) async -> JournalImportItemState {
        .gone
    }
}

@MainActor
private final class SpyExportBgScheduling: FinishSyncingScheduling {
    private(set) var registeredIdentifier: String?
    private(set) var submitIdentifier: String?

    func register(identifier: String, launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void) -> Bool {
        self.registeredIdentifier = identifier
        return true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        self.submitIdentifier = identifier
    }
}

@MainActor
private final class SpyExportBgTaskHandle: FinishSyncingTaskHandle {
    var isCancelled = false
    private(set) var progressTotal = 0
    private(set) var progressCompleted = 0
    private(set) var completedSuccess: Bool?
    private(set) var lastTitle: String?
    private var expirationHandler: (@MainActor () -> Void)?

    func setProgressTotal(_ total: Int) { self.progressTotal = total }
    func setProgressCompleted(_ completed: Int) { self.progressCompleted = completed }
    func updateTitle(_ title: String, subtitle: String) { self.lastTitle = title }
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) { self.expirationHandler = handler }
    func fireExpiration() { self.expirationHandler?() }
    func complete(success: Bool) { self.completedSuccess = success }
}

private struct ImmediateExportBgClock: ObserverClock {
    func now() -> Date { Date() }
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Minimal IPv4 loopback HTTP/1.1 server supporting `Range`, `If-Range`, and deterministic drops.
private final class IOSLoopbackExportServer: @unchecked Sendable {
    struct RequestRecord: Sendable {
        let range: String?
        let ifRange: String?
    }

    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(self.port)")! }

    private let listenFD: Int32
    private let payload: Data
    private let etag: String
    private let response206ETag: String
    private let truncateFirstAttemptAt: Int?
    private let fixedStatus: Int?
    private let fixedBody: Data
    private let ignoreRangeWithETag: String??
    private let state = OSAllocatedUnfairLock(initialState: (stopped: false, attempts: 0, bodyBytesSent: 0, requests: [RequestRecord]()))

    init(
        payload: Data,
        etag: String,
        response206ETag: String? = nil,
        truncateFirstAttemptAt: Int? = nil,
        fixedStatus: Int? = nil,
        fixedBody: Data = Data(),
        ignoreRangeWithETag: String?? = nil
    ) throws {
        self.payload = payload
        self.etag = etag
        self.response206ETag = response206ETag ?? etag
        self.truncateFirstAttemptAt = truncateFirstAttemptAt
        self.fixedStatus = fixedStatus
        self.fixedBody = fixedBody
        self.ignoreRangeWithETag = ignoreRangeWithETag

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        let queue = DispatchQueue(label: "ios.export.test.server", attributes: .concurrent)
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        self.state.withLock { $0.stopped = true }
        Darwin.shutdown(self.listenFD, SHUT_RDWR)
        Darwin.close(self.listenFD)
    }

    func recordedRequests() -> [RequestRecord] {
        self.state.withLock { $0.requests }
    }

    func totalBodyBytesSent() -> Int {
        self.state.withLock { $0.bodyBytesSent }
    }

    private func acceptLoop() {
        while !self.state.withLock({ $0.stopped }) {
            let clientFD = Darwin.accept(self.listenFD, nil, nil)
            if clientFD < 0 { break }
            var noSigPipe: Int32 = 1
            Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleClient(fd: clientFD)
                Darwin.close(clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        var requestData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while requestData.range(of: Data("\r\n\r\n".utf8)) == nil && requestData.count < 32768 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return }
            requestData.append(contentsOf: buf[0..<n])
        }
        guard let text = String(data: requestData, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        let rangeHeader = headers["range"]
        let ifRangeHeader = headers["if-range"]
        let attempt = self.state.withLock { s -> Int in
            s.attempts += 1
            s.requests.append(RequestRecord(range: rangeHeader, ifRange: ifRangeHeader))
            return s.attempts
        }

        if let fixedStatus = self.fixedStatus {
            let head = "HTTP/1.1 \(fixedStatus) Status\r\nContent-Type: application/json\r\nContent-Length: \(self.fixedBody.count)\r\nConnection: close\r\n\r\n"
            Self.writeAll(fd: fd, data: Data(head.utf8))
            Self.writeAll(fd: fd, data: self.fixedBody)
            return
        }

        let total = self.payload.count
        if let ignoreETag = self.ignoreRangeWithETag {
            var sndBuf: Int32 = 65_536
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
            let etagLine = ignoreETag.map { "ETag: \($0)\r\n" } ?? ""
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(total)\r\n\(etagLine)Connection: close\r\n\r\n"
            _ = Self.writeAll(fd: fd, data: Data(head.utf8))
            usleep(20_000)
            let sent = Self.writeAll(fd: fd, data: self.payload)
            self.state.withLock { $0.bodyBytesSent += sent }
            return
        }
        if let range = headers["range"], range.hasPrefix("bytes="), headers["if-range"] == self.etag {
            let spec = range.dropFirst(6)
            let start = Int(spec.split(separator: "-").first ?? "0") ?? 0
            let slice = self.payload[start..<total]
            let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: application/zip\r\nContent-Length: \(slice.count)\r\nContent-Range: bytes \(start)-\(total - 1)/\(total)\r\nETag: \(self.response206ETag)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            _ = Self.writeAll(fd: fd, data: Data(head.utf8))
            let sent = Self.writeAll(fd: fd, data: Data(slice))
            self.state.withLock { $0.bodyBytesSent += sent }
            return
        }

        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(total)\r\nETag: \(self.etag)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        _ = Self.writeAll(fd: fd, data: Data(head.utf8))
        if attempt == 1, let cut = self.truncateFirstAttemptAt, cut < total {
            let sent = Self.writeAll(fd: fd, data: self.payload.prefix(cut))
            self.state.withLock { $0.bodyBytesSent += sent }
        } else {
            let sent = Self.writeAll(fd: fd, data: self.payload)
            self.state.withLock { $0.bodyBytesSent += sent }
        }
    }

    @discardableResult
    private static func writeAll(fd: Int32, data: Data) -> Int {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var sent = 0
            while sent < raw.count {
                let chunkLen = min(65_536, raw.count - sent)
                let n = Darwin.write(fd, base.advanced(by: sent), chunkLen)
                if n <= 0 { break }
                sent += n
            }
            return sent
        }
    }
}
