// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

/// A store that answers as scripted and counts every call the check makes.
@MainActor
final class FakeAgeSignalPlatform: AgeSignalPlatform {
    struct Failure: Error {}

    var eligible: Result<Bool, Failure> = .success(true)
    var eligibleFailuresBeforeAnswer = 0
    var category: AgeSignalCategory? = .adultOrUnknown
    var categoryFails = false
    var consentRequired = false
    var adultNotificationRequired = false
    var adultNotificationFails = false
    var acknowledgmentSucceeds = true
    var ratingCode: Int? = 13
    var installedHere = false
    var installedFails = false
    var eligibilityHangs = false
    /// Runs while the check waits on the age prompt.
    var duringPrompt: (@MainActor () async -> Void)?

    private(set) var eligibilityCalls = 0
    private(set) var categoryCalls = 0
    private(set) var consentCalls = 0
    private(set) var adultNotificationCalls = 0
    private(set) var ratingCalls = 0
    private(set) var asks = 0
    private(set) var acknowledgments = 0
    private var continuation: AsyncStream<Bool>.Continuation?

    var totalCalls: Int {
        self.eligibilityCalls + self.categoryCalls + self.consentCalls + self.adultNotificationCalls
            + self.ratingCalls + self.asks + self.acknowledgments
    }

    func isEligible() async throws -> Bool {
        self.eligibilityCalls += 1
        if self.eligibilityHangs { try? await Task.sleep(for: .seconds(3600)) }
        if self.eligibilityCalls <= self.eligibleFailuresBeforeAnswer { throw Failure() }
        return try self.eligible.get()
    }

    func requestCategory() async throws -> AgeSignalCategory? {
        self.categoryCalls += 1
        await self.duringPrompt?()
        if self.categoryFails { throw Failure() }
        return self.category
    }

    func requiresParentalConsentForSignificantChange() async throws -> Bool {
        self.consentCalls += 1
        return self.consentRequired
    }

    func requiresAdultNotificationForSignificantChange() async throws -> Bool {
        self.adultNotificationCalls += 1
        if self.adultNotificationFails { throw Failure() }
        return self.adultNotificationRequired
    }

    func currentRatingCode() async -> Int? {
        self.ratingCalls += 1
        return self.ratingCode
    }

    func installedThisBuild() async throws -> Bool {
        if self.installedFails { throw Failure() }
        return self.installedHere
    }

    func askParent() async throws {
        self.asks += 1
    }

    func parentAnswers() -> AsyncStream<Bool> {
        AsyncStream { self.continuation = $0 }
    }

    func parentAnswers(_ approved: Bool) {
        self.continuation?.yield(approved)
    }

    func acknowledgeSignificantChange() async -> Bool {
        self.acknowledgments += 1
        return self.acknowledgmentSucceeds
    }
}

nonisolated final class AgeSignalTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        self.suiteName = "AgeSignalTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suiteName)?.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    private var store: AgeSignalStore { AgeSignalStore(suiteName: self.suiteName) }
    private var gate: AgeSignalGate { AgeSignalGate(isEnabled: true, store: self.store) }

    @MainActor
    private func check(_ platform: FakeAgeSignalPlatform) -> AgeSignalCheck {
        AgeSignalCheck(platform: platform, store: self.store, pause: { _ in }, deadline: .milliseconds(200))
    }

    // MARK: category

    func testRangesReduceToThreeCategoriesAndNothingFiner() {
        XCTAssertEqual(AgeSignalCategory(lowerBound: nil, upperBound: 12), .under13)
        XCTAssertEqual(AgeSignalCategory(lowerBound: 13, upperBound: 17), .teen)
        XCTAssertEqual(AgeSignalCategory(lowerBound: 13, upperBound: 15), .teen)
        XCTAssertEqual(AgeSignalCategory(lowerBound: 16, upperBound: 17), .teen)
        XCTAssertEqual(AgeSignalCategory(lowerBound: 18, upperBound: nil), .adultOrUnknown)
        // A range that does not settle a side of a gate is no signal, not the stricter guess.
        XCTAssertEqual(AgeSignalCategory(lowerBound: nil, upperBound: 17), .adultOrUnknown)
        XCTAssertEqual(AgeSignalCategory(lowerBound: 13, upperBound: nil), .adultOrUnknown)
        XCTAssertEqual(AgeSignalCategory(lowerBound: nil, upperBound: nil), .adultOrUnknown)
    }

    // MARK: outcome

    @MainActor
    func testNotEligibleAsksForNoAge() async {
        let platform = FakeAgeSignalPlatform()
        platform.eligible = .success(false)
        let outcome = await self.check(platform).run()
        XCTAssertEqual(outcome, .run)
        XCTAssertEqual(platform.categoryCalls, 0)
    }

    @MainActor
    func testAdultDeclinedAndUnderThirteenOutcomes() async {
        let platform = FakeAgeSignalPlatform()
        let adultOutcome = await self.check(platform).run()
        XCTAssertEqual(adultOutcome, .run)
        XCTAssertEqual(platform.adultNotificationCalls, 1)
        XCTAssertEqual(platform.ratingCalls, 0)
        XCTAssertEqual(platform.acknowledgments, 0)
        platform.category = nil
        let declinedOutcome = await self.check(platform).run()
        XCTAssertEqual(declinedOutcome, .run)
        XCTAssertEqual(platform.adultNotificationCalls, 1, "declined sharing skips adult notification")
        platform.category = .under13
        let under13Outcome = await self.check(platform).run()
        XCTAssertEqual(under13Outcome, .stopped)
        XCTAssertEqual(platform.consentCalls, 0, "only a teen's answer leads to the consent question")
        XCTAssertEqual(platform.adultNotificationCalls, 1, "under 13 skips adult notification")
    }

    @MainActor
    func testAnAdultSeesOneTimeAcknowledgmentForAnUnacknowledgedRatingChange() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .adultOrUnknown
        platform.adultNotificationRequired = true
        platform.installedHere = false

        let first = await self.check(platform).run()
        XCTAssertEqual(first, .run)
        XCTAssertEqual(platform.acknowledgments, 1)
        XCTAssertEqual(self.store.approvedRatingCode(), 13)
        let kept = UserDefaults(suiteName: self.suiteName)?.persistentDomain(forName: self.suiteName) ?? [:]
        XCTAssertEqual(kept.count, 1, "only the rating code is kept, never an age or outcome")
        XCTAssertEqual(kept[AgeSignalStore.approvedRatingKey] as? Int, 13)

        let second = await self.check(platform).run()
        XCTAssertEqual(second, .run)
        XCTAssertEqual(platform.acknowledgments, 1, "already acknowledged rating is not shown again")

        platform.ratingCode = 16
        let changed = await self.check(platform).run()
        XCTAssertEqual(changed, .run)
        XCTAssertEqual(platform.acknowledgments, 2, "a later rating change asks for acknowledgment again")
        XCTAssertEqual(self.store.approvedRatingCode(), 16)
    }

    @MainActor
    func testAnAdultOnAFirstInstallOfThisBuildBaselinesWithoutAcknowledgment() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .adultOrUnknown
        platform.adultNotificationRequired = true
        platform.installedHere = true

        let outcome = await self.check(platform).run()
        XCTAssertEqual(outcome, .run)
        XCTAssertEqual(platform.acknowledgments, 0)
        XCTAssertEqual(self.store.approvedRatingCode(), 13)
    }

    @MainActor
    func testFailedAdultAcknowledgmentDoesNotBlockOrRecordCompletion() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .adultOrUnknown
        platform.adultNotificationRequired = true
        platform.installedHere = false
        platform.acknowledgmentSucceeds = false

        let first = await self.check(platform).run()
        XCTAssertEqual(first, .run, "a failed or unavailable acknowledgment never blocks")
        XCTAssertEqual(platform.acknowledgments, 1)
        XCTAssertNil(self.store.approvedRatingCode())

        platform.acknowledgmentSucceeds = true
        let next = await self.check(platform).run()
        XCTAssertEqual(next, .run)
        XCTAssertEqual(platform.acknowledgments, 2)
        XCTAssertEqual(self.store.approvedRatingCode(), 13)
    }

    @MainActor
    func testAdultNotificationFailureRetriesAndUnavailableRatingSkipsAcknowledgment() async {
        let failing = FakeAgeSignalPlatform()
        failing.category = .adultOrUnknown
        failing.adultNotificationFails = true
        let afterRetries = await self.check(failing).run()
        XCTAssertEqual(afterRetries, .run)
        XCTAssertEqual(failing.adultNotificationCalls, 3)
        XCTAssertEqual(failing.acknowledgments, 0)

        let noRating = FakeAgeSignalPlatform()
        noRating.category = .adultOrUnknown
        noRating.adultNotificationRequired = true
        noRating.ratingCode = nil
        let skipped = await self.check(noRating).run()
        XCTAssertEqual(skipped, .run)
        XCTAssertEqual(noRating.acknowledgments, 0)
        XCTAssertNil(self.store.approvedRatingCode())
    }

    @MainActor
    func testATeenRunsWithNoConsentRule() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .teen
        let outcome = await self.check(platform).run()
        XCTAssertEqual(outcome, .run)
        XCTAssertEqual(platform.ratingCalls, 0)
        XCTAssertEqual(platform.asks, 0)
    }

    @MainActor
    func testATeenOnAnInstallFromAnEarlierRatingIsHeldUntilTheRatingIsApproved() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .teen
        platform.consentRequired = true
        platform.installedHere = false
        let unapproved = await self.check(platform).run()
        XCTAssertEqual(unapproved, .held)
        XCTAssertNil(self.store.approvedRatingCode())

        self.store.saveApprovedRatingCode(13)
        let approved = await self.check(platform).run()
        XCTAssertEqual(approved, .run)

        platform.ratingCode = 16
        let changed = await self.check(platform).run()
        XCTAssertEqual(changed, .held, "any later rating change needs approval again")
    }

    @MainActor
    func testAFirstInstallOfThisBuildRunsAndRecordsItsRatingAsTheBaseline() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .teen
        platform.consentRequired = true
        platform.installedHere = true
        let outcome = await self.check(platform).run()
        XCTAssertEqual(outcome, .run)
        XCTAssertEqual(self.store.approvedRatingCode(), 13)
    }

    @MainActor
    func testUnavailableRatingOrInstallRecordSettlesNothing() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .teen
        platform.consentRequired = true
        platform.ratingCode = nil
        let noRating = await self.check(platform).run()
        XCTAssertEqual(noRating, .run, "with no rating, nothing shows a change")
        platform.ratingCode = 13
        platform.installedFails = true
        let noInstallRecord = await self.check(platform).run()
        XCTAssertEqual(noInstallRecord, .run, "an install record that cannot be read is an error: the app runs")
        XCTAssertNil(self.store.approvedRatingCode())
    }

    // MARK: retry bound

    @MainActor
    func testErrorsRetryThreeTimesThenTheAppCarriesOn() async {
        let platform = FakeAgeSignalPlatform()
        platform.eligible = .failure(FakeAgeSignalPlatform.Failure())
        let outcome = await self.check(platform).run()
        XCTAssertEqual(outcome, .run)
        XCTAssertEqual(platform.eligibilityCalls, 3)

        let flaky = FakeAgeSignalPlatform()
        flaky.eligibleFailuresBeforeAnswer = 2
        flaky.category = .under13
        let recovered = await self.check(flaky).run()
        XCTAssertEqual(recovered, .stopped, "a third try that answers is used")

        let failingAnswer = FakeAgeSignalPlatform()
        failingAnswer.categoryFails = true
        let unanswered = await self.check(failingAnswer).run()
        XCTAssertEqual(unanswered, .run)
        XCTAssertEqual(failingAnswer.categoryCalls, 3)
    }

    @MainActor
    func testAnErrorAfterItsRetriesClearsAnEarlierStopOrHold() async {
        for earlier in [AgeSignalOutcome.stopped, .held] {
            self.store.saveOutcome(earlier)
            let platform = FakeAgeSignalPlatform()
            platform.eligible = .failure(FakeAgeSignalPlatform.Failure())
            let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
            XCTAssertEqual(model.presentation, earlier == .stopped ? .stopped : .held)
            await model.check()
            XCTAssertEqual(model.presentation, .content)
            XCTAssertEqual(self.store.outcome(), .run)
            XCTAssertTrue(self.gate.allowsActivity())
        }
    }

    @MainActor
    func testACallThatNeverReturnsCountsAsAnErrorAfterItsDeadline() async {
        let platform = FakeAgeSignalPlatform()
        platform.eligibilityHangs = true
        let outcome = await self.check(platform).run()
        XCTAssertEqual(outcome, .run)
        XCTAssertEqual(platform.eligibilityCalls, 3)
    }

    @MainActor
    func testRetriesPauseBetweenTriesNotAfterTheLast() async {
        let pauses = PauseLog()
        let platform = FakeAgeSignalPlatform()
        platform.eligible = .failure(FakeAgeSignalPlatform.Failure())
        _ = await AgeSignalCheck(platform: platform, store: self.store, pause: { await pauses.note($0) }, deadline: .seconds(1)).run()
        let noted = await pauses.durations
        XCTAssertEqual(noted, [.seconds(1), .seconds(2)])
    }

    // MARK: persistence

    @MainActor
    func testOnlyTheDerivedOutcomeIsKeptAndRunKeepsNothing() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .under13
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        await model.check()
        let kept = UserDefaults(suiteName: self.suiteName)?.persistentDomain(forName: self.suiteName) ?? [:]
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[AgeSignalStore.outcomeKey] as? String, "stopped")

        platform.category = .adultOrUnknown
        await model.check()
        let afterRun = UserDefaults(suiteName: self.suiteName)?.persistentDomain(forName: self.suiteName) ?? [:]
        XCTAssertTrue(afterRun.isEmpty)
    }

    @MainActor
    func testAFreshProcessReadsTheKeptOutcome() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .under13
        let first = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        await first.check()

        // What a process iOS starts later sees, before any check of its own.
        let gate = AgeSignalGate(isEnabled: true, store: AgeSignalStore(suiteName: self.suiteName))
        XCTAssertFalse(gate.allowsActivity())
        let next = AgeSignalModel(gate: gate, platform: { FakeAgeSignalPlatform() }, pause: { _ in })
        XCTAssertEqual(next.presentation, .stopped)
        XCTAssertFalse(next.allowsActivity)
    }

    // MARK: flag off

    @MainActor
    func testWithTheCheckOffNothingIsAskedAndNothingChanges() async {
        self.store.saveOutcome(.stopped)
        let platform = FakeAgeSignalPlatform()
        let gate = AgeSignalGate(isEnabled: false, store: self.store)
        let model = AgeSignalModel(gate: gate, platform: { platform }, pause: { _ in })
        XCTAssertEqual(model.presentation, .content)
        XCTAssertNil(model.scenePhaseChanged(.active))
        await model.check()
        XCTAssertEqual(platform.totalCalls, 0)
        XCTAssertTrue(gate.allowsActivity(), "a left-over outcome does nothing while the check is off")
        XCTAssertEqual(model.presentation, .content)
    }

#if !SOLSTONE_AGE_SIGNAL
    /// What every build cut from main runs: no check, the content as before.
    @MainActor
    func testTheShippedSettingCarriesNoCheck() {
        XCTAssertFalse(AgeSignalBuild.isEnabled)
        XCTAssertEqual(AgeSignalModel.live().presentation, .content)
        XCTAssertTrue(AgeSignalGate.live.allowsActivity())
    }
#endif

    // MARK: launch and hold

    @MainActor
    func testLeavingDuringTheCheckDoesNotLetTheContentIn() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .under13
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        platform.duringPrompt = { model.scenePhaseChanged(.background) }
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .stopped)
    }

    @MainActor
    func testAnApprovalDuringACheckStands() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .teen
        platform.consentRequired = true
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .held)
        // The parent approves while a foreground re-check is still asking.
        platform.duringPrompt = {
            platform.parentAnswers(true)
            await Self.settle { model.presentation == .content }
        }
        model.scenePhaseChanged(.background)
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .content)
        XCTAssertEqual(self.store.outcome(), .run)
    }

    @MainActor
    func testContentWaitsForTheFirstForegroundCheck() async {
        let platform = FakeAgeSignalPlatform()
        var blocked = 0
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        model.onBlocked = { blocked += 1 }
        XCTAssertEqual(model.presentation, .waiting)
        XCTAssertFalse(model.allowsActivity)
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .content)
        XCTAssertEqual(blocked, 0)
        XCTAssertNil(model.scenePhaseChanged(.active), "asked once per launch")
    }

    @MainActor
    func testABackgroundLaunchKeepsWhatTheLastCheckAllowed() async {
        let platform = FakeAgeSignalPlatform()
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        model.scenePhaseChanged(.background)
        XCTAssertEqual(model.presentation, .content)
        XCTAssertEqual(platform.totalCalls, 0)

        self.store.saveOutcome(.stopped)
        let stopped = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        stopped.scenePhaseChanged(.background)
        XCTAssertEqual(stopped.presentation, .stopped)
        XCTAssertEqual(platform.totalCalls, 0)
    }

    @MainActor
    func testUnderThirteenStopsWhatIsRunning() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .under13
        var blocked = 0
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        model.onBlocked = { blocked += 1 }
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .stopped)
        XCTAssertEqual(blocked, 1)
        XCTAssertFalse(self.gate.allowsActivity())
        XCTAssertNil(model.scenePhaseChanged(.active), "under 13 is asked again at the next launch")
    }

    @MainActor
    func testTheHoldAsksOnceThenWaitsForTheParentAndApprovalResumes() async {
        let platform = FakeAgeSignalPlatform()
        platform.category = .teen
        platform.consentRequired = true
        var blocked = 0
        let model = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        model.onBlocked = { blocked += 1 }
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .held)
        XCTAssertEqual(platform.asks, 1)
        XCTAssertEqual(blocked, 1)
        XCTAssertEqual(self.store.outcome(), .held)

        // Pending: a system sheet does not re-ask; coming back from the background re-checks
        // and stays held without asking on its own.
        XCTAssertNil(model.scenePhaseChanged(.active))
        model.scenePhaseChanged(.background)
        await model.scenePhaseChanged(.active)?.value
        XCTAssertEqual(model.presentation, .held)
        XCTAssertEqual(platform.asks, 1)

        await model.askAgain()
        XCTAssertEqual(platform.asks, 2)

        platform.parentAnswers(false)
        await Self.settle { false }
        XCTAssertEqual(model.presentation, .held, "a decline keeps the hold")

        platform.parentAnswers(true)
        await Self.settle { model.presentation == .content }
        XCTAssertEqual(model.presentation, .content)
        XCTAssertEqual(self.store.outcome(), .run)
        XCTAssertEqual(self.store.approvedRatingCode(), 13)

        // The approval holds for the next launch.
        let next = AgeSignalModel(gate: self.gate, platform: { platform }, pause: { _ in })
        await next.scenePhaseChanged(.active)?.value
        XCTAssertEqual(next.presentation, .content)
    }

    /// Lets queued work run until `done`, for at most about a second.
    @MainActor
    private static func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor PauseLog {
    private(set) var durations: [Duration] = []
    func note(_ duration: Duration) { self.durations.append(duration) }
}
