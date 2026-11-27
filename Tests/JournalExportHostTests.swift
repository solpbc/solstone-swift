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
    private let state = OSAllocatedUnfairLock(initialState: (stopped: false, attempts: 0, requests: [RequestRecord]()))

    init(
        payload: Data,
        etag: String,
        response206ETag: String? = nil,
        truncateFirstAttemptAt: Int? = nil,
        fixedStatus: Int? = nil,
        fixedBody: Data = Data()
    ) throws {
        self.payload = payload
        self.etag = etag
        self.response206ETag = response206ETag ?? etag
        self.truncateFirstAttemptAt = truncateFirstAttemptAt
        self.fixedStatus = fixedStatus
        self.fixedBody = fixedBody

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

    private func acceptLoop() {
        while !self.state.withLock({ $0.stopped }) {
            let clientFD = Darwin.accept(self.listenFD, nil, nil)
            if clientFD < 0 { break }
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
        if let range = headers["range"], range.hasPrefix("bytes="), headers["if-range"] == self.etag {
            let spec = range.dropFirst(6)
            let start = Int(spec.split(separator: "-").first ?? "0") ?? 0
            let slice = self.payload[start..<total]
            let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: application/zip\r\nContent-Length: \(slice.count)\r\nContent-Range: bytes \(start)-\(total - 1)/\(total)\r\nETag: \(self.response206ETag)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            Self.writeAll(fd: fd, data: Data(head.utf8))
            Self.writeAll(fd: fd, data: Data(slice))
            return
        }

        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(total)\r\nETag: \(self.etag)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        Self.writeAll(fd: fd, data: Data(head.utf8))
        if attempt == 1, let cut = self.truncateFirstAttemptAt, cut < total {
            Self.writeAll(fd: fd, data: self.payload.prefix(cut))
        } else {
            Self.writeAll(fd: fd, data: self.payload)
        }
    }

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
