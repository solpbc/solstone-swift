// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchSourceFactsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSourceFactsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testStatusContextFactSetsOnceAndPersistsThroughDefaults() throws {
        let defaults = try Self.defaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let facts = WatchSourceFacts(defaults: defaults.defaults)

        XCTAssertEqual(facts.snapshot, Self.snapshot(watchAppCheckedIn: false, segmentFileReceived: false))

        facts.noteStatusContextCheckedIn()
        facts.noteStatusContextCheckedIn()

        XCTAssertEqual(facts.snapshot, Self.snapshot(watchAppCheckedIn: true, segmentFileReceived: false))
        XCTAssertEqual(
            WatchSourceFacts(defaults: defaults.defaults).snapshot,
            Self.snapshot(watchAppCheckedIn: true, segmentFileReceived: false)
        )
    }

    func testSegmentFileFactSetsBothFactsAndPersistsThroughDefaults() throws {
        let defaults = try Self.defaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let facts = WatchSourceFacts(defaults: defaults.defaults)

        facts.noteSegmentFileReceived()
        facts.noteSegmentFileReceived()

        XCTAssertEqual(facts.snapshot, Self.snapshot(watchAppCheckedIn: true, segmentFileReceived: true))
        XCTAssertEqual(
            WatchSourceFacts(defaults: defaults.defaults).snapshot,
            Self.snapshot(watchAppCheckedIn: true, segmentFileReceived: true)
        )
    }

    func testInstallTappedFactSetsOnceAndPersistsThroughDefaults() throws {
        let defaults = try Self.defaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let facts = WatchSourceFacts(defaults: defaults.defaults)

        facts.noteInstallTapped()
        facts.noteInstallTapped()

        XCTAssertEqual(
            facts.snapshot,
            Self.snapshot(watchAppCheckedIn: false, segmentFileReceived: false, installTapped: true)
        )
        XCTAssertEqual(
            WatchSourceFacts(defaults: defaults.defaults).snapshot,
            Self.snapshot(watchAppCheckedIn: false, segmentFileReceived: false, installTapped: true)
        )
    }

    func testFirstSegmentCelebrationShownFactSetsOnceAndPersistsThroughDefaults() throws {
        let defaults = try Self.defaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let facts = WatchSourceFacts(defaults: defaults.defaults)

        facts.noteFirstSegmentCelebrationShown()
        facts.noteFirstSegmentCelebrationShown()

        XCTAssertEqual(
            facts.snapshot,
            Self.snapshot(
                watchAppCheckedIn: false,
                segmentFileReceived: false,
                firstSegmentCelebrationShown: true
            )
        )
        XCTAssertEqual(
            WatchSourceFacts(defaults: defaults.defaults).snapshot,
            Self.snapshot(
                watchAppCheckedIn: false,
                segmentFileReceived: false,
                firstSegmentCelebrationShown: true
            )
        )
    }

    func testWatchLinkWritesStatusContextFactForValidContext() async throws {
        let defaults = try Self.defaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let facts = WatchSourceFacts(defaults: defaults.defaults)
        let session = MockWatchConnectivitySession()
        let historyStore = WatchPhoneSessionHistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(WatchPhoneSessionHistoryStore.historyFileName),
            clock: Date.init
        )
        let link = WatchLink(session: session, receiver: nil, facts: facts, phoneSessionHistoryStore: historyStore)

        session.deliverApplicationContext(Self.status(seq: 1).applicationContext())
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(link.watchStatus?.seq, 1)
        XCTAssertEqual(facts.snapshot, Self.snapshot(watchAppCheckedIn: true, segmentFileReceived: false))
    }

    func testWatchRelayReceiverWritesBothFactsForValidSegmentOnly() throws {
        let defaults = try Self.defaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let facts = WatchSourceFacts(defaults: defaults.defaults)
        let session = MockWatchConnectivitySession()
        let ledger = WatchSegmentLedger(
            fileURL: self.tempDirectory.appendingPathComponent("ledger.json", isDirectory: false)
        )
        let receiver = try WatchRelayReceiver(
            session: session,
            ledger: ledger,
            stagingRootURL: self.tempDirectory.appendingPathComponent("staging", isDirectory: true),
            facts: facts
        )

        let invalidScratch = self.tempDirectory.appendingPathComponent("invalid.bundle", isDirectory: false)
        try Data("invalid".utf8).write(to: invalidScratch)
        receiver.receiveFile(invalidScratch, metadata: [:])
        XCTAssertEqual(facts.snapshot, Self.snapshot(watchAppCheckedIn: false, segmentFileReceived: false))

        let id = UUID()
        let validScratch = self.tempDirectory.appendingPathComponent("valid.bundle", isDirectory: false)
        try Self.writeBundle(id: id, to: validScratch)
        receiver.receiveFile(validScratch, metadata: ["id": id.uuidString])

        XCTAssertEqual(facts.snapshot, Self.snapshot(watchAppCheckedIn: true, segmentFileReceived: true))
        XCTAssertEqual(ledger.nonTerminalCount, 1)
    }
}

private extension WatchSourceFactsTests {
    struct DefaultsBox {
        let name: String
        let defaults: UserDefaults
    }

    static func defaults() throws -> DefaultsBox {
        let name = "WatchSourceFactsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return DefaultsBox(name: name, defaults: defaults)
    }

    static func snapshot(
        watchAppCheckedIn: Bool,
        segmentFileReceived: Bool,
        installTapped: Bool = false,
        firstSegmentCelebrationShown: Bool = false
    ) -> WatchSourceFacts.Snapshot {
        WatchSourceFacts.Snapshot(
            watchAppCheckedIn: watchAppCheckedIn,
            segmentFileReceived: segmentFileReceived,
            installTapped: installTapped,
            firstSegmentCelebrationShown: firstSegmentCelebrationShown
        )
    }

    static func status(seq: Int) -> WatchStatusContext {
        WatchStatusContext(
            phase: .idle,
            sessionID: nil,
            startedAt: nil,
            asOf: Date(timeIntervalSince1970: 1_000),
            seq: seq,
            queuedCount: 0,
            transferringCount: 0
        )
    }

    static func writeBundle(id: UUID, to url: URL) throws {
        let manifest = WatchSegmentManifest(
            id: id,
            day: "20260720",
            segment: "120000_300",
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .queued
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let bundleData = try PropertyListSerialization.data(
            fromPropertyList: [WatchSegmentBundleCodec.manifestFilename: manifestData],
            format: .binary,
            options: 0
        )
        try bundleData.write(to: url, options: .atomic)
    }
}
