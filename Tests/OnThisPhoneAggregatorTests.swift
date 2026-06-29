// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Observation
import XCTest

nonisolated final class OnThisPhoneAggregatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testAggregatorMergesSourcesNewestFirstWithCountsKindsAndPayloads() throws {
        let queues = self.makeQueues()
        let audioSegmentID = UUID()
        let locationSegmentID = UUID()
        let audioID = "mobile-segment:\(audioSegmentID.uuidString):audio"
        let locationID = "mobile-segment:\(locationSegmentID.uuidString):location"
        let shareID = "share-delivered"

        try self.writeMobileSegment(
            root: queues.mobileSegmentRoot,
            lifecycle: .pending,
            segmentID: audioSegmentID,
            source: .audio,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 42
        )
        try self.writeMobileSegment(
            root: queues.mobileSegmentRoot,
            lifecycle: .failed,
            segmentID: locationSegmentID,
            source: .location,
            startedAt: Date(timeIntervalSince1970: 1_780_480_700),
            durationS: 300,
            fixCount: 7
        )
        try self.writeShareLedger(
            root: queues.importRoot,
            itemID: shareID,
            deliveredAt: Date(timeIntervalSince1970: 1_780_473_600)
        )

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            mobileSegmentUploader: queues.mobileSegmentUploader,
            omiUploader: queues.omiUploader,
            watchUploader: queues.watchUploader
        )

        XCTAssertEqual(snapshot.items.map(\.id), [audioID, locationID, shareID])
        XCTAssertEqual(try self.count(for: .audio, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .location, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .share, in: snapshot), 1)
        XCTAssertEqual(snapshot.items.map(\.sourceKind), [.audio, .location, .share])
        XCTAssertEqual(snapshot.items.first { $0.id == audioID }?.sendState, .savedOnThisPhone)
        XCTAssertEqual(snapshot.items.first { $0.id == locationID }?.sendState, .needsAttention)
        XCTAssertEqual(snapshot.items.first { $0.id == shareID }?.sendState, .inYourJournal)
        XCTAssertEqual(snapshot.items.first { $0.id == audioID }?.audioDurationS, 42)
        XCTAssertEqual(snapshot.items.first { $0.id == locationID }?.locationFixCount, 7)

        let emptyQueues = self.makeQueues(suffix: "empty")
        let empty = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: emptyQueues.importQueue,
            mobileSegmentUploader: emptyQueues.mobileSegmentUploader,
            omiUploader: emptyQueues.omiUploader,
            watchUploader: emptyQueues.watchUploader
        )
        XCTAssertEqual(empty.items, [])
        XCTAssertEqual(try self.count(for: .audio, in: empty), 0)
        XCTAssertEqual(try self.count(for: .location, in: empty), 0)
        XCTAssertEqual(try self.count(for: .share, in: empty), 0)
    }

    @MainActor
    func testAggregatorKeepsHealthySourcesWhenShareStoreFails() throws {
        let queues = self.makeQueues()
        let audioSegmentID = UUID()
        let locationSegmentID = UUID()
        let audioID = "mobile-segment:\(audioSegmentID.uuidString):audio"
        let locationID = "mobile-segment:\(locationSegmentID.uuidString):location"
        try self.writeMobileSegment(
            root: queues.mobileSegmentRoot,
            lifecycle: .pending,
            segmentID: audioSegmentID,
            source: .audio,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 12
        )
        try self.writeMobileSegment(
            root: queues.mobileSegmentRoot,
            lifecycle: .pending,
            segmentID: locationSegmentID,
            source: .location,
            startedAt: Date(timeIntervalSince1970: 1_780_480_700),
            durationS: 300,
            fixCount: 3
        )
        try Data("{".utf8).write(to: queues.importRoot.appendingPathComponent("ledger.json"), options: .atomic)

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            mobileSegmentUploader: queues.mobileSegmentUploader,
            omiUploader: queues.omiUploader,
            watchUploader: queues.watchUploader
        )

        XCTAssertEqual(snapshot.items.map(\.id), [audioID, locationID])
        XCTAssertTrue(try self.isFailed(.share, in: snapshot))
        XCTAssertEqual(try self.count(for: .audio, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .location, in: snapshot), 1)
    }

    @MainActor
    func testAggregatorIncludesOmiAudioWithDistinctNamespace() throws {
        let queues = self.makeQueues()
        let mobileSegmentID = UUID()
        let omiSessionID = UUID()
        let omiChunkID = "omi-chunk"
        let observerID = "mobile-segment:\(mobileSegmentID.uuidString):audio"
        let omiID = "omi:\(omiSessionID.uuidString):\(omiChunkID)"

        try self.writeMobileSegment(
            root: queues.mobileSegmentRoot,
            lifecycle: .pending,
            segmentID: mobileSegmentID,
            source: .audio,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 42
        )
        try self.writeObserverChunk(
            root: queues.omiRoot,
            sessionID: omiSessionID,
            chunkID: omiChunkID,
            status: "pending",
            startedAt: Date(timeIntervalSince1970: 1_780_480_900),
            durationS: 12
        )

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            mobileSegmentUploader: queues.mobileSegmentUploader,
            omiUploader: queues.omiUploader,
            watchUploader: queues.watchUploader
        )

        XCTAssertEqual(snapshot.items.map(\.id), [omiID, observerID])
        XCTAssertEqual(try self.count(for: .audio, in: snapshot), 2)
        XCTAssertEqual(snapshot.items.first { $0.id == observerID }?.sourceLabel, SourceVocabulary.onThisPhoneObserverAudioSourceLabel)
        XCTAssertEqual(snapshot.items.first { $0.id == omiID }?.sourceLabel, SourceVocabulary.onThisPhoneOmiAudioSourceLabel)
    }

    #if DEBUG
    @MainActor
    func testLargeBacklogSeedSurfacesObserverAndOmiRowsWithLabels() throws {
        let queues = self.makeQueues(suffix: "large")
        let requestedCount = 7
        let observerCount = (requestedCount + 1) / 2
        let omiCount = requestedCount / 2
        let baseDate = Date(timeIntervalSince1970: 1_780_500_000)
        for index in 0..<observerCount {
            try self.writeMobileSegment(
                root: queues.mobileSegmentRoot,
                lifecycle: .pending,
                segmentID: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index))!,
                source: .audio,
                startedAt: baseDate.addingTimeInterval(Double(index)),
                durationS: TimeInterval(30 + (index % 90))
            )
        }
        for index in 0..<omiCount {
            try self.writeObserverChunk(
                root: queues.omiRoot,
                sessionID: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
                chunkID: String(format: "ui-test-large-backlog-omi-%04d", index),
                status: "pending",
                startedAt: baseDate.addingTimeInterval(Double(observerCount + index)),
                durationS: TimeInterval(30 + ((observerCount + index) % 90))
            )
        }

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            mobileSegmentUploader: queues.mobileSegmentUploader,
            omiUploader: queues.omiUploader,
            watchUploader: queues.watchUploader
        )
        let observerItems = snapshot.items.filter { $0.id.hasPrefix("mobile-segment:") && $0.sourceKind == .audio }
        let omiItems = snapshot.items.filter { $0.id.hasPrefix("omi:") }

        XCTAssertEqual(snapshot.items.count, requestedCount)
        XCTAssertEqual(observerItems.count, observerCount)
        XCTAssertEqual(omiItems.count, omiCount)
        XCTAssertTrue(observerItems.allSatisfy { $0.sourceLabel == SourceVocabulary.onThisPhoneObserverAudioSourceLabel })
        XCTAssertTrue(omiItems.allSatisfy { $0.sourceLabel == SourceVocabulary.onThisPhoneOmiAudioSourceLabel })
    }
    #endif

    @MainActor
    func testPureSnapshotKeepsGapCountDistinctFromLoadedZero() throws {
        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(sources: [
            OnThisPhoneSourceSnapshot(sourceKind: .audio, result: .failed),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: .loaded(items: [])),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: [])),
        ])

        let audio = try self.result(for: .audio, in: snapshot)
        let location = try self.result(for: .location, in: snapshot)
        XCTAssertNil(audio.count)
        XCTAssertEqual(location.count, 0)
        XCTAssertEqual(snapshot.sendStateSummary, [])
    }

    @MainActor
    func testSendStateSummaryCountsSuppressesZeroAndUsesFixedOrder() {
        let saved1 = Self.item(
            id: "saved-1",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 40),
            sendState: .savedOnThisPhone
        )
        let needsAttention = Self.item(
            id: "attention",
            sourceKind: .location,
            itemTime: Date(timeIntervalSince1970: 30),
            sendState: .needsAttention
        )
        let sending = Self.item(
            id: "sending",
            sourceKind: .share,
            itemTime: Date(timeIntervalSince1970: 20),
            sendState: .sending
        )
        let saved2 = Self.item(
            id: "saved-2",
            sourceKind: .share,
            itemTime: Date(timeIntervalSince1970: 10),
            sendState: .savedOnThisPhone
        )

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(sources: [
            OnThisPhoneSourceSnapshot(sourceKind: .audio, result: .loaded(items: [saved1])),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: .failed),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: [needsAttention, sending, saved2])),
        ])

        XCTAssertEqual(snapshot.sendStateSummary.map(\.sendState), [
            .savedOnThisPhone,
            .sending,
            .needsAttention,
        ])
        XCTAssertEqual(snapshot.sendStateSummary.map(\.count), [2, 1, 1])
        XCTAssertEqual(snapshot.sendStateSummary.map(\.id), [
            "savedOnThisPhone",
            "sending",
            "needsAttention",
        ])
    }

    @MainActor
    func testFilteringOutPendingRemovesItemsSourcesAndUpdatesSummary() throws {
        let audio = Self.item(
            id: "audio:00000000-0000-0000-0000-000000000001:chunk",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 40),
            sendState: .savedOnThisPhone
        )
        let location = Self.item(
            id: "location:20260603-110000_300",
            sourceKind: .location,
            itemTime: Date(timeIntervalSince1970: 30),
            sendState: .needsAttention
        )
        let share = Self.item(
            id: "11111111-1111-1111-1111-111111111111",
            sourceKind: .share,
            itemTime: Date(timeIntervalSince1970: 20),
            sendState: .sending
        )

        let sources = [
            OnThisPhoneSourceSnapshot(sourceKind: .audio, result: .loaded(items: [audio])),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: .loaded(items: [location])),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: [share])),
        ]
        let snapshot = OnThisPhoneAggregateSnapshot(
            sources: sources,
            items: [share, location, audio]
        )

        let filtered = snapshot.filteringOutPending([location.id])

        XCTAssertEqual(filtered.items.map(\.id), [share.id, audio.id])
        XCTAssertEqual(try self.count(for: .audio, in: filtered), 1)
        XCTAssertEqual(try self.count(for: .location, in: filtered), 0)
        XCTAssertEqual(try self.count(for: .share, in: filtered), 1)
        XCTAssertEqual(filtered.sendStateSummary.map(\.sendState), [.savedOnThisPhone, .sending])
        XCTAssertEqual(filtered.sendStateSummary.map(\.count), [1, 1])
    }

    @MainActor
    func testFilteringOutPendingUnknownIDIsNoOp() {
        let audio = Self.item(
            id: "audio:00000000-0000-0000-0000-000000000001:chunk",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 40)
        )
        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(sources: [
            OnThisPhoneSourceSnapshot(sourceKind: .audio, result: .loaded(items: [audio])),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: .failed),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: [])),
        ])

        XCTAssertEqual(snapshot.filteringOutPending(["missing"]), snapshot)
    }

    @MainActor
    func testPureSnapshotPartialFailureMergesLoadedItems() {
        let audio = Self.item(id: "audio", sourceKind: .audio, itemTime: Date(timeIntervalSince1970: 30))
        let share = Self.item(id: "share", sourceKind: .share, itemTime: Date(timeIntervalSince1970: 20))

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(sources: [
            OnThisPhoneSourceSnapshot(sourceKind: .audio, result: .loaded(items: [audio])),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: .failed),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: [share])),
        ])

        XCTAssertEqual(snapshot.items.map(\.id), ["audio", "share"])
    }

    @MainActor
    func testAgedBacklogThresholdRequiresCountAndAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(OnThisPhoneBacklogNudge.shouldShow(
            items: Self.items(count: 50, oldest: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            now: now
        ))
        XCTAssertFalse(OnThisPhoneBacklogNudge.shouldShow(
            items: Self.items(count: 51, oldest: now.addingTimeInterval(-6 * 24 * 60 * 60)),
            now: now
        ))
        XCTAssertTrue(OnThisPhoneBacklogNudge.shouldShow(
            items: Self.items(count: 51, oldest: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            now: now
        ))
    }

    func testLocationRowPayloadUsesObservationNoun() {
        let itemTime = Date(timeIntervalSince1970: 1_780_480_800)
        let singular = Self.item(
            id: "location:one",
            sourceKind: .location,
            itemTime: itemTime,
            locationFixCount: 1
        )
        let plural = Self.item(
            id: "location:two",
            sourceKind: .location,
            itemTime: itemTime,
            locationFixCount: 2
        )

        XCTAssertTrue(singular.rowPayloadText.hasPrefix("1 observation · "))
        XCTAssertTrue(plural.rowPayloadText.hasPrefix("2 observations · "))
        XCTAssertTrue(singular.voiceOverText.contains("1 observation"))
        XCTAssertTrue(plural.voiceOverText.contains("2 observations"))
        XCTAssertFalse(singular.rowPayloadText.contains("place"))
        XCTAssertFalse(plural.rowPayloadText.contains("place"))
    }

    func testRowDescriptorAndTimestampText() {
        let itemTime = Date(timeIntervalSince1970: 1_780_480_800)
        let deliveredAt = Date(timeIntervalSince1970: 1_780_481_200)
        let audio = Self.item(
            id: "audio.m4a",
            sourceKind: .audio,
            itemTime: itemTime,
            audioDurationS: 75
        )
        let failedAudio = Self.item(
            id: "audio-failed.m4a",
            sourceKind: .audio,
            itemTime: itemTime,
            sendState: .needsAttention,
            audioDurationS: 75,
            retryAvailable: true
        )
        let location = Self.item(
            id: "location",
            sourceKind: .location,
            itemTime: itemTime,
            locationFixCount: 2
        )
        let share = Self.item(
            id: "share.pdf",
            sourceKind: .share,
            itemTime: itemTime
        )
        let deliveredOnly = Self.item(
            id: "delivered.pdf",
            sourceKind: .share,
            itemTime: nil,
            deliveredAt: deliveredAt
        )
        let nilTime = Self.item(
            id: "nil-time",
            sourceKind: .share,
            itemTime: nil
        )

        XCTAssertEqual(audio.rowDescriptorText, "1m 15s")
        XCTAssertEqual(failedAudio.rowDescriptorText, "1m 15s · \(SourceVocabulary.onThisPhoneFailureRowHint)")
        XCTAssertEqual(location.rowDescriptorText, "2 observations")
        XCTAssertEqual(share.rowDescriptorText, "share.pdf")
        XCTAssertEqual(audio.rowTimestampText, itemTime.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(deliveredOnly.rowTimestampText, deliveredAt.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(nilTime.rowTimestampText, "")
    }

    func testDropDescriptorForParseableItems() throws {
        let sessionID = UUID()
        let audioDuration: Double = 75
        let audioDurationText = try XCTUnwrap(OnThisPhoneItem.formattedDuration(audioDuration))
        let audio = Self.item(
            id: "audio:\(sessionID.uuidString):chunk-a",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            audioDurationS: audioDuration
        )
        let locationSegmentID = UUID()
        let location = Self.item(
            id: "mobile-segment:\(locationSegmentID.uuidString):location",
            sourceKind: .location,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            locationFixCount: 2
        )
        let shareID = UUID()
        let share = Self.item(
            id: shareID.uuidString,
            sourceKind: .share,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800)
        )

        XCTAssertEqual(audio.dropDescriptor, SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: audioDurationText))
        XCTAssertEqual(location.dropDescriptor, SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2))
        XCTAssertEqual(share.dropDescriptor, share.filename)
    }

    func testDropDescriptorUsesParseFailureFallbacks() {
        let audio = Self.item(
            id: "audio:not-a-uuid:chunk",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800)
        )
        let location = Self.item(
            id: "20260603-110000_300",
            sourceKind: .location,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800)
        )
        let share = Self.item(
            id: "location:20260603-110000_300",
            sourceKind: .share,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800)
        )

        XCTAssertEqual(audio.dropDescriptor, audio.filename)
        XCTAssertEqual(location.dropDescriptor, location.filename)
        XCTAssertEqual(share.dropDescriptor, share.filename)
    }

    func testOmiAudioAccessorAndVoiceOverTextDistinguishSource() {
        let sessionID = UUID()
        let observer = Self.item(
            id: "audio:\(sessionID.uuidString):chunk",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            audioDurationS: 12
        )
        let omi = Self.item(
            id: "omi:\(sessionID.uuidString):chunk",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            audioDurationS: 12
        )

        XCTAssertFalse(observer.isOmiAudio)
        XCTAssertTrue(omi.isOmiAudio)
        XCTAssertTrue(observer.voiceOverText.hasPrefix("audio."))
        XCTAssertTrue(omi.voiceOverText.hasPrefix("omi pendant audio."))
    }

    func testOnThisPhoneItemIDParsing() throws {
        let sessionID = UUID()
        let shareID = UUID()
        let segmentID = UUID()

        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .audio, id: "audio:\(sessionID.uuidString):chunk:with:colons"),
            .audio(sessionID: sessionID, chunkID: "chunk:with:colons", source: .observer)
        )
        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .audio, id: "omi:\(sessionID.uuidString):chunk"),
            .audio(sessionID: sessionID, chunkID: "chunk", source: .omi)
        )
        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .location, id: "mobile-segment:\(segmentID.uuidString):location"),
            .mobileSegment(segmentID: segmentID, facet: .location)
        )
        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .share, id: shareID.uuidString),
            .share(shareID)
        )
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .audio, id: "audio:not-a-uuid:chunk"))
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .audio, id: "omi:not-a-uuid:chunk"))
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .location, id: "location:20260603-110000_300"))
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .location, id: "20260603-110000_300"))
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .share, id: "location:20260603-110000_300"))
    }

    @MainActor
    func testOmiUploaderHolderCountProxiesObserveUploaderCounts() async {
        let queues = self.makeQueues()
        let holder = OmiUploaderHolder(queues.omiUploader)
        let pendingChanged = self.expectation(description: "pending count changed")
        let failedChanged = self.expectation(description: "failed count changed")

        withObservationTracking {
            _ = holder.pendingCount
        } onChange: {
            pendingChanged.fulfill()
        }
        withObservationTracking {
            _ = holder.failedCount
        } onChange: {
            failedChanged.fulfill()
        }

        queues.omiUploader.pendingCount = 1
        queues.omiUploader.failedCount = 2

        await fulfillment(of: [pendingChanged, failedChanged], timeout: 1)
    }
}

private extension OnThisPhoneAggregatorTests {
    struct Queues {
        let importRoot: URL
        let mobileSegmentRoot: URL
        let omiRoot: URL
        let watchRoot: URL
        let importQueue: ImportQueue
        let mobileSegmentUploader: MobileSegmentUploader
        let omiUploader: ObserverUploader
        let watchUploader: ObserverUploader
    }

    @MainActor
    func makeQueues(suffix: String = "main") -> Queues {
        let importRoot = self.tempDirectory.appendingPathComponent("\(suffix)-import", isDirectory: true)
        let mobileSegmentRoot = self.tempDirectory.appendingPathComponent("\(suffix)-mobile-segment", isDirectory: true)
        let omiRoot = self.tempDirectory.appendingPathComponent("\(suffix)-omi", isDirectory: true)
        let watchRoot = self.tempDirectory.appendingPathComponent("\(suffix)-watch", isDirectory: true)
        let mobileTransport = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("\(suffix)-mobile-transport", isDirectory: true),
            sessionConfiguration: .ephemeral,
            isJournalConfigured: { false },
            localPortProvider: { nil },
            startPathMonitor: false
        )
        return Queues(
            importRoot: importRoot,
            mobileSegmentRoot: mobileSegmentRoot,
            omiRoot: omiRoot,
            watchRoot: watchRoot,
            importQueue: ImportQueue(
                cacheRootURL: importRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false
            ),
            mobileSegmentUploader: MobileSegmentUploader(
                transport: mobileTransport,
                store: MobileSegmentStore(rootURL: mobileSegmentRoot),
                clock: MockObserverClock()
            ),
            omiUploader: ObserverUploader(
                cacheRootURL: omiRoot,
                sessionConfiguration: .ephemeral,
                sourceType: "omi-audio",
                startPathMonitor: false
            ),
            watchUploader: ObserverUploader(
                cacheRootURL: watchRoot,
                sessionConfiguration: .ephemeral,
                sourceType: "watch-audio",
                startPathMonitor: false
            )
        )
    }

    @MainActor
    func writeObserverChunk(
        root: URL,
        sessionID: UUID,
        chunkID: String,
        status: String,
        startedAt: Date,
        durationS: TimeInterval
    ) throws {
        let directory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(status, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("\(chunkID).m4a"))
        let sidecar = ChunkSidecar(
            segment: "120000_300",
            day: "20260603",
            chunkIndex: 0,
            startedAt: startedAt,
            durationS: durationS,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sidecar).write(to: directory.appendingPathComponent("\(chunkID).json"))
    }

    @MainActor
    func writeMobileSegment(
        root: URL,
        lifecycle: MobileSegmentLifecycle,
        segmentID: UUID,
        source: MobileSegmentSource,
        startedAt: Date,
        durationS: TimeInterval,
        fixCount: Int? = nil
    ) throws {
        let store = MobileSegmentStore(rootURL: root)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: Set([source]),
            activeSourceSetVersion: 0
        )
        manifest.day = "20260603"
        manifest.segment = "120000_\(Int(durationS))"
        manifest.endedAt = startedAt.addingTimeInterval(durationS)
        manifest.durationS = durationS
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)

        switch source {
        case .audio:
            let audioURL = store.audioURL(in: directory)
            try Data("audio".utf8).write(to: audioURL, options: .atomic)
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: audioURL.lastPathComponent,
                bytes: store.fileSize(at: audioURL),
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(durationS),
                durationS: durationS,
                mode: .meeting
            )
            try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: startedAt)
        case .location:
            let locationURL = store.locationURL(in: directory)
            let data = Data(
                #"{"accuracy":"full","fix_count":\#(fixCount ?? 0),"gap":false,"kind":"location","platform":"ios","schema":"solstone.location.segment/1","source":"location","tier":"balanced"}"#
                    .utf8
            ) + Data([0x0A])
            try data.write(to: locationURL, options: .atomic)
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: locationURL.lastPathComponent,
                bytes: store.fileSize(at: locationURL),
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(durationS),
                durationS: durationS,
                fixCount: fixCount
            )
            try store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: startedAt)
        }

        if lifecycle == .failed {
            try store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: "test failure",
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 1,
                    stage: "test",
                    lastAttemptAt: startedAt
                ),
                in: directory
            )
        }
        _ = try store.move(segmentID: segmentID, from: .active, to: lifecycle)
    }

    func writeShareLedger(root: URL, itemID: String, deliveredAt: Date) throws {
        let ledger = [
            itemID: ShareLedgerFixture(
                itemID: itemID,
                basis: "sent",
                contentType: "application/pdf",
                targetJournal: "home",
                serverPath: "/imports/share",
                serverTimestamp: "2026-06-03T12:00:00Z",
                deliveredAt: deliveredAt,
                filename: "share.pdf",
                originApp: nil,
                itemTime: nil
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: root.appendingPathComponent("ledger.json"), options: .atomic)
    }

    func count(for sourceKind: OnThisPhoneSourceKind, in snapshot: OnThisPhoneAggregateSnapshot) throws -> Int {
        let result = try self.result(for: sourceKind, in: snapshot)
        guard case .loaded(let items) = result else {
            XCTFail("Expected loaded source")
            return 0
        }
        return items.count
    }

    func isFailed(_ sourceKind: OnThisPhoneSourceKind, in snapshot: OnThisPhoneAggregateSnapshot) throws -> Bool {
        let result = try self.result(for: sourceKind, in: snapshot)
        guard case .failed = result else { return false }
        return true
    }

    func result(for sourceKind: OnThisPhoneSourceKind, in snapshot: OnThisPhoneAggregateSnapshot) throws -> OnThisPhoneSourceResult {
        try XCTUnwrap(snapshot.sources.first { $0.sourceKind == sourceKind }?.result)
    }

    static func items(count: Int, oldest: Date) -> [OnThisPhoneItem] {
        (0..<count).map { index in
            Self.item(
                id: "item-\(index)",
                sourceKind: .share,
                itemTime: index == 0 ? oldest : Date(timeIntervalSince1970: oldest.timeIntervalSince1970 + Double(index + 1))
            )
        }
    }

    static func item(
        id: String,
        sourceKind: OnThisPhoneSourceKind,
        itemTime: Date?,
        sendState: OnThisPhoneSendState = .savedOnThisPhone,
        deliveredAt: Date? = nil,
        audioDurationS: Double? = nil,
        locationFixCount: Int? = nil,
        failureReason: String? = nil,
        failureAttemptCount: Int? = nil,
        sourceLabel: String? = nil,
        retryAvailable: Bool = false
    ) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id,
            sourceKind: sourceKind,
            sendState: sendState,
            contentType: "application/octet-stream",
            filename: id,
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: itemTime,
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: deliveredAt,
            rawFileURL: nil,
            audioDurationS: audioDurationS,
            locationFixCount: locationFixCount,
            failureReason: failureReason,
            failureAttemptCount: failureAttemptCount,
            sourceLabel: sourceLabel,
            retryAvailable: retryAvailable
        )
    }
}

private struct ShareLedgerFixture: Codable {
    let itemID: String
    let basis: String
    let contentType: String
    let targetJournal: String
    let serverPath: String?
    let serverTimestamp: String?
    let deliveredAt: Date
    let filename: String?
    let originApp: String?
    let itemTime: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case basis
        case contentType = "content_type"
        case targetJournal = "target_journal"
        case serverPath = "server_path"
        case serverTimestamp = "server_timestamp"
        case deliveredAt = "delivered_at"
        case filename
        case originApp = "origin_app"
        case itemTime = "item_time"
    }
}
