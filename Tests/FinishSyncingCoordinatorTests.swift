// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import BackgroundTasks
import XCTest

nonisolated final class FinishSyncingCoordinatorTests: XCTestCase {
    @MainActor
    func testCardStateTruthTable() async {
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: false,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: FinishSyncingCoordinator.backlogThreshold,
                isFinishing: false,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .hidden
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: false,
                isSustaining: false,
                isCapable: true,
                backlog: FinishSyncingCoordinator.backlogThreshold,
                isFinishing: false,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .hidden
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: FinishSyncingCoordinator.backlogThreshold - 1,
                isFinishing: false,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .hidden
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: FinishSyncingCoordinator.backlogThreshold,
                isFinishing: false,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .idle
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: true,
                isCapable: true,
                backlog: FinishSyncingCoordinator.backlogThreshold,
                isFinishing: false,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .hidden
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: false,
                backlog: FinishSyncingCoordinator.backlogThreshold,
                isFinishing: false,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .hidden
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: false,
                isConnected: false,
                isSustaining: false,
                isCapable: true,
                backlog: 0,
                isFinishing: true,
                lastOutcome: nil,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .inProgress
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: 0,
                isFinishing: false,
                lastOutcome: .completed,
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .completed
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: 0,
                isFinishing: false,
                lastOutcome: .interrupted(remaining: 3),
                threshold: FinishSyncingCoordinator.backlogThreshold
            ),
            .interrupted(remaining: 3)
        )
    }

    @MainActor
    func testThresholdAndProgressDenominatorUseProvidedTotals() async {
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: 5,
                isFinishing: false,
                lastOutcome: nil,
                threshold: 5
            ),
            .idle
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.cardState(
                isPaired: true,
                isConnected: true,
                isSustaining: false,
                isCapable: true,
                backlog: 4,
                isFinishing: false,
                lastOutcome: nil,
                threshold: 5
            ),
            .hidden
        )

        let totals = FinishSyncingTotalsBox(failed: 3, pending: 4)
        let handle = SpyFinishSyncingTaskHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                totals.failed = 0
                totals.pending = 0
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {},
            scheduling: SpyFinishSyncingScheduling(),
            clock: MockObserverClock()
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(handle.progressTotal, 7)
        XCTAssertEqual(handle.completedSuccess, true)
    }

    @MainActor
    func testProgressMappingUsesRealTotalsDeltas() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 10)
        let counters = FinishSyncingCountersBox()
        let handle = SpyFinishSyncingTaskHandle()
        let clock = MockObserverClock()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                counters.driveCount += 1
                if counters.driveCount == 1 {
                    totals.pending = 6
                } else {
                    totals.pending = 0
                }
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {
                counters.disconnectCount += 1
            },
            scheduling: SpyFinishSyncingScheduling(),
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.runTask(handle)
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(handle.completedHistory, [0, 4])

        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 2)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(handle.completedHistory, [0, 4, 10])
        XCTAssertEqual(handle.completedSuccess, true)
    }

    @MainActor
    func testCompletionSetsSuccessOutcomeAndDoneTitle() async {
        let totals = FinishSyncingTotalsBox(failed: 1, pending: 1)
        let handle = SpyFinishSyncingTaskHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                totals.failed = 0
                totals.pending = 0
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {},
            scheduling: SpyFinishSyncingScheduling(),
            clock: MockObserverClock()
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(handle.completedSuccess, true)
        XCTAssertEqual(coordinator.lastOutcome, .completed)
        XCTAssertEqual(handle.titleUpdates.last?.title, SourceVocabulary.finishSyncingSystemDoneTitle)
    }

    @MainActor
    func testNoForwardProgressGivesOneSettleGraceThenInterruptsWithLiveRemaining() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 3)
        let counters = FinishSyncingCountersBox()
        let handle = SpyFinishSyncingTaskHandle()
        let clock = MockObserverClock()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                counters.driveCount += 1
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {
                counters.disconnectCount += 1
            },
            scheduling: SpyFinishSyncingScheduling(),
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.runTask(handle)
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)
        XCTAssertNil(handle.completedSuccess)
        XCTAssertNil(coordinator.lastOutcome)

        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 2)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertEqual(coordinator.lastOutcome, .interrupted(remaining: 3))
        XCTAssertEqual(totals.snapshot.failed, 0)
        XCTAssertEqual(totals.snapshot.pending, 3)
        XCTAssertEqual(handle.titleUpdates.last?.title, SourceVocabulary.finishSyncingSystemPausedTitle)
    }

    @MainActor
    func testBackoffOnLiveEndpointKeepsTaskRunningInsteadOfInterrupting() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 3)
        let backoff = FinishSyncingBackoffBox(backoffPendingCount: 1, endpointHeld: false)
        let counters = FinishSyncingCountersBox()
        let handle = SpyFinishSyncingTaskHandle()
        let clock = MockObserverClock()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { backoff.snapshot },
            drive: {
                counters.driveCount += 1
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {
                counters.disconnectCount += 1
            },
            scheduling: SpyFinishSyncingScheduling(),
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.runTask(handle)
        }
        await self.drain(until: {
            counters.driveCount == 1 && clock.pendingSleeperCount == 1
        })
        XCTAssertNil(handle.completedSuccess)
        XCTAssertNil(coordinator.lastOutcome)

        clock.advance(by: 1)
        await self.drain(until: {
            counters.driveCount == 2 && clock.pendingSleeperCount == 1
        })
        XCTAssertNil(handle.completedSuccess)
        XCTAssertNil(coordinator.lastOutcome)

        totals.pending = 0
        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 3)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(handle.completedSuccess, true)
        XCTAssertEqual(coordinator.lastOutcome, .completed)
    }

    @MainActor
    func testInFlightNoProgressKeepsTaskRunningUntilTotalsDrain() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 3)
        let inFlight = FinishSyncingInFlightBox(1)
        let counters = FinishSyncingCountersBox()
        let handle = SpyFinishSyncingTaskHandle()
        let clock = MockObserverClock()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { inFlight.value },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                counters.driveCount += 1
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {
                counters.disconnectCount += 1
            },
            scheduling: SpyFinishSyncingScheduling(),
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.runTask(handle)
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)
        XCTAssertNil(handle.completedSuccess)
        XCTAssertNil(coordinator.lastOutcome)

        clock.advance(by: 1)
        await self.drain(until: {
            counters.driveCount == 2 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)
        XCTAssertNil(handle.completedSuccess)
        XCTAssertNil(coordinator.lastOutcome)

        inFlight.value = 0
        totals.pending = 0
        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 3)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(handle.completedSuccess, true)
        XCTAssertEqual(coordinator.lastOutcome, .completed)
    }

    @MainActor
    func testPacingModeRestoresOnCompletionPath() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 1)
        let modes = FinishSyncingPacingModeBox()
        let handle = SpyFinishSyncingTaskHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                totals.pending = 0
            },
            setPacingMode: { mode in
                modes.append(mode)
            },
            isConnected: { true },
            disconnect: {},
            scheduling: SpyFinishSyncingScheduling(),
            clock: MockObserverClock()
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(modes.values, [.finishSyncing, .normal])
        XCTAssertEqual(handle.completedSuccess, true)
    }

    @MainActor
    func testPacingModeRestoresOnExpirationPath() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 1)
        let modes = FinishSyncingPacingModeBox()
        let handle = SpyFinishSyncingTaskHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                handle.fireExpiration()
            },
            setPacingMode: { mode in
                modes.append(mode)
            },
            isConnected: { true },
            disconnect: {},
            scheduling: SpyFinishSyncingScheduling(),
            clock: MockObserverClock()
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(modes.values, [.finishSyncing, .normal])
        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertEqual(coordinator.lastOutcome, .interrupted(remaining: 1))
    }

    @MainActor
    func testExpirationInterruptsWithoutClearingPendingTotals() async {
        let totals = FinishSyncingTotalsBox(failed: 1, pending: 2)
        let handle = SpyFinishSyncingTaskHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                handle.fireExpiration()
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {},
            scheduling: SpyFinishSyncingScheduling(),
            clock: MockObserverClock()
        )

        await coordinator.runTask(handle)

        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertEqual(coordinator.lastOutcome, .interrupted(remaining: 3))
        XCTAssertEqual(totals.snapshot.failed, 1)
        XCTAssertEqual(totals.snapshot.pending, 2)
    }

    @MainActor
    func testAvailabilityHonestyForRegistrationAndSubmitFailures() async {
        let failedScheduling = SpyFinishSyncingScheduling()
        failedScheduling.registerReturn = false
        let registrationCoordinator = FinishSyncingCoordinator(
            totals: { (0, 0) },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {},
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {},
            scheduling: failedScheduling,
            clock: MockObserverClock()
        )

        registrationCoordinator.registerLaunchHandler()

        XCTAssertFalse(registrationCoordinator.isCapable)
        XCTAssertEqual(
            registrationCoordinator.availability,
            .ready
        )

        let submitScheduling = SpyFinishSyncingScheduling()
        submitScheduling.submitError = GenericFinishSyncingSubmitError()
        let submitCoordinator = FinishSyncingCoordinator(
            totals: { (0, 1) },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {},
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {},
            scheduling: submitScheduling,
            clock: MockObserverClock()
        )

        submitCoordinator.submit()

        XCTAssertEqual(
            submitCoordinator.availability,
            .unavailable(reason: SourceVocabulary.finishSyncingUnavailableFallback)
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.unavailableReason(for: .unavailable),
            SourceVocabulary.finishSyncingUnavailableUnavailable
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.unavailableReason(for: .notPermitted),
            SourceVocabulary.finishSyncingUnavailableNotPermitted
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.unavailableReason(for: .tooManyPendingTaskRequests),
            SourceVocabulary.finishSyncingUnavailableTooManyPending
        )
        XCTAssertEqual(
            FinishSyncingCoordinator.unavailableReason(for: .immediateRunIneligible),
            SourceVocabulary.finishSyncingUnavailableImmediateIneligible
        )
    }

    @MainActor
    func testSingularAndPluralCopy() async {
        XCTAssertTrue(SourceVocabulary.finishSyncingCardBody(count: 1).contains("1 segment"))
        XCTAssertTrue(SourceVocabulary.finishSyncingCardBody(count: 2).contains("2 segments"))
        XCTAssertTrue(SourceVocabulary.finishSyncingInterrupted(count: 1).contains("1 still waiting"))
        XCTAssertTrue(SourceVocabulary.finishSyncingInterrupted(count: 2).contains("2 still waiting"))
        XCTAssertTrue(SourceVocabulary.finishSyncingSystemSubtitle(remaining: 1).contains("1 item"))
        XCTAssertTrue(SourceVocabulary.finishSyncingSystemSubtitle(remaining: 2).contains("2 items"))
    }

    @MainActor
    func testSubmitSetsFinishingAndLaunchHandlerRunClearsIt() async {
        let totals = FinishSyncingTotalsBox(failed: 0, pending: 1)
        let scheduling = SpyFinishSyncingScheduling()
        let handle = SpyFinishSyncingTaskHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {
                totals.pending = 0
            },
            setPacingMode: { _ in },
            isConnected: { true },
            disconnect: {},
            scheduling: scheduling,
            clock: MockObserverClock()
        )

        coordinator.registerLaunchHandler()
        coordinator.submit()

        XCTAssertEqual(coordinator.isFinishing, true)
        XCTAssertEqual(scheduling.submitTitle, SourceVocabulary.finishSyncingSystemTitle)
        XCTAssertEqual(scheduling.submitSubtitle, SourceVocabulary.finishSyncingSystemSubtitle(remaining: 1))
        XCTAssertTrue(scheduling.submitIdentifier?.hasPrefix(FinishSyncingCoordinator.taskIdentifierPrefix + ".") == true)

        scheduling.launchHandler?(handle)
        await self.drain(until: { coordinator.isFinishing == false })

        XCTAssertEqual(handle.completedSuccess, true)
        XCTAssertEqual(coordinator.lastOutcome, .completed)
        XCTAssertEqual(coordinator.isFinishing, false)
    }

    @MainActor
    private func drain(until condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
    }

    @MainActor
    private func pendingSleeperCount(in clock: MockObserverClock) -> Int {
        guard let sleepers = Mirror(reflecting: clock).children.first(where: { $0.label == "sleepers" }) else {
            return 0
        }
        return Mirror(reflecting: sleepers.value).children.count
    }
}

@MainActor
private final class FinishSyncingTotalsBox {
    var failed: Int
    var pending: Int

    init(failed: Int, pending: Int) {
        self.failed = failed
        self.pending = pending
    }

    var snapshot: (failed: Int, pending: Int) {
        (failed: self.failed, pending: self.pending)
    }
}

@MainActor
private final class FinishSyncingCountersBox {
    var driveCount = 0
    var disconnectCount = 0
}

@MainActor
private final class FinishSyncingInFlightBox {
    var value: Int

    init(_ value: Int) {
        self.value = value
    }
}

@MainActor
private final class FinishSyncingBackoffBox {
    var backoffPendingCount: Int
    var endpointHeld: Bool

    init(backoffPendingCount: Int, endpointHeld: Bool) {
        self.backoffPendingCount = backoffPendingCount
        self.endpointHeld = endpointHeld
    }

    var snapshot: TransferBackoffStatus {
        TransferBackoffStatus(
            backoffPendingCount: self.backoffPendingCount,
            endpointHeld: self.endpointHeld
        )
    }
}

@MainActor
private final class FinishSyncingPacingModeBox {
    private(set) var values: [TransferPacingMode] = []

    func append(_ mode: TransferPacingMode) {
        self.values.append(mode)
    }
}

@MainActor
private final class SpyFinishSyncingTaskHandle: FinishSyncingTaskHandle {
    var isCancelled = false
    private(set) var progressTotal: Int?
    private(set) var completedHistory: [Int] = []
    private(set) var titleUpdates: [(title: String, subtitle: String)] = []
    private(set) var completedSuccess: Bool?
    private var expirationHandler: (@MainActor () -> Void)?

    func setProgressTotal(_ total: Int) {
        self.progressTotal = total
    }

    func setProgressCompleted(_ completed: Int) {
        self.completedHistory.append(completed)
    }

    func updateTitle(_ title: String, subtitle: String) {
        self.titleUpdates.append((title: title, subtitle: subtitle))
    }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        self.expirationHandler = handler
    }

    func complete(success: Bool) {
        self.completedSuccess = success
    }

    func fireExpiration() {
        self.expirationHandler?()
    }
}

@MainActor
private final class SpyFinishSyncingScheduling: FinishSyncingScheduling {
    var registerReturn = true
    var submitError: Error?
    private(set) var registerIdentifier: String?
    private(set) var launchHandler: (@MainActor (any FinishSyncingTaskHandle) -> Void)?
    private(set) var submitIdentifier: String?
    private(set) var submitTitle: String?
    private(set) var submitSubtitle: String?

    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void
    ) -> Bool {
        self.registerIdentifier = identifier
        self.launchHandler = launchHandler
        return self.registerReturn
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        self.submitIdentifier = identifier
        self.submitTitle = title
        self.submitSubtitle = subtitle
        if let submitError {
            throw submitError
        }
    }
}

private struct GenericFinishSyncingSubmitError: Error {}
