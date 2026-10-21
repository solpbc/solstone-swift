// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

/// Calendar notes through the real transfer engine and spool: the hold until the paired journal
/// lists `calendar_notes`, the journal's answers, the waiting counts, and finish-syncing.
nonisolated final class CalendarDeliveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CalendarIngestURLProtocol.reset()
    }

    override func tearDown() {
        CalendarIngestURLProtocol.reset()
        super.tearDown()
    }

    // MARK: waiting

    @MainActor
    func testWithNoJournalConnectedNotesWaitAndTheWaitingCountIncludesThem() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        rig.resolver.set(.unavailable("waiting"))
        rig.addMeetings(count: 3)
        await rig.harness.setUpAndConfirm()
        try await rig.waitFor("files queued") { rig.holder.pendingCount == 3 }

        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 0)
        XCTAssertEqual(captureUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, calendar: rig.holder).pending, 3)
        XCTAssertEqual(uploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder).pending, 3)
        await rig.holder.refreshNoteCounts()
        XCTAssertEqual(rig.holder.notesWaiting, 3)
        XCTAssertEqual(rig.harness.engine.state.notesWaiting, 3)
        let aggregate = await OnThisPhoneSnapshotAggregator.snapshot(share: rig.share, mobileSegmentUploader: rig.uploader, transferEngine: rig.engine)
        XCTAssertEqual(aggregate.items.filter { $0.sourceKind == .calendar }.count, 3)
        XCTAssertTrue(aggregate.items.filter { $0.sourceKind == .calendar }.allSatisfy { $0.sendState == .savedOnThisPhone })
        XCTAssertEqual(StatusPaneWaitingPresentation.build(
            mobileAggregateCount: 0, audioCount: 0, locationCount: 0, screencastCount: 0, watchCount: 0,
            calendarCount: rig.holder.pendingCount + rig.holder.failedCount
        ).total, 3)
    }

    @MainActor
    func testAnImportWithNoJournalConnectedNeverHasMoreThanTheWindowInTheSpool() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        rig.resolver.set(.unavailable("waiting"))
        rig.addMeetings(count: 8)
        await rig.harness.setUpAndConfirm()
        for _ in 0..<3 {
            rig.harness.engine.foreground()
            await rig.harness.engine.waitUntilIdle()
        }
        let queued = await rig.engine.itemSnapshots(sourceKey: "calendar").count
        XCTAssertEqual(queued, CalendarSourceEngine.Settings().importWindow)
        XCTAssertEqual(rig.harness.engine.setupStep, .importing)

        rig.resolver.set(.available(CalendarDeliveryRig.endpoint(credential: "journal-a")))
        await rig.engine.endpointAvailabilityChanged()
        try await rig.waitFor("the import arrives") {
            rig.harness.engine.setupStep == .on && rig.holder.pendingCount == 0 && rig.holder.deliveredCount == 8
        }
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 8)
        XCTAssertEqual(Set(CalendarIngestURLProtocol.calendarRequests.compactMap(\.fileName)).count, 8)
    }

    @MainActor
    func testNotesWaitWhileThePairedJournalDoesNotListCalendarNotesAndGoOnceItDoes() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["something_else"])
        rig.addMeetings(count: 2)
        await rig.harness.setUpAndConfirm()
        try await rig.waitFor("journal read") { rig.holder.capability == .notListed }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 0)
        XCTAssertTrue(rig.holder.waitingForJournalUpdate)
        XCTAssertTrue(rig.harness.engine.state.waitingForJournalUpdate)
        let snapshot = await rig.engine.snapshot()
        XCTAssertFalse(snapshot.endpointHeld, "the engine as a whole is never held for calendar notes")

        rig.report.set(.read(version: "2.2.0", capabilities: ["calendar_notes"]))
        await rig.gate.journalChanged(identity: "journal-a", version: "2.2.0")
        try await rig.waitFor("calendar files delivered") { rig.holder.deliveredCount == 2 && rig.holder.pendingCount == 0 }
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 2)
        XCTAssertFalse(rig.holder.waitingForJournalUpdate)

        let envelope = try XCTUnwrap(CalendarIngestURLProtocol.calendarRequests.first?.envelope)
        XCTAssertEqual(envelope["source"] as? String, "calendar")
        let file = try XCTUnwrap((envelope["files"] as? [[String: Any]])?.first?["submitted"] as? String)
        XCTAssertTrue(file.range(of: #"^calendar_[0-9a-f]{64}\.jsonl$"#, options: .regularExpression) != nil)
        XCTAssertTrue(((envelope["segment"] as? String) ?? "").hasSuffix("_300"))
        XCTAssertEqual(Set(CalendarIngestURLProtocol.calendarRequests.compactMap(\.fileName)).count, 2)
    }

    @MainActor
    func testNotesQueuedForAJournalThatListsTheCapabilityNeverGoToARePairedJournalThatDoesNot() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        let primed = await rig.prime()
        XCTAssertTrue(primed)
        await rig.engine.pause()
        rig.addMeetings(count: 2)
        await rig.harness.setUpAndConfirm()
        try await rig.waitFor("files queued") { rig.holder.pendingCount == 2 }

        rig.resolver.set(.available(CalendarDeliveryRig.endpoint(credential: "journal-b")))
        rig.report.set(.read(version: "2.0.9", capabilities: []))
        await rig.engine.resume()
        await rig.engine.kick()
        try await rig.waitFor("the new journal was read") { rig.holder.capability == .notListed }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 0)
        XCTAssertTrue(rig.harness.engine.state.waitingForJournalUpdate)
        XCTAssertEqual(rig.holder.pendingCount, 2)
    }

    @MainActor
    func testAFileChosenForOneJournalIsNotSentWhenThePairingChangesBeforeItGoes() async throws {
        let box = CalendarRigBox()
        let rig = try await CalendarDeliveryRig(
            report: .read(version: "2.2.0", capabilities: ["calendar_notes"]),
            bodyBuilder: { item, spool in
                // The pairing changes while the chosen file's body is being built.
                if item.manifest.source == "calendar" {
                    box.repair()
                }
                return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
            }
        )
        box.resolver = rig.resolver
        box.report = rig.report
        rig.addMeetings(count: 1)
        await rig.harness.setUpAndConfirm()
        try await rig.waitFor("the new journal was read") { box.repaired && rig.holder.capability == .notListed }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 0)
        XCTAssertEqual(rig.holder.pendingCount, 1)
        let snapshot = await rig.engine.itemSnapshots(sourceKey: "calendar")
        XCTAssertEqual(snapshot.first?.attempts, 0, "turning a file away is not an attempt")
    }

    @MainActor
    func testTheGateIsAskedAtTheMomentOfSendingForTheEndpointItIsSentTo() async {
        let gate = CalendarCapabilityGate(
            read: { endpoint in
                endpoint.dispatchOwner?.credentialCID == "journal-a"
                    ? .read(version: "2.2.0", capabilities: ["calendar_notes"])
                    : .read(version: "2.0.9", capabilities: [])
            },
            retryDelay: .milliseconds(20)
        )
        let listed = CalendarDeliveryRig.endpoint(credential: "journal-a")
        let other = CalendarDeliveryRig.endpoint(credential: "journal-b")
        let otherSource = await gate.admits(sourceKey: "watch-audio", endpoint: other)
        XCTAssertTrue(otherSource, "other sources are never held")
        let beforeRead = await gate.admits(sourceKey: "calendar", endpoint: listed)
        XCTAssertFalse(beforeRead, "before the first read")
        for _ in 0..<50 {
            if await gate.currentCapability == .listed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let afterRead = await gate.admits(sourceKey: "calendar", endpoint: listed)
        XCTAssertTrue(afterRead)
        let repaired = await gate.admits(sourceKey: "calendar", endpoint: other)
        XCTAssertFalse(repaired, "a different pairing starts again from not known")
        for _ in 0..<50 {
            if await gate.currentCapability == .notListed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let repairedAfterRead = await gate.admits(sourceKey: "calendar", endpoint: other)
        XCTAssertFalse(repairedAfterRead)
        let capability = await gate.currentCapability
        XCTAssertEqual(capability, .notListed)
        let backAgain = await gate.admits(sourceKey: "calendar", endpoint: listed)
        XCTAssertFalse(backAgain, "what an earlier connection said is not trusted")
    }

    @MainActor
    func testAFailedReadIsTriedAgainLaterAndNeverCountsAsNotListed() async throws {
        let report = CalendarReportBox(.failed)
        let gate = CalendarCapabilityGate(read: { _ in report.value }, retryDelay: .milliseconds(300))
        let endpoint = CalendarDeliveryRig.endpoint(credential: "journal-a")
        for _ in 0..<5 {
            _ = await gate.admits(sourceKey: "calendar", endpoint: endpoint)
            try await Task.sleep(for: .milliseconds(20))
        }
        let readsBeforeRetry = await gate.readCount
        XCTAssertEqual(readsBeforeRetry, 1, "a failed read waits for its retry")
        let capability = await gate.currentCapability
        XCTAssertEqual(capability, .unknown)

        report.set(.read(version: "2.2.0", capabilities: ["calendar_notes"]))
        try await Task.sleep(for: .milliseconds(400))
        _ = await gate.admits(sourceKey: "calendar", endpoint: endpoint)
        for _ in 0..<50 {
            if await gate.currentCapability == .listed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reads = await gate.readCount
        XCTAssertEqual(reads, 2)
        let admitted = await gate.admits(sourceKey: "calendar", endpoint: endpoint)
        XCTAssertTrue(admitted)
    }

    @MainActor
    func testAMissingAMalformedOrAFailedCapabilitiesReadHoldsNotesAndTheVersionIsStillRead() async throws {
        let bodies: [(String, Int, String?, JournalStatusReport)] = [
            (#"{"version":{"current":"2.1.0"}}"#, 200, "2.1.0", .read(version: "2.1.0", capabilities: nil)),
            (#"{"version":{"current":"2.1.1"},"capabilities":"calendar_notes"}"#, 200, "2.1.1", .read(version: "2.1.1", capabilities: nil)),
            (#"{"version":{"current":"2.1.2"},"capabilities":[1,"calendar_notes"]}"#, 200, "2.1.2", .read(version: "2.1.2", capabilities: nil)),
            (#"{"version":{"current":"2.1.3"},"capabilities":["calendar_notes"]}"#, 200, "2.1.3", .read(version: "2.1.3", capabilities: ["calendar_notes"])),
            (#"{"error":"down"}"#, 503, nil, .failed),
        ]
        for (body, status, version, expected) in bodies {
            CalendarIngestURLProtocol.statusBody = (status, Data(body.utf8))
            let client = AuthenticatedHomeClient(sessionFactory: { _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [CalendarIngestURLProtocol.self]
                return URLSession(configuration: configuration)
            })
            let fetchedVersion = await client.fetchStatus(localPort: 7071)
            let report = await client.fetchStatusReport(localPort: 7071)
            XCTAssertEqual(fetchedVersion, version, body)
            XCTAssertEqual(report, expected, body)
            XCTAssertEqual(report.lists("calendar_notes"), expected == .read(version: "2.1.3", capabilities: ["calendar_notes"]), body)
        }

        for report in [JournalStatusReport.read(version: "2.1.0", capabilities: nil), .failed] {
            let rig = try await CalendarDeliveryRig(report: report)
            rig.addMeetings(count: 1)
            await rig.harness.setUpAndConfirm()
            try await rig.waitFor("queued") { rig.holder.pendingCount == 1 }
            try await rig.waitFor("read") { await rig.gate.readCount >= 1 }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 0)
            CalendarIngestURLProtocol.reset()
        }
    }

    @MainActor
    func testOnlyASuccessfulReadLackingCalendarNotesReportsWaitingForAJournalUpdate() async throws {
        let rig = try await CalendarDeliveryRig(report: .failed)
        rig.resolver.set(.unavailable("waiting"))
        rig.addMeetings(count: 1)
        await rig.harness.setUpAndConfirm()
        try await rig.waitFor("queued") { rig.holder.pendingCount == 1 }
        XCTAssertFalse(rig.harness.engine.state.waitingForJournalUpdate, "no read yet this connection")
        XCTAssertEqual(rig.holder.heldForJournalCount, 0, "before a read the notes are ordinary waiting")

        rig.resolver.set(.available(CalendarDeliveryRig.endpoint(credential: "journal-a")))
        await rig.engine.kick()
        try await rig.waitFor("failed read") { await rig.gate.readCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.holder.capability, .unknown)
        XCTAssertFalse(rig.harness.engine.state.waitingForJournalUpdate, "a failed read is not a journal without calendar notes")

        XCTAssertEqual(rig.holder.heldForJournalCount, 0)
        rig.report.set(.read(version: "2.0.9", capabilities: ["other"]))
        try await rig.waitFor("read retried") { rig.holder.capability == .notListed }
        XCTAssertTrue(rig.harness.engine.state.waitingForJournalUpdate)
        XCTAssertEqual(rig.holder.heldForJournalCount, 1)
        XCTAssertEqual(sendableUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder).pending, 0)
    }

    // MARK: the journal's answers

    @MainActor
    func testEveryAnswerFromTheJournalIsHandledAsTheContractSays() async throws {
        for answer in ["ok", "duplicate", "collision", "segment_removed", "calendar_note_invalid"] {
            CalendarIngestURLProtocol.reset()
            CalendarIngestURLProtocol.answer = answer
            let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
            rig.addMeetings(count: 1)
            await rig.harness.setUpAndConfirm()
            if answer == "calendar_note_invalid" {
                try await rig.waitFor("refused") { rig.holder.failedCount == 1 }
                XCTAssertEqual(rig.holder.pendingCount, 0, answer)
                let snapshot = await rig.engine.itemSnapshots(sourceKey: "calendar")
                XCTAssertEqual(snapshot.first?.manifest.attention?.journalReasonCode, "calendar_note_invalid")
            } else {
                try await rig.waitFor("settled \(answer)") { rig.holder.pendingCount == 0 && rig.holder.deliveredCount == 1 }
                XCTAssertEqual(rig.holder.failedCount, 0, answer)
            }
            let requests = CalendarIngestURLProtocol.calendarRequests.count
            await rig.engine.kick()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, requests, "\(answer) is not sent again")
        }
    }

    @MainActor
    func testAnImportCarriesOnWhenTheJournalTurnsItsFilesAway() async throws {
        CalendarIngestURLProtocol.answer = "calendar_note_invalid"
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        rig.resolver.set(.unavailable("waiting"))
        rig.addMeetings(count: 7)
        await rig.harness.setUpAndConfirm()
        let queued = await rig.engine.itemSnapshots(sourceKey: "calendar").count
        XCTAssertEqual(queued, 3, "the window is full before the journal answers")
        // Only the refusals free the window now: nothing else asks the import for more.
        rig.resolver.set(.available(CalendarDeliveryRig.endpoint(credential: "journal-a")))
        await rig.engine.endpointAvailabilityChanged()
        try await rig.waitFor("every file was offered and turned away") {
            rig.harness.engine.setupStep == .on && rig.holder.failedCount == 7
        }
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 7)
        XCTAssertEqual(rig.holder.pendingCount, 0)
    }

    @MainActor
    func testLaunchClearsWhatAKillLeftInTheStagingFolder() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        let staging = rig.root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let leftover = staging.appendingPathComponent("\(UUID().uuidString)-calendar_half.jsonl")
        try Data("{\"partial\"".utf8).write(to: leftover)
        await rig.harness.engine.launch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    // MARK: drains

    @MainActor
    func testFinishSyncingWaitsForAnotherSourcesRetryLeavesTheEngineUnheldAndEndsPausedWithCalendarNotesLeft() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: [])
        rig.addMeetings(count: 2)
        await rig.harness.setUpAndConfirm()
        try await rig.waitFor("held for the journal") { rig.holder.capability == .notListed && rig.holder.pendingCount == 2 }

        CalendarIngestURLProtocol.failFirstWatchAttempts = 1
        let watchManifest = ObserverAudioTransferEnqueuer.makeManifest(
            itemID: UUID(),
            source: ObserverAudioTransferSource.watch,
            platform: "watchos",
            createdAt: Date(timeIntervalSinceNow: -3_600),
            segment: "120000_300",
            day: "20261020",
            startedAt: Date(timeIntervalSinceNow: -3_600),
            durationS: 300,
            sources: ["audio"],
            chunkIndex: 0,
            sessionID: UUID(),
            modeRawValue: "meeting",
            segmentID: UUID(),
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        try await rig.engine.enqueue(manifest: watchManifest, payloads: ["audio": Data(repeating: 7, count: 512)])
        try await rig.waitFor("first watch attempt failed") { CalendarIngestURLProtocol.watchRequests >= 1 }
        try await rig.waitFor("the retry is counted") { rig.watch.pendingCount == 1 && rig.mirror.backoffPendingCount == 1 }

        let handle = CalendarFinishSyncingHandle()
        var endpointEverHeld = false
        let coordinator = FinishSyncingCoordinator(
            totals: { sendableUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder) },
            heldTotals: { uploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder) },
            inFlight: { uploadInFlight(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder) },
            backoff: {
                endpointEverHeld = endpointEverHeld || rig.mirror.endpointHeld
                return uploadBackoff(mirror: rig.mirror)
            },
            drive: { await rig.engine.kick() },
            setPacingMode: { await rig.engine.setPacingMode($0) },
            isConnected: { true },
            disconnect: {},
            scheduling: CalendarNoScheduling(),
            settleInterval: .milliseconds(250)
        )
        await coordinator.runTask(handle)

        XCTAssertEqual(rig.watch.pendingCount + rig.watch.failedCount, 0, "finish-syncing waited for the retry")
        XCTAssertGreaterThanOrEqual(CalendarIngestURLProtocol.watchRequests, 2)
        XCTAssertFalse(endpointEverHeld)
        XCTAssertEqual(coordinator.lastOutcome, .interrupted(remaining: 2))
        XCTAssertEqual(handle.completedSuccess, false)
        XCTAssertEqual(CalendarIngestURLProtocol.calendarRequests.count, 0)
    }

    @MainActor
    func testFinishSyncingDoesNotWaitOnImportFilesHeldWhilePausedOrUnreadable() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        rig.resolver.set(.unavailable("waiting"))
        rig.addMeetings(count: 7)
        await rig.harness.setUpAndConfirm()
        rig.harness.engine.pause()
        rig.resolver.set(.available(CalendarDeliveryRig.endpoint(credential: "journal-a")))
        await rig.engine.endpointAvailabilityChanged()
        try await rig.waitFor("the queued files were sent") { rig.holder.deliveredCount == 3 && rig.holder.inFlightCount == 0 }
        XCTAssertEqual(rig.holder.pendingCount, 4, "the rest wait in the source's own store")
        XCTAssertEqual(uploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder).pending, 4)
        XCTAssertEqual(sendableUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder).pending, 0)

        let settle = Duration.seconds(5)
        let handle = CalendarFinishSyncingHandle()
        let coordinator = FinishSyncingCoordinator(
            totals: { sendableUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder) },
            heldTotals: { uploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder) },
            inFlight: { uploadInFlight(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder) },
            backoff: { uploadBackoff(mirror: rig.mirror) },
            drive: { await rig.engine.kick() },
            setPacingMode: { await rig.engine.setPacingMode($0) },
            isConnected: { true },
            disconnect: {},
            scheduling: CalendarNoScheduling(),
            settleInterval: settle
        )
        let started = ContinuousClock.now
        await coordinator.runTask(handle)
        XCTAssertLessThan(ContinuousClock.now - started, settle, "nothing it could send was left to wait on")
        XCTAssertEqual(coordinator.lastOutcome, .interrupted(remaining: 4), "the owner's count keeps them")
        XCTAssertEqual(handle.completedSuccess, false)

        // The same while the calendar cannot be read.
        rig.harness.provider.accessValue = .denied
        await rig.harness.engine.resume()
        XCTAssertEqual(rig.harness.engine.importFilesHeld, 4)
        XCTAssertEqual(sendableUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder).pending, 0)
        rig.harness.provider.accessValue = .full
        XCTAssertEqual(rig.harness.engine.importFilesHeld, 0)
        XCTAssertEqual(sendableUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, share: rig.share, calendar: rig.holder).pending, 4)
    }

    @MainActor
    func testTheIOSConfigurationAsksForFullAccessOnlyAndPermitsTheRefreshTask() throws {
        let info = Bundle(for: CalendarTransferHolder.self)
        XCTAssertNotNil(info.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription"))
        XCTAssertNil(info.object(forInfoDictionaryKey: "NSCalendarsWriteOnlyAccessUsageDescription"))
        let permitted = info.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        XCTAssertTrue(permitted?.contains(CalendarBackgroundRefresh.identifier) == true)
        let modes = info.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("fetch") == true)
    }
}

// MARK: rig

/// The calendar engine over a fake calendar, delivering through a real transfer engine and spool
/// to a stub journal.
@MainActor
final class CalendarDeliveryRig {
    let root: URL
    let harness: CalendarHarness
    let engine: TransferEngine
    let mirror: TransferStatusMirror
    let holder: CalendarTransferHolder
    let gate: CalendarCapabilityGate
    let resolver: CalendarStubResolver
    let report: CalendarReportBox
    let mobile: MobileSegmentTransferHolder
    let watch: WatchUploaderHolder
    let share: ShareTransferHolder
    let uploader: MobileSegmentUploader
    private var nextMeeting = 0

    nonisolated static func endpoint(credential: String) -> TransferResolvedEndpoint {
        TransferResolvedEndpoint(
            baseURL: URL(string: "http://127.0.0.1:7071")!,
            port: 7071,
            dispatchOwner: TransferDispatchOwner(
                pairingGeneration: 1,
                ownerID: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!,
                credentialCID: credential
            )
        )
    }

    convenience init(capabilities: [String]) async throws {
        try await self.init(report: .read(version: "2.1.0", capabilities: capabilities))
    }

    init(report initial: JournalStatusReport, bodyBuilder: TransferBodyBuilder? = nil) async throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarDelivery-\(UUID().uuidString)", isDirectory: true)
        let resolver = CalendarStubResolver(.available(Self.endpoint(credential: "journal-a")))
        let report = CalendarReportBox(initial)
        self.resolver = resolver
        self.report = report
        self.gate = CalendarCapabilityGate(
            read: { _ in report.value },
            isCurrent: { await resolver.isCurrent($0) },
            retryDelay: .milliseconds(100)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarIngestURLProtocol.self]
        self.mirror = TransferStatusMirror()
        self.engine = TransferEngine(
            spool: TransferSpool(rootURL: self.root.appendingPathComponent("Transfers", isDirectory: true)),
            transport: TransferTransport(sessionConfiguration: configuration),
            endpointResolver: resolver,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [1], maxDelay: 300)),
            statusMirror: self.mirror,
            bodyBuilder: bodyBuilder ?? DefaultTransferBodyBuilder.build,
            sourceGate: self.gate
        )
        let holder = CalendarTransferHolder(transferEngine: self.engine, mirror: self.mirror)
        self.holder = holder
        let engine = self.engine
        await self.gate.connect(
            wake: { await engine.kick() },
            publish: { capability in Task { @MainActor in holder.capability = capability } }
        )
        self.uploader = MobileSegmentUploader(
            transferEngine: self.engine,
            store: MobileSegmentStore(rootURL: self.root.appendingPathComponent("mobile", isDirectory: true)),
            clock: MockObserverClock()
        )
        self.mobile = MobileSegmentTransferHolder(transferEngine: self.engine, mirror: self.mirror, uploader: self.uploader)
        self.watch = WatchUploaderHolder(transferEngine: self.engine, mirror: self.mirror)
        self.share = ShareTransferHolder(
            transferEngine: self.engine,
            mirror: self.mirror,
            store: ShareImportStore(cacheRootURL: self.root.appendingPathComponent("share", isDirectory: true))
        )
        self.harness = CalendarHarness(
            now: CalendarFixtures.instant(CalendarSourceEngineTests.start),
            delivery: CalendarTransferDelivery(engine: self.engine, stagingURL: self.root.appendingPathComponent("staging", isDirectory: true)),
            dependencies: { harness in
                CalendarSourceEngine.Dependencies(
                    now: { [weak harness] in harness?.now ?? Date() },
                    timeZone: { [weak harness] in harness?.provider.deviceTimeZone ?? .current },
                    delivery: { (holder.notesWaiting, holder.notesNeedingAttention, holder.waitingForJournalUpdate) },
                    deliveryChanged: { Task { await holder.refreshNoteCounts() } }
                )
            }
        )
        self.harness.provider.addCalendar("cal-work", title: "Work")
        let harness = self.harness
        holder.importFilesNotYetQueued = { [weak harness] in harness?.engine.importFilesNotYetQueued ?? 0 }
        holder.importFilesHeld = { [weak harness] in harness?.engine.importFilesHeld ?? 0 }
        try await self.engine.start()
        await self.engine.registerDeliveredHook(sourceKey: CalendarTransfer.sourceKey) { [weak self] _, _ in
            await MainActor.run {
                self?.harness.engine.deliveryProgressed()
            }
        }
        await self.engine.registerAttentionHook(sourceKey: CalendarTransfer.sourceKey) { [weak self] _ in
            await MainActor.run {
                self?.harness.engine.deliveryProgressed()
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: self.root)
    }

    func addMeetings(count: Int) {
        for _ in 0..<count {
            let index = self.nextMeeting
            self.nextMeeting += 1
            self.harness.provider.events.append(CalendarSourceEngineTests.meeting(
                "DELIVER-\(index)",
                title: "meeting \(index)",
                CalendarFixtures.at(2026, 10, 22 + index, 9, 0),
                lastModified: "2026-10-1\(index)T10:00:00-06:00"
            ))
        }
    }

    /// Reads the capability for the current endpoint once, as a waiting calendar file would.
    func prime() async -> Bool {
        let endpoint = Self.endpoint(credential: "journal-a")
        _ = await self.gate.admits(sourceKey: "calendar", endpoint: endpoint)
        for _ in 0..<100 {
            if await self.gate.currentCapability != .unknown { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await self.gate.currentCapability == .listed
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(label)")
        throw CancellationError()
    }
}

/// Lets a body builder change the pairing mid-send.
nonisolated final class CalendarRigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolver: CalendarStubResolver?
    private var _report: CalendarReportBox?
    private var _repaired = false

    var resolver: CalendarStubResolver? {
        get { self.lock.withLock { self._resolver } }
        set { self.lock.withLock { self._resolver = newValue } }
    }

    var report: CalendarReportBox? {
        get { self.lock.withLock { self._report } }
        set { self.lock.withLock { self._report = newValue } }
    }

    var repaired: Bool {
        self.lock.withLock { self._repaired }
    }

    func repair() {
        self.lock.withLock {
            guard !self._repaired else { return }
            self._repaired = true
            self._resolver?.set(.available(CalendarDeliveryRig.endpoint(credential: "journal-b")))
            self._report?.set(.read(version: "2.0.9", capabilities: []))
        }
    }
}

nonisolated final class CalendarReportBox: Sendable {
    private let state: OSAllocatedUnfairLock<JournalStatusReport>

    init(_ report: JournalStatusReport) {
        self.state = OSAllocatedUnfairLock(initialState: report)
    }

    var value: JournalStatusReport {
        self.state.withLock { $0 }
    }

    func set(_ report: JournalStatusReport) {
        self.state.withLock { $0 = report }
    }
}

nonisolated final class CalendarStubResolver: TransferEndpointResolver, Sendable {
    private let state: OSAllocatedUnfairLock<TransferEndpointResolution>

    init(_ resolution: TransferEndpointResolution) {
        self.state = OSAllocatedUnfairLock(initialState: resolution)
    }

    func set(_ resolution: TransferEndpointResolution) {
        self.state.withLock { $0 = resolution }
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        self.state.withLock { $0 }
    }

    func isCurrent(_ endpoint: TransferResolvedEndpoint) async -> Bool {
        self.state.withLock { $0 } == .available(endpoint)
    }
}

/// A stub journal: answers status reads and ingest uploads, and records what it was sent.
nonisolated final class CalendarIngestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let envelopeData: Data?

        init(body: Data) {
            let text = String(decoding: body, as: UTF8.self)
            if let range = text.range(of: "name=\"envelope\"\r\n\r\n"),
               let end = text[range.upperBound...].range(of: "\r\n--")
            {
                self.envelopeData = Data(text[range.upperBound..<end.lowerBound].utf8)
            } else {
                self.envelopeData = nil
            }
        }

        var envelope: [String: Any]? {
            self.envelopeData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        var fileName: String? {
            (self.envelope?["files"] as? [[String: Any]])?.first?["submitted"] as? String
        }
    }

    private struct State {
        var calendar: [Request] = []
        var watch = 0
        var failWatch = 0
        var answer = "ok"
        var status: (Int, Data) = (200, Data(#"{"version":{"current":"2.1.0"}}"#.utf8))
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset() {
        self.state.withLock { $0 = State() }
    }

    static var calendarRequests: [Request] { self.state.withLock { $0.calendar } }
    static var watchRequests: Int { self.state.withLock { $0.watch } }
    static var answer: String {
        get { self.state.withLock { $0.answer } }
        set { self.state.withLock { $0.answer = newValue } }
    }
    static var failFirstWatchAttempts: Int {
        get { self.state.withLock { $0.failWatch } }
        set { self.state.withLock { $0.failWatch = newValue } }
    }
    static var statusBody: (Int, Data) {
        get { self.state.withLock { $0.status } }
        set { self.state.withLock { $0.status = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(of: self.request)
        let statusCode: Int
        let data: Data
        if self.request.url?.path == "/api/system/status" {
            (statusCode, data) = Self.statusBody
        } else {
            let parsed = Request(body: body)
            if parsed.envelope?["source"] as? String == "calendar" {
                Self.state.withLock { $0.calendar.append(parsed) }
                switch Self.answer {
                case "segment_removed":
                    (statusCode, data) = (500, Data(#"{"status":"failed","error":"Ingest request failed","reason_code":"segment_removed"}"#.utf8))
                case "calendar_note_invalid":
                    (statusCode, data) = (400, Data(#"{"status":"failed","error":"Ingest request refused","reason_code":"calendar_note_invalid","detail":"line 1"}"#.utf8))
                default:
                    (statusCode, data) = (200, transferTestMatchingReceipt(body: body, contentType: self.request.value(forHTTPHeaderField: "Content-Type"), status: Self.answer))
                }
            } else {
                let fail = Self.state.withLock { state -> Bool in
                    state.watch += 1
                    guard state.failWatch > 0 else { return false }
                    state.failWatch -= 1
                    return true
                }
                (statusCode, data) = fail
                    ? (500, Data(#"{"status":"failed"}"#.utf8))
                    : (200, transferTestMatchingReceipt(body: body, contentType: self.request.value(forHTTPHeaderField: "Content-Type")))
            }
        }
        let response = HTTPURLResponse(url: self.request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
final class CalendarFinishSyncingHandle: FinishSyncingTaskHandle {
    var isCancelled = false
    private(set) var completedSuccess: Bool?

    func setProgressTotal(_ total: Int) {}
    func setProgressCompleted(_ completed: Int) {}
    func updateTitle(_ title: String, subtitle: String) {}
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {}

    func complete(success: Bool) {
        self.completedSuccess = success
    }
}

@MainActor
final class CalendarNoScheduling: FinishSyncingScheduling {
    func register(identifier: String, launchHandler: @escaping @MainActor (any FinishSyncingTaskHandle) -> Void) -> Bool {
        true
    }

    func submit(identifier: String, title: String, subtitle: String) throws {}
}
