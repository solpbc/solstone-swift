// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class LaunchMaintenanceCoordinatorTests: XCTestCase {
    private let mobileKey = "didMigrateLegacyMobileSegmentsV1"
    private let audioKey = "didMigrateLegacyAudioSegmentKeysV1"

    func testForegroundPassRunsAllEightOpsInOrder() async throws {
        let harness = try self.makeHarness()

        await harness.coordinator.runForegroundMaintenance()

        XCTAssertEqual(harness.log.entries, Self.migrationExpectedOrder)
        XCTAssertTrue(harness.defaults.bool(forKey: self.mobileKey))
        XCTAssertTrue(harness.defaults.bool(forKey: self.audioKey))

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertEqual(harness.log.entries, Self.migrationExpectedOrder)
    }

    func testCompletedPassDoesNotRerunOnRepeatForeground() async throws {
        let harness = try self.makeHarness()

        await harness.coordinator.runForegroundMaintenance()
        await harness.coordinator.runForegroundMaintenance()

        XCTAssertEqual(harness.log.entries, Self.migrationExpectedOrder)
    }

    func testCancelledCallerDoesNotStartPass() async throws {
        let harness = try self.makeHarness()

        let task = Task { @MainActor in
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            await harness.coordinator.runForegroundMaintenance()
        }
        await task.value

        XCTAssertEqual(harness.log.entries, [])
    }

    func testConcurrentForegroundRequestsCoalesceToSinglePass() async throws {
        let blocker = ControlledLaunchMaintenanceOperation()
        let harness = try self.makeHarness(blockers: ["resumeImport": blocker])

        let first = Task { @MainActor in
            await harness.coordinator.runForegroundMaintenance()
        }
        await self.drain(until: { blocker.pendingReleaseCount == 1 })

        let second = Task { @MainActor in
            await harness.coordinator.runForegroundMaintenance()
        }
        await self.yield(times: 20)
        XCTAssertEqual(harness.log.count(of: "resumeImport"), 1)

        blocker.releaseNext()
        await first.value
        await second.value

        XCTAssertEqual(harness.log.entries, Self.migrationExpectedOrder)
    }

    func testForegroundRequestDuringCancelledPassRetriesAfterJoin() async throws {
        let blocker = ControlledLaunchMaintenanceOperation()
        let harness = try self.makeHarness(blockers: ["resumeImport": blocker])

        let first = Task { @MainActor in
            await harness.coordinator.runForegroundMaintenance()
        }
        await self.drain(until: { blocker.pendingReleaseCount == 1 })

        harness.coordinator.cancel()
        let second = Task { @MainActor in
            await harness.coordinator.runForegroundMaintenance()
        }
        await self.yield(times: 20)
        XCTAssertEqual(harness.log.count(of: "resumeImport"), 1)

        blocker.releaseNext()
        await self.drain(until: { blocker.pendingReleaseCount == 1 })
        XCTAssertEqual(harness.log.count(of: "resumeImport"), 2)

        blocker.releaseNext()
        await first.value
        await second.value

        XCTAssertEqual(harness.log.entries, [
            "ingestKey",
            "startScreencast",
            "reconcile:launch",
            "resumeImport",
        ] + Self.migrationExpectedOrder)
        XCTAssertTrue(harness.defaults.bool(forKey: self.mobileKey))
        XCTAssertTrue(harness.defaults.bool(forKey: self.audioKey))
    }

    func testBestEffortOneFailingOpDoesNotBlockLaterOps() async throws {
        let harness = try self.makeHarness(failures: ["resumeImport"])

        await harness.coordinator.runForegroundMaintenance()

        XCTAssertTrue(harness.log.entries.contains("resumeImport"))
        XCTAssertTrue(harness.log.entries.contains("migrateMobile"))
        XCTAssertTrue(harness.log.entries.contains("migrateAudio"))
        XCTAssertTrue(harness.log.entries.contains("drainWatch"))
        XCTAssertTrue(harness.log.entries.contains("stale"))
        XCTAssertTrue(harness.defaults.bool(forKey: self.mobileKey))
        XCTAssertTrue(harness.defaults.bool(forKey: self.audioKey))
    }

    func testResumeImportQueueOperationAdoptsStagedShareImportWithoutExtensionEngineCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchShareAdoptionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = ShareImportStore(cacheRootURL: tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true))
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000050001")!
        _ = try ShareImportLegacyTestSupport.writeLegacyItem(
            root: store.cacheRootURL,
            itemID: itemID,
            source: "quick",
            raw: Data("launch share".utf8),
            contentType: "text/plain",
            requestFilename: "text.txt",
            originalFilename: "note.txt"
        )
        let transfer = makeTransferCutoverHarness(
            rootURL: tempDirectory.appendingPathComponent("Transfers", isDirectory: true),
            endpointResolver: TransferEndpointResolverStub(.unavailable("waiting")),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        try await transfer.engine.start()
        let log = LaunchMaintenanceLogBox()
        let defaults = try self.makeDefaults()
        let coordinator = LaunchMaintenanceCoordinator(
            defaults: defaults,
            operations: LaunchMaintenanceCoordinator.Operations(
                migrateIngestKeyAccessibility: { log.append("ingestKey") },
                startScreencastObserving: { log.append("startScreencast") },
                reconcileScreencast: { log.append("reconcile:\($0.rawValue)") },
                resumeImportQueue: {
                    log.append("resumeImport")
                    await resumeShareImports(
                        shareImportStore: store,
                        transferEngine: transfer.engine,
                        diagnosticLog: nil
                    )
                },
                migrateLegacyMobileItems: { log.append("migrateMobile") },
                resumeMobileSegments: { log.append("resumeMobile") },
                migrateLegacyAudioKeys: { log.append("migrateAudio") },
                replayWatchACKs: { log.append("replayWatchACKs") },
                drainWatch: { log.append("drainWatch") },
                endStaleObserverActivitiesIfIdle: { log.append("stale") }
            )
        )

        await coordinator.runForegroundMaintenance()

        let snapshot = await transfer.engine.itemSnapshot(itemID: itemID)
        XCTAssertEqual(snapshot?.sourceKey, ObserverAudioTransferSource.share)
        XCTAssertEqual(snapshot?.state, .queued)
        XCTAssertTrue(log.entries.contains("resumeImport"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShareImportLegacyTestSupport.itemDirectory(
            root: store.cacheRootURL,
            status: "pending",
            itemID: itemID
        ).path))
    }

    func testMobileFlagNotSetWhenMigrationThrows() async throws {
        let harness = try self.makeHarness(failures: ["migrateMobile"])

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertFalse(harness.defaults.bool(forKey: self.mobileKey))
        XCTAssertEqual(harness.log.count(of: "migrateMobile"), 1)

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertEqual(harness.log.count(of: "migrateMobile"), 2)
        XCTAssertFalse(harness.defaults.bool(forKey: self.mobileKey))
    }

    func testAudioFlagNotSetWhenMigrationThrows() async throws {
        let harness = try self.makeHarness(failures: ["migrateAudio"])

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertFalse(harness.defaults.bool(forKey: self.audioKey))
        XCTAssertEqual(harness.log.count(of: "migrateAudio"), 1)

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertEqual(harness.log.count(of: "migrateAudio"), 2)
        XCTAssertFalse(harness.defaults.bool(forKey: self.audioKey))
    }

    func testMobileFlagNotSetWhenCancelledMidMigration() async throws {
        let cancelBox = LaunchMaintenanceCancelOnceBox()
        let harness = try self.makeHarness(cancelLabels: ["migrateMobile"], cancelBox: cancelBox)
        cancelBox.cancel = { harness.coordinator.cancel() }

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertFalse(harness.defaults.bool(forKey: self.mobileKey))
        XCTAssertEqual(harness.log.count(of: "migrateMobile"), 1)

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertEqual(harness.log.count(of: "migrateMobile"), 2)
        XCTAssertTrue(harness.defaults.bool(forKey: self.mobileKey))
    }

    func testAudioFlagNotSetWhenCancelledMidMigration() async throws {
        let cancelBox = LaunchMaintenanceCancelOnceBox()
        let harness = try self.makeHarness(cancelLabels: ["migrateAudio"], cancelBox: cancelBox)
        cancelBox.cancel = { harness.coordinator.cancel() }

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertFalse(harness.defaults.bool(forKey: self.audioKey))
        XCTAssertEqual(harness.log.count(of: "migrateAudio"), 1)

        await harness.coordinator.runForegroundMaintenance()
        XCTAssertEqual(harness.log.count(of: "migrateAudio"), 2)
        XCTAssertTrue(harness.defaults.bool(forKey: self.audioKey))
    }

    func testAlreadyMigratedTakesResumePathNotMigration() async throws {
        let defaults = try self.makeDefaults()
        defaults.set(true, forKey: self.mobileKey)
        defaults.set(true, forKey: self.audioKey)
        let harness = try self.makeHarness(defaults: defaults)

        await harness.coordinator.runForegroundMaintenance()

        XCTAssertTrue(harness.log.entries.contains("resumeMobile"))
        XCTAssertTrue(harness.log.entries.contains("reconcile:mobileSegmentResume"))
        XCTAssertFalse(harness.log.entries.contains("migrateMobile"))
        XCTAssertFalse(harness.log.entries.contains("migrateAudio"))
    }
}

private extension LaunchMaintenanceCoordinatorTests {
    static let migrationExpectedOrder = [
        "ingestKey",
        "startScreencast",
        "reconcile:launch",
        "resumeImport",
        "migrateMobile",
        "reconcile:mobileSegmentResume",
        "migrateAudio",
        "replayWatchACKs",
        "drainWatch",
        "stale",
    ]

    struct Harness {
        let coordinator: LaunchMaintenanceCoordinator
        let log: LaunchMaintenanceLogBox
        let defaults: UserDefaults
    }

    func makeHarness(
        defaults: UserDefaults? = nil,
        failures: Set<String> = [],
        blockers: [String: ControlledLaunchMaintenanceOperation] = [:],
        cancelLabels: Set<String> = [],
        cancelBox: LaunchMaintenanceCancelOnceBox? = nil
    ) throws -> Harness {
        let defaults = try defaults ?? self.makeDefaults()
        let log = LaunchMaintenanceLogBox()
        let operations = LaunchMaintenanceCoordinator.Operations(
            migrateIngestKeyAccessibility: {
                log.append("ingestKey")
            },
            startScreencastObserving: {
                log.append("startScreencast")
            },
            reconcileScreencast: { reason in
                log.append("reconcile:\(reason.rawValue)")
            },
            resumeImportQueue: {
                try await self.perform(
                    "resumeImport",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            },
            migrateLegacyMobileItems: {
                try await self.perform(
                    "migrateMobile",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            },
            resumeMobileSegments: {
                try await self.perform(
                    "resumeMobile",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            },
            migrateLegacyAudioKeys: {
                try await self.perform(
                    "migrateAudio",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            },
            replayWatchACKs: {
                try await self.perform(
                    "replayWatchACKs",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            },
            drainWatch: {
                try await self.perform(
                    "drainWatch",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            },
            endStaleObserverActivitiesIfIdle: {
                try await self.perform(
                    "stale",
                    log: log,
                    failures: failures,
                    blockers: blockers,
                    cancelLabels: cancelLabels,
                    cancelBox: cancelBox
                )
            }
        )
        return Harness(
            coordinator: LaunchMaintenanceCoordinator(defaults: defaults, operations: operations),
            log: log,
            defaults: defaults
        )
    }

    func perform(
        _ label: String,
        log: LaunchMaintenanceLogBox,
        failures: Set<String>,
        blockers: [String: ControlledLaunchMaintenanceOperation],
        cancelLabels: Set<String>,
        cancelBox: LaunchMaintenanceCancelOnceBox?
    ) async throws {
        log.append(label)
        if let blocker = blockers[label] {
            await blocker.run()
        }
        if cancelLabels.contains(label) {
            cancelBox?.cancelOnce()
            await Task.yield()
        }
        if failures.contains(label) {
            throw LaunchMaintenanceTestError.failed(label)
        }
    }

    func makeDefaults() throws -> UserDefaults {
        let suiteName = "LaunchMaintenanceCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func drain(until condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
        if !condition() {
            XCTFail("Timed out waiting for launch maintenance condition")
        }
    }

    func yield(times: Int) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }
}

private enum LaunchMaintenanceTestError: Error, Equatable {
    case failed(String)
}

@MainActor
private final class LaunchMaintenanceLogBox {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        self.entries.append(entry)
    }

    func count(of entry: String) -> Int {
        self.entries.filter { $0 == entry }.count
    }
}

@MainActor
private final class ControlledLaunchMaintenanceOperation {
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    var pendingReleaseCount: Int {
        self.releaseContinuations.count
    }

    func run() async {
        await withCheckedContinuation { continuation in
            self.releaseContinuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !self.releaseContinuations.isEmpty else {
            XCTFail("No launch maintenance operation is waiting to be released")
            return
        }
        self.releaseContinuations.removeFirst().resume()
    }
}

@MainActor
private final class LaunchMaintenanceCancelOnceBox {
    var cancel: (() -> Void)?
    private var shouldCancel = true

    func cancelOnce() {
        guard self.shouldCancel else { return }
        self.shouldCancel = false
        self.cancel?()
    }
}
