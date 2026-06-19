// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
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
        let sessionID = UUID()
        let audioChunkID = "chunk-a"
        let audioID = "audio:\(sessionID.uuidString):\(audioChunkID)"
        let locationID = "location:20260603-110000_300"
        let shareID = "share-delivered"

        try self.writeObserverChunk(
            root: queues.observerRoot,
            sessionID: sessionID,
            chunkID: audioChunkID,
            status: "pending",
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 42
        )
        try self.writeLocationSegment(
            root: queues.locationRoot,
            status: "failed",
            fileID: "20260603-110000_300",
            fixCount: 7
        )
        try self.writeShareLedger(
            root: queues.importRoot,
            itemID: shareID,
            deliveredAt: Date(timeIntervalSince1970: 1_780_473_600)
        )

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            observerUploader: queues.observerUploader,
            locationUploader: queues.locationUploader
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
            observerUploader: emptyQueues.observerUploader,
            locationUploader: emptyQueues.locationUploader
        )
        XCTAssertEqual(empty.items, [])
        XCTAssertEqual(try self.count(for: .audio, in: empty), 0)
        XCTAssertEqual(try self.count(for: .location, in: empty), 0)
        XCTAssertEqual(try self.count(for: .share, in: empty), 0)
    }

    @MainActor
    func testAggregatorKeepsHealthySourcesWhenShareStoreFails() throws {
        let queues = self.makeQueues()
        let sessionID = UUID()
        let audioChunkID = "chunk-b"
        let audioID = "audio:\(sessionID.uuidString):\(audioChunkID)"
        let locationID = "location:20260603-110000_300"
        try self.writeObserverChunk(
            root: queues.observerRoot,
            sessionID: sessionID,
            chunkID: audioChunkID,
            status: "pending",
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 12
        )
        try self.writeLocationSegment(
            root: queues.locationRoot,
            status: "pending",
            fileID: "20260603-110000_300",
            fixCount: 3
        )
        try Data("{".utf8).write(to: queues.importRoot.appendingPathComponent("ledger.json"), options: .atomic)

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: queues.importQueue,
            observerUploader: queues.observerUploader,
            locationUploader: queues.locationUploader
        )

        XCTAssertEqual(snapshot.items.map(\.id), [audioID, locationID])
        XCTAssertTrue(try self.isFailed(.share, in: snapshot))
        XCTAssertEqual(try self.count(for: .audio, in: snapshot), 1)
        XCTAssertEqual(try self.count(for: .location, in: snapshot), 1)
    }

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
        XCTAssertEqual(location.rowDescriptorText, "2 observations")
        XCTAssertEqual(share.rowDescriptorText, "share.pdf")
        XCTAssertEqual(audio.rowTimestampText, itemTime.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(deliveredOnly.rowTimestampText, deliveredAt.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(nilTime.rowTimestampText, "")
    }

    func testDropDescriptorAndConfirmNounForParseableItems() throws {
        let sessionID = UUID()
        let audioDuration: Double = 75
        let audioDurationText = try XCTUnwrap(OnThisPhoneItem.formattedDuration(audioDuration))
        let audio = Self.item(
            id: "audio:\(sessionID.uuidString):chunk-a",
            sourceKind: .audio,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            audioDurationS: audioDuration
        )
        let location = Self.item(
            id: "location:20260603-110000_300",
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
        XCTAssertEqual(audio.dropConfirmNoun, SourceVocabulary.onThisPhoneDropAudioNoun)
        XCTAssertEqual(location.dropDescriptor, SourceVocabulary.onThisPhoneDropLocationDescriptor(count: 2))
        XCTAssertEqual(location.dropConfirmNoun, SourceVocabulary.onThisPhoneDropLocationNoun)
        XCTAssertEqual(share.dropDescriptor, share.filename)
        XCTAssertEqual(share.dropConfirmNoun, SourceVocabulary.onThisPhoneDropShareNoun)
    }

    func testDropDescriptorAndConfirmNounUseParseFailureFallbacks() {
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
        XCTAssertEqual(audio.dropConfirmNoun, SourceVocabulary.onThisPhoneDropShareNoun)
        XCTAssertEqual(location.dropDescriptor, location.filename)
        XCTAssertEqual(location.dropConfirmNoun, SourceVocabulary.onThisPhoneDropShareNoun)
        XCTAssertEqual(share.dropDescriptor, share.filename)
        XCTAssertEqual(share.dropConfirmNoun, SourceVocabulary.onThisPhoneDropShareNoun)
    }

    func testOnThisPhoneItemIDParsing() throws {
        let sessionID = UUID()
        let shareID = UUID()

        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .audio, id: "audio:\(sessionID.uuidString):chunk:with:colons"),
            .audio(sessionID: sessionID, chunkID: "chunk:with:colons")
        )
        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .location, id: "location:20260603-110000_300"),
            .location(fileID: "20260603-110000_300")
        )
        XCTAssertEqual(
            OnThisPhoneItemID(sourceKind: .share, id: shareID.uuidString),
            .share(shareID)
        )
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .audio, id: "audio:not-a-uuid:chunk"))
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .location, id: "20260603-110000_300"))
        XCTAssertNil(OnThisPhoneItemID(sourceKind: .share, id: "location:20260603-110000_300"))
    }
}

private extension OnThisPhoneAggregatorTests {
    struct Queues {
        let importRoot: URL
        let observerRoot: URL
        let locationRoot: URL
        let importQueue: ImportQueue
        let observerUploader: ObserverUploader
        let locationUploader: LocationUploader
    }

    @MainActor
    func makeQueues(suffix: String = "main") -> Queues {
        let importRoot = self.tempDirectory.appendingPathComponent("\(suffix)-import", isDirectory: true)
        let observerRoot = self.tempDirectory.appendingPathComponent("\(suffix)-observer", isDirectory: true)
        let locationRoot = self.tempDirectory.appendingPathComponent("\(suffix)-location", isDirectory: true)
        return Queues(
            importRoot: importRoot,
            observerRoot: observerRoot,
            locationRoot: locationRoot,
            importQueue: ImportQueue(
                cacheRootURL: importRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false
            ),
            observerUploader: ObserverUploader(
                cacheRootURL: observerRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false
            ),
            locationUploader: LocationUploader(
                cacheRootURL: locationRoot,
                sessionConfiguration: .ephemeral,
                startPathMonitor: false,
                timeZone: TimeZone(secondsFromGMT: 7_200)!
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
            mode: .meeting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sidecar).write(to: directory.appendingPathComponent("\(chunkID).json"))
    }

    func writeLocationSegment(root: URL, status: String, fileID: String, fixCount: Int) throws {
        let directory = root.appendingPathComponent(status, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(
            #"{"accuracy":"full","fix_count":\#(fixCount),"gap":false,"kind":"location","platform":"ios","schema":"solstone.location.segment/1","source":"location","tier":"balanced"}"#
                .utf8
        ) + Data([0x0A])
        try data.write(to: directory.appendingPathComponent("\(fileID).jsonl"))
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
        locationFixCount: Int? = nil
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
            locationFixCount: locationFixCount
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
