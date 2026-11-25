// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import BackgroundTasks
import Foundation
import os
import XCTest
@testable import solstone_swift

@MainActor
final class ImportBackgroundUploadCoordinatorTests: XCTestCase {
    func testAppInfoPlistDeclaresImportUploadBackgroundIdentifier() throws {
        let info = Bundle(for: ImportBackgroundUploadCoordinator.self)
        let modes = info.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("processing") == true, "UIBackgroundModes must keep processing")
        let permitted = info.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        XCTAssertTrue(
            permitted?.contains(ImportBackgroundUploadCoordinator.taskIdentifierPrefix + ".*") == true,
            "ImportBackgroundUploadCoordinator wildcard identifier must be in BGTaskSchedulerPermittedIdentifiers"
        )
    }

    func testCardStateOfferedForSingleLargeImportWithout25ItemThreshold() {
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                hasLargeImport: true,
                isPairingRefused: false,
                isRunning: false,
                lastOutcome: nil,
                awaitingMarkConfirmation: false
            ),
            .idle
        )
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: true,
                isCapable: true,
                hasLargeImport: true,
                isPairingRefused: false,
                isRunning: false,
                lastOutcome: nil,
                awaitingMarkConfirmation: false
            ),
            .hidden
        )
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                hasLargeImport: true,
                isPairingRefused: true,
                isRunning: false,
                lastOutcome: nil,
                awaitingMarkConfirmation: false
            ),
            .hidden
        )
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                hasLargeImport: true,
                isPairingRefused: false,
                isRunning: false,
                lastOutcome: nil,
                awaitingMarkConfirmation: true
            ),
            .hidden
        )
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: false,
                isSustaining: false,
                isCapable: true,
                hasLargeImport: true,
                isPairingRefused: false,
                isRunning: true,
                lastOutcome: nil,
                awaitingMarkConfirmation: false
            ),
            .inProgress
        )
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: false,
                isSustaining: false,
                isCapable: true,
                hasLargeImport: false,
                isPairingRefused: false,
                isRunning: false,
                lastOutcome: .completed,
                awaitingMarkConfirmation: false
            ),
            .completed
        )
        XCTAssertEqual(
            ImportBackgroundUploadCoordinator.cardState(
                isPaired: true,
                isConnected: false,
                isSustaining: false,
                isCapable: true,
                hasLargeImport: true,
                isPairingRefused: false,
                isRunning: false,
                lastOutcome: .paused,
                awaitingMarkConfirmation: false
            ),
            .paused
        )
    }

    func testProgressUnitsAdvancePerChunkAndNeverPrematurelyReach100Percent() {
        let fourGiB: Int64 = 4_294_967_296
        let chunk: Int64 = 4_194_304
        let u0 = ImportBackgroundUploadCoordinator.progressUnits(bytesSent: 0, bytesTotal: fourGiB)
        let u1 = ImportBackgroundUploadCoordinator.progressUnits(bytesSent: chunk, bytesTotal: fourGiB)
        let u2 = ImportBackgroundUploadCoordinator.progressUnits(bytesSent: chunk * 2, bytesTotal: fourGiB)
        let almost = ImportBackgroundUploadCoordinator.progressUnits(bytesSent: fourGiB - 1, bytesTotal: fourGiB)
        let done = ImportBackgroundUploadCoordinator.progressUnits(bytesSent: fourGiB, bytesTotal: fourGiB)

        XCTAssertEqual(u0.total, 4_194_304)
        XCTAssertEqual(u0.completed, 0)
        XCTAssertEqual(u1.completed, 4_096)
        XCTAssertEqual(u2.completed, 8_192)
        XCTAssertEqual(almost.completed, 4_194_303)
        XCTAssertEqual(done.completed, 4_194_304)
    }

    func testPerChunkProgressObserverTicksSystemTaskProgressAndSubtitles() async {
        let itemID = UUID()
        let total: Int64 = 12_582_912 // 12 MiB
        let chunk: Int64 = 4_194_304
        var pending = 1
        var inFlight = 1
        var currentTarget: ImportBackgroundUploadTarget? = ImportBackgroundUploadTarget(
            itemID: itemID,
            filename: "takeout.zip",
            bytesSent: 0,
            bytesTotal: total,
            phase: .sending
        )
        let scheduling = SpyImportBgScheduling()
        let handle = SpyImportBgTaskHandle()
        var pacingModes: [TransferPacingMode] = []
        var disconnectCalls = 0
        var driveStep = 0

        var coordinatorRef: ImportBackgroundUploadCoordinator?
        let coordinator = ImportBackgroundUploadCoordinator(
            activeTarget: { currentTarget },
            filenameForItem: { $0 == itemID ? "takeout.zip" : nil },
            pendingSendableCount: { pending },
            inFlightCount: { inFlight },
            isPairingRefused: { false },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                driveStep += 1
                switch driveStep {
                case 1:
                    currentTarget = ImportBackgroundUploadTarget(
                        itemID: itemID,
                        filename: "takeout.zip",
                        bytesSent: chunk,
                        bytesTotal: total,
                        phase: .sending
                    )
                    coordinatorRef?.handleResumableProgress(
                        itemID: itemID,
                        progress: TransferResumableProgress(bytesSent: chunk, bytesTotal: total, phase: .sending)
                    )
                case 2:
                    currentTarget = ImportBackgroundUploadTarget(
                        itemID: itemID,
                        filename: "takeout.zip",
                        bytesSent: total,
                        bytesTotal: total,
                        phase: .checking
                    )
                    coordinatorRef?.handleResumableProgress(
                        itemID: itemID,
                        progress: TransferResumableProgress(bytesSent: total, bytesTotal: total, phase: .checking)
                    )
                default:
                    currentTarget = nil
                    inFlight = 0
                    pending = 0
                }
            },
            setPacingMode: { pacingModes.append($0) },
            isConnected: { true },
            shouldDisconnectOnExit: { true },
            disconnect: { disconnectCalls += 1 },
            scheduling: scheduling,
            clock: InstantImportBgClock(),
            settleInterval: .zero
        )
        coordinatorRef = coordinator

        // Submit registers the concrete dynamic identifier (never literal `.*`) and does not
        // claim background sustain until `runTask` actually starts (a783802 invariant).
        coordinator.submit()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(coordinator.isSustainingBackground)
        XCTAssertTrue(scheduling.submitIdentifier?.hasPrefix(ImportBackgroundUploadCoordinator.taskIdentifierPrefix + ".") == true)
        XCTAssertEqual(scheduling.registeredIdentifier, scheduling.submitIdentifier)
        XCTAssertFalse(scheduling.registeredIdentifier?.hasSuffix(".*") == true)

        await coordinator.runTask(handle)

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(coordinator.isSustainingBackground)
        XCTAssertEqual(coordinator.lastOutcome, .completed)
        XCTAssertEqual(handle.completedSuccess, true)
        XCTAssertEqual(pacingModes, [.finishSyncing, .normal])
        XCTAssertEqual(disconnectCalls, 1)
        XCTAssertTrue(handle.completedHistory.contains(4_096))
        XCTAssertTrue(handle.completedHistory.contains(12_288))
        XCTAssertTrue(handle.titleHistory.contains(where: { $0.subtitle == "takeout.zip · checking file" }))
        XCTAssertEqual(handle.titleHistory.last?.title, "finished sending")
    }

    func testBackgroundSustainCoversImportUploadOnlyWhileRunning() async {
        XCTAssertTrue(isBackgroundTunnelSustained(locationSustaining: false, finishSyncingActive: false, importUploadActive: true))
        XCTAssertFalse(isBackgroundTunnelSustained(locationSustaining: false, finishSyncingActive: false, importUploadActive: false))

        var observedSustainingDuringDrive = false
        var pending = 1
        var coordinatorRef: ImportBackgroundUploadCoordinator?
        let handle = SpyImportBgTaskHandle()
        let coordinator = ImportBackgroundUploadCoordinator(
            activeTarget: { nil },
            filenameForItem: { _ in nil },
            pendingSendableCount: { pending },
            inFlightCount: { 0 },
            isPairingRefused: { false },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                observedSustainingDuringDrive = coordinatorRef?.isSustainingBackground ?? false
                pending = 0
            },
            setPacingMode: { _ in },
            isConnected: { true },
            shouldDisconnectOnExit: { false },
            disconnect: { XCTFail("must not disconnect when foregrounded") },
            scheduling: SpyImportBgScheduling(),
            clock: InstantImportBgClock(),
            settleInterval: .zero
        )
        coordinatorRef = coordinator
        await coordinator.runTask(handle)

        XCTAssertTrue(observedSustainingDuringDrive)
        XCTAssertFalse(coordinator.isSustainingBackground)
    }

    func testExpirationPausesCleanlyWithConfirmedBytesAndPreservesItem() async {
        let itemID = UUID()
        let total: Int64 = 100_000_000
        let confirmed: Int64 = 32_000_000
        let handle = SpyImportBgTaskHandle()
        var disconnectCalls = 0

        let coordinator = ImportBackgroundUploadCoordinator(
            activeTarget: {
                ImportBackgroundUploadTarget(
                    itemID: itemID,
                    filename: "archive.zip",
                    bytesSent: confirmed,
                    bytesTotal: total,
                    phase: .sending
                )
            },
            filenameForItem: { _ in "archive.zip" },
            pendingSendableCount: { 1 },
            inFlightCount: { 1 },
            isPairingRefused: { false },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                handle.fireExpiration()
            },
            setPacingMode: { _ in },
            isConnected: { true },
            shouldDisconnectOnExit: { true },
            disconnect: { disconnectCalls += 1 },
            scheduling: SpyImportBgScheduling(),
            clock: InstantImportBgClock(),
            settleInterval: .zero
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(coordinator.lastOutcome, .paused)
        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertFalse(coordinator.isSustainingBackground)
        XCTAssertEqual(disconnectCalls, 1)
        XCTAssertEqual(handle.titleHistory.last?.title, "import paused")
        XCTAssertEqual(
            handle.titleHistory.last?.subtitle,
            "archive.zip · paused at \(ImportByteFormat.bytes(confirmed)) of \(ImportByteFormat.bytes(total))"
        )
    }

    func testTransientDisconnectInsideGraceWindowRecoversAndCompletes() async {
        let itemID = UUID()
        let total: Int64 = 32_000_000
        let clock = StepImportBgClock(start: Date(timeIntervalSince1970: 1_795_520_000), stepSeconds: 2)
        let handle = SpyImportBgTaskHandle()
        var connected = false
        var pending = 1
        var pollCount = 0

        let coordinator = ImportBackgroundUploadCoordinator(
            activeTarget: {
                pending > 0
                    ? ImportBackgroundUploadTarget(
                        itemID: itemID,
                        filename: "export.zip",
                        bytesSent: 16_000_000,
                        bytesTotal: total,
                        phase: connected ? .sending : .paused
                    )
                    : nil
            },
            filenameForItem: { _ in "export.zip" },
            pendingSendableCount: { pending },
            inFlightCount: { pending },
            isPairingRefused: { false },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                pending = 0
            },
            setPacingMode: { _ in },
            isConnected: {
                pollCount += 1
                // Disconnect for 2 ticks (4s), well inside the 30s reconnect grace window.
                if pollCount >= 3 {
                    connected = true
                }
                return connected
            },
            shouldDisconnectOnExit: { false },
            disconnect: {},
            scheduling: SpyImportBgScheduling(),
            clock: clock,
            settleInterval: .zero,
            reconnectGraceTimeout: 30
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(coordinator.lastOutcome, .completed)
        XCTAssertEqual(handle.completedSuccess, true)
        XCTAssertTrue(handle.titleHistory.contains(where: { $0.title == "import paused" }))
        XCTAssertEqual(handle.titleHistory.last?.title, "finished sending")
    }

    func testProlongedDisconnectBeyondGraceTimeoutPausesCleanly() async {
        let itemID = UUID()
        let clock = StepImportBgClock(start: Date(timeIntervalSince1970: 1_795_520_000), stepSeconds: 10)
        let handle = SpyImportBgTaskHandle()

        let coordinator = ImportBackgroundUploadCoordinator(
            activeTarget: {
                ImportBackgroundUploadTarget(
                    itemID: itemID,
                    filename: "export.zip",
                    bytesSent: 16_000_000,
                    bytesTotal: 32_000_000,
                    phase: .paused
                )
            },
            filenameForItem: { _ in "export.zip" },
            pendingSendableCount: { 1 },
            inFlightCount: { 0 },
            isPairingRefused: { false },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {},
            setPacingMode: { _ in },
            isConnected: { false },
            shouldDisconnectOnExit: { true },
            disconnect: {},
            scheduling: SpyImportBgScheduling(),
            clock: clock,
            settleInterval: .zero,
            reconnectGraceTimeout: 20
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(coordinator.lastOutcome, .paused)
        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertEqual(handle.titleHistory.last?.title, "import paused")
    }

    func testDynamicRegistrationFailureMarksUnavailableWithoutSubmitting() {
        let scheduling = SpyImportBgScheduling()
        scheduling.shouldRegister = false
        let coordinator = ImportBackgroundUploadCoordinator(
            activeTarget: { nil },
            filenameForItem: { _ in nil },
            pendingSendableCount: { 1 },
            inFlightCount: { 0 },
            isPairingRefused: { false },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {},
            setPacingMode: { _ in },
            isConnected: { true },
            shouldDisconnectOnExit: { false },
            disconnect: {},
            scheduling: scheduling,
            clock: InstantImportBgClock(),
            settleInterval: .zero
        )

        coordinator.submit()

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(
            coordinator.availability,
            .unavailable(reason: SourceVocabulary.finishSyncingUnavailableNotPermitted)
        )
        XCTAssertNil(scheduling.submitIdentifier)
        XCTAssertTrue(scheduling.registeredIdentifier?.hasPrefix(ImportBackgroundUploadCoordinator.taskIdentifierPrefix + ".") == true)
        XCTAssertFalse(scheduling.registeredIdentifier?.hasSuffix(".*") == true)
    }
}

// MARK: - Spies

@MainActor
private final class SpyImportBgScheduling: FinishSyncingScheduling {
    var shouldRegister = true
    var submitError: (any Error)?
    private(set) var registeredIdentifier: String?
    private(set) var submitIdentifier: String?
    private(set) var submitTitle: String?
    private(set) var submitSubtitle: String?

    func register(identifier: String, launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void) -> Bool {
        self.registeredIdentifier = identifier
        return self.shouldRegister
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        if let submitError { throw submitError }
        self.submitIdentifier = identifier
        self.submitTitle = title
        self.submitSubtitle = subtitle
    }
}

@MainActor
private final class SpyImportBgTaskHandle: FinishSyncingTaskHandle {
    var isCancelled = false
    private(set) var progressTotal = 0
    private(set) var progressCompleted = 0
    private(set) var completedHistory: [Int] = []
    private(set) var titleHistory: [(title: String, subtitle: String)] = []
    private(set) var completedSuccess: Bool?
    private var expirationHandler: (@MainActor () -> Void)?

    func setProgressTotal(_ total: Int) {
        self.progressTotal = total
    }

    func setProgressCompleted(_ completed: Int) {
        self.progressCompleted = completed
        self.completedHistory.append(completed)
    }

    func updateTitle(_ title: String, subtitle: String) {
        self.titleHistory.append((title, subtitle))
    }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        self.expirationHandler = handler
    }

    func fireExpiration() {
        self.expirationHandler?()
    }

    func complete(success: Bool) {
        self.completedSuccess = success
    }
}

private struct InstantImportBgClock: ObserverClock {
    func now() -> Date { Date() }
    func sleep(for duration: Duration) async throws {}
}

private final class StepImportBgClock: ObserverClock, Sendable {
    private let current: OSAllocatedUnfairLock<Date>
    private let stepSeconds: TimeInterval

    init(start: Date, stepSeconds: TimeInterval) {
        self.current = OSAllocatedUnfairLock(initialState: start)
        self.stepSeconds = stepSeconds
    }

    func now() -> Date {
        self.current.withLock { $0 }
    }

    func sleep(for duration: Duration) async throws {
        self.current.withLock { $0 = $0.addingTimeInterval(self.stepSeconds) }
    }
}
