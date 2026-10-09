// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// A refused item can be diagnosed from the diagnostics export alone: the journal's reason code
/// is kept on its own field, the refusal body's detail is never stored, and the export lists the
/// most recent refusals with their day and segment rendered in printable ASCII.
nonisolated final class RefusedItemsExportTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefusedItemsExportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    // MARK: - capture path

    @MainActor
    func testIngestRefusalKeepsTheCodeNotTheDetailAndExportsTheSegmentEscaped() async throws {
        let body = #"{"error":"Ingest request refused","reason_code":"segment_invalid","detail":"segment must be HHMMSS_LEN"}"#
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 400), Data(body.utf8))
        }
        let engine = self.makeEngine()
        try await engine.start()
        let itemID = try await engine.enqueue(
            manifest: Self.ingestManifest(itemID: Self.uuid(1), segment: "13724\u{202F}PM_13"),
            payloads: Self.audioPayloads
        )
        try await self.waitFor("refused item in attention") {
            (await engine.itemSnapshot(itemID: itemID))?.state == .attention
        }

        let snapshot = await engine.itemSnapshot(itemID: itemID)
        let attention = try XCTUnwrap(snapshot?.manifest.attention)
        XCTAssertEqual(attention.journalReasonCode, "segment_invalid")
        XCTAssertFalse(attention.shortDetail.contains("HHMMSS"), attention.shortDetail)
        let stored = try self.storedAttentionManifestText(itemID: itemID)
        XCTAssertTrue(stored.contains("segment_invalid"), stored)
        XCTAssertFalse(stored.contains("HHMMSS"), stored)
        XCTAssertFalse(stored.contains("Ingest request refused"), stored)

        let export = try await self.exportText(engine: engine, now: Self.baseDate.addingTimeInterval(3_600))
        await engine.pause()

        XCTAssertTrue(export.contains(#"«13724\u{202F}PM_13»"#), export)
        let block = try Self.syncStateSection(of: export)
        XCTAssertFalse(block.isEmpty)
        for line in block {
            XCTAssertFalse(line.unicodeScalars.contains { $0.value == 0x202F }, line)
        }
    }

    @MainActor
    func testRefusalDetailCarryingDeviceIdentifiersIsNeitherStoredNorExported() async throws {
        let body = #"{"error":"Not Found","reason_code":"not_found","detail":"LinkedDevice { carrier: ViaSpl, cid: LinkedDeviceCid(\"sha256:aaaa\"), leaf_spki: [48, 89] }"}"#
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 404), Data(body.utf8))
        }
        let engine = self.makeEngine()
        try await engine.start()
        let itemID = try await engine.enqueue(
            manifest: Self.ingestManifest(itemID: Self.uuid(2), segment: "133724_13"),
            payloads: Self.audioPayloads
        )
        try await self.waitFor("refused item in attention") {
            (await engine.itemSnapshot(itemID: itemID))?.state == .attention
        }

        let snapshot = await engine.itemSnapshot(itemID: itemID)
        let attention = try XCTUnwrap(snapshot?.manifest.attention)
        XCTAssertEqual(attention.journalReasonCode, "not_found")
        for needle in ["sha256:", "leaf_spki", "LinkedDevice"] {
            XCTAssertFalse(attention.shortDetail.contains(needle), attention.shortDetail)
        }
        let stored = try self.storedAttentionManifestText(itemID: itemID)
        for needle in ["sha256:", "leaf_spki", "LinkedDevice"] {
            XCTAssertFalse(stored.contains(needle), stored)
        }

        let export = try await self.exportText(engine: engine, now: Self.baseDate.addingTimeInterval(60))
        await engine.pause()

        XCTAssertTrue(export.contains("not_found"), export)
        XCTAssertFalse(export.contains("sha256:"), export)
        XCTAssertFalse(export.contains("leaf_spki"), export)
    }

    func testEveryRefusalPathKeepsTheReasonCodeAndNeverTheBodyDetail() {
        let ingest400 = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(
                statusCode: 400,
                data: Data(#"{"error":"Ingest request refused","reason_code":"day_invalid","detail":"day must be YYYYMMDD"}"#.utf8)
            ),
            endpointPhase: .observerIngest
        )
        let save413 = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(
                statusCode: 413,
                data: Data(#"{"error":"that file is too large to bring in.","reason_code":"multipart_part_too_large","detail":"limit 1"}"#.utf8)
            ),
            endpointPhase: .save
        )
        let ingestFailed = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"failed","reason_code":"envelope_invalid"}"#.utf8)),
            endpointPhase: .observerIngest
        )
        let detailOnly = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 422, data: Data(#"{"detail":"cid sha256:aaaa"}"#.utf8)),
            endpointPhase: .observerIngest
        )
        let plainText = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 404, data: Data("missing".utf8)),
            endpointPhase: .observerIngest
        )

        XCTAssertEqual(Self.attentionReason(ingest400)?.journalReasonCode, "day_invalid")
        XCTAssertEqual(Self.attentionReason(save413)?.journalReasonCode, "multipart_part_too_large")
        XCTAssertEqual(Self.attentionReason(ingestFailed)?.journalReasonCode, "envelope_invalid")
        XCTAssertNil(Self.attentionReason(detailOnly)?.journalReasonCode)
        XCTAssertNil(Self.attentionReason(plainText)?.journalReasonCode)
        for outcome in [ingest400, save413, ingestFailed, detailOnly] {
            let detail = Self.attentionReason(outcome)?.ownerSafeDetail ?? ""
            XCTAssertFalse(detail.contains("must be"), detail)
            XCTAssertFalse(detail.contains("limit 1"), detail)
            XCTAssertFalse(detail.contains("sha256:"), detail)
        }
        XCTAssertNil(TransferAttentionReason.removedInJournal.journalReasonCode)

        let longCode = String(repeating: "x", count: 500)
        let bounded = TransferHTTPClassifier.classify(
            result: TransferHTTPResult(statusCode: 400, data: Data(#"{"reason_code":"\#(longCode)"}"#.utf8)),
            endpointPhase: .observerIngest
        )
        XCTAssertEqual(
            Self.attentionReason(bounded)?.journalReasonCode?.count,
            TransferHTTPClassifier.journalReasonCodeMaxLength
        )
    }

    // MARK: - grouping

    func testRefusalsAreGroupedByReasonAndOtherAttentionIsNotCounted() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("grouping", isDirectory: true))
        let seeds: [(Int, String, String, String?)] = [
            (10, TransferAttentionReason.httpClientErrorCode, "reason_code=segment_invalid", "segment_invalid"),
            (11, TransferAttentionReason.httpClientErrorCode, "reason_code=segment_invalid", "segment_invalid"),
            (12, TransferAttentionReason.httpClientErrorCode, "reason_code=day_invalid", "day_invalid"),
            (13, TransferAttentionReason.httpClientErrorCode, "reason_code=segment_invalid", nil),
            (14, "removed_in_journal", "removed", nil),
        ]
        for (index, (id, reason, detail, code)) in seeds.enumerated() {
            try self.seedAttention(
                spool: spool,
                manifest: Self.ingestManifest(itemID: Self.uuid(id), segment: "12000\(index)_3"),
                reason: reason,
                detail: detail,
                journalReasonCode: code,
                movedAt: Self.baseDate.addingTimeInterval(Double(index))
            )
        }
        let engine = self.makeEngine(spool: spool, resolver: TransferEndpointResolverStub(.unavailable("held")))
        try await engine.start()
        let detail = await SourceSyncStateDetail.build(from: engine, sourceKey: Self.sourceKey)
        await engine.pause()

        XCTAssertEqual(detail.attentionItemCount, 5)
        let lines = detail.refusedItems.lines(sourceName: "audio", now: Self.baseDate.addingTimeInterval(600))
        XCTAssertTrue(lines.contains("    segment_invalid: 2"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("    day_invalid: 1"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("    segment_invalid (from stored detail): 1"), lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("removed") }, lines.joined(separator: "\n"))
        XCTAssertEqual(detail.refusedItems.refusals.count, 4)
        XCTAssertFalse(detail.refusedItems.refusals.contains { $0.itemID == Self.uuid(14) })
    }

    // MARK: - escape rule

    func testEscapeRulePinnedOutputs() {
        let cases: [(String, String)] = [
            ("133724_13", #"«133724_13»"#),
            ("13724\u{202F}PM_13", #"«13724\u{202F}PM_13»"#),
            (#"\u{202F}"#, #"«\\u{202F}»"#),
            ("", "«»"),
            ("e\u{301}_1", #"«e\u{0301}_1»"#),
            ("٠١٣٧٢٤_13", #"«\u{0660}\u{0661}\u{0663}\u{0667}\u{0662}\u{0664}_13»"#),
            ("13\u{1F600}", #"«13\u{1F600}»"#),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DiagnosticExportText.delimited(input), expected)
        }
    }

    func testEveryScalarBetweenTheDelimitersIsPrintableASCII() {
        let inputs = [
            "133724_13", "13724\u{202F}PM_13", #"\u{202F}"#, "", "e\u{301}_1", "٠١٣٧٢٤_13", "13\u{1F600}",
            "a\tb\nc\u{7F}d", "«»", "85000\u{00A0}AM_13", "\u{0}", "\u{10FFFF}",
        ]
        for input in inputs {
            let rendered = Array(DiagnosticExportText.delimited(input).unicodeScalars)
            XCTAssertEqual(String(rendered.first.map(Character.init) ?? " "), DiagnosticExportText.openDelimiter)
            XCTAssertEqual(String(rendered.last.map(Character.init) ?? " "), DiagnosticExportText.closeDelimiter)
            for scalar in rendered.dropFirst().dropLast() {
                XCTAssertTrue((0x20...0x7E).contains(scalar.value), "\(input.unicodeScalars.map(\.value)) -> \(scalar.value)")
            }
        }
    }

    func testRefusedShareItemShowsNoIngestMetadataRatherThanAnEmptyKey() throws {
        var share = Self.shareManifest(itemID: Self.uuid(20))
        share.diskState = .attention
        share.attention = TransferAttentionInfo(
            reason: TransferAttentionReason.httpClientErrorCode,
            shortDetail: "that file is too large to bring in.",
            movedAt: Self.baseDate,
            journalReasonCode: "multipart_part_too_large"
        )
        var emptyKey = Self.ingestManifest(itemID: Self.uuid(21), segment: "")
        emptyKey.observerIngest?.day = ""
        emptyKey.diskState = .attention
        emptyKey.attention = TransferAttentionInfo(
            reason: TransferAttentionReason.httpClientErrorCode,
            shortDetail: "reason_code=segment_invalid",
            movedAt: Self.baseDate.addingTimeInterval(1),
            journalReasonCode: "segment_invalid"
        )

        let export = RefusedItemsExport(manifests: [share, emptyKey])
        let shareRefusal = try XCTUnwrap(export.refusals.first { $0.itemID == Self.uuid(20) })
        let emptyRefusal = try XCTUnwrap(export.refusals.first { $0.itemID == Self.uuid(21) })
        let shareFields = RefusedItemsExport.itemFields(shareRefusal, now: Self.baseDate)
        let emptyFields = RefusedItemsExport.itemFields(emptyRefusal, now: Self.baseDate)

        XCTAssertTrue(shareFields.contains("no ingest metadata"), shareFields.joined(separator: ", "))
        XCTAssertFalse(shareFields.contains { $0.contains("«") }, shareFields.joined(separator: ", "))
        XCTAssertFalse(emptyFields.contains("no ingest metadata"), emptyFields.joined(separator: ", "))
        XCTAssertTrue(emptyFields.contains { $0.hasSuffix("«»") }, emptyFields.joined(separator: ", "))
    }

    // MARK: - cap and order

    func testListsTheFiveMostRecentlyRefusedOfAllRefusals() {
        // Created in one order, refused in the reverse order.
        let manifests: [TransferManifest] = (0..<6).map { index in
            var manifest = Self.ingestManifest(
                itemID: Self.uuid(30 + index),
                segment: "10000\(index)_3",
                createdAt: Self.baseDate.addingTimeInterval(Double(index) * 60)
            )
            manifest.diskState = .attention
            manifest.attention = TransferAttentionInfo(
                reason: TransferAttentionReason.httpClientErrorCode,
                shortDetail: "reason_code=segment_invalid",
                movedAt: Self.baseDate.addingTimeInterval(3_600 - Double(index) * 60),
                journalReasonCode: "segment_invalid"
            )
            return manifest
        }
        let lines = RefusedItemsExport(manifests: manifests.shuffled())
            .lines(sourceName: "audio", now: Self.baseDate.addingTimeInterval(7_200))
        let text = lines.joined(separator: "\n")

        XCTAssertTrue(text.contains("5 most recently refused of 6 refusals"), text)
        let itemLines = lines.filter { $0.hasPrefix("    refused ") }
        XCTAssertEqual(itemLines.count, 5, text)
        let expectedOrder = (0..<5).map { "«10000\($0)_3»" }
        for (line, segment) in zip(itemLines, expectedOrder) {
            XCTAssertTrue(line.contains(segment), "\(line) should hold \(segment)")
        }
        XCTAssertTrue(text.contains("«100000_3»"), "the oldest-created item was refused last and is listed")
        XCTAssertFalse(text.contains("«100005_3»"), "the newest-created item was refused first and falls off")
    }

    func testASourceWithoutRefusalsStatesNone() {
        let detail = SourceSyncStateDetail(
            oldestPendingItemCreatedAt: Self.baseDate,
            mostRecentAttention: nil,
            attentionItemCount: 0,
            mostRecentAttentionRetryCount: 0,
            mostRecentAttentionLastRetriedAt: nil,
            refusedItems: RefusedItemsExport(manifests: [])
        )
        let row = SourceSyncStateLine(
            name: "audio", pending: 1, inFlight: 0, attention: 0, delivered: 0,
            lastUploadAt: nil, recentErrorCount: 0, recentErrorDetail: nil, detail: detail
        )
        let lines = syncStateSummaryLines(rows: [row], now: Self.baseDate.addingTimeInterval(60))

        XCTAssertTrue(lines.contains { $0.hasSuffix("refused items: none") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasSuffix("refused by reason: none") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains(RefusedItemsExport.appVersionNote))
    }

    // MARK: - field allowlist

    @MainActor
    func testExportPrintsOnlyTheAllowlistedFieldsOfARefusedItem() async throws {
        let sessionID = Self.uuid(424_242)
        let startedAt = Date(timeIntervalSince1970: 1_111_111_111)
        var manifest = Self.ingestManifest(itemID: Self.uuid(40), segment: "133724_13")
        manifest.meta = .object(["sentinelMetaKey": .string("sentinel-meta-value")])
        manifest.observerIngest?.tz = "Sentinel/Zone"
        manifest.observerIngest?.utcOffsetSeconds = 31_337
        manifest.observerIngest?.startedAt = startedAt
        manifest.observerIngest?.sources = ["sentinel-source"]
        manifest.observerIngest?.platform = "sentinel-platform"
        manifest.observerIngest?.batteryLevel = 0.123456
        manifest.observerIngest?.sessionID = sessionID
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("allowlist", isDirectory: true))
        try self.seedAttention(
            spool: spool,
            manifest: manifest,
            reason: TransferAttentionReason.httpClientErrorCode,
            detail: "reason_code=segment_invalid",
            journalReasonCode: "segment_invalid",
            movedAt: Self.baseDate
        )
        var noVersion = Self.ingestManifest(itemID: Self.uuid(41), segment: "133725_13")
        noVersion.appVersion = nil
        try self.seedAttention(
            spool: spool,
            manifest: noVersion,
            reason: TransferAttentionReason.httpClientErrorCode,
            detail: "reason_code=day_invalid",
            journalReasonCode: nil,
            movedAt: Self.baseDate.addingTimeInterval(1)
        )
        var share = Self.shareManifest(itemID: Self.uuid(42))
        share.meta = .object(["sentinelMetaKey": .string("sentinel-meta-value")])
        try self.seedAttention(
            spool: spool,
            manifest: share,
            reason: TransferAttentionReason.httpClientErrorCode,
            detail: "that file is too large to bring in.",
            journalReasonCode: "multipart_part_too_large",
            movedAt: Self.baseDate.addingTimeInterval(2)
        )
        let engine = self.makeEngine(spool: spool, resolver: TransferEndpointResolverStub(.unavailable("held")))
        try await engine.start()

        let export = try await self.exportText(
            engine: engine,
            sources: [("audio", Self.sourceKey), ("share", Self.shareSourceKey)],
            now: Self.baseDate.addingTimeInterval(7_384)
        )
        await engine.pause()

        let iso = ISO8601DateFormatter()
        let sentinels = [
            "Sentinel/Zone", "31337", "1111111111", iso.string(from: startedAt), "2005-03-18",
            "sentinelMetaKey", "sentinel-meta-value", "sentinel-source", "sentinel-platform", "0.123456",
            sessionID.uuidString, sessionID.uuidString.lowercased(),
        ]
        for sentinel in sentinels {
            XCTAssertFalse(export.contains(sentinel), "export leaked \(sentinel)")
        }

        let grammar = try NSRegularExpression(pattern: #"""
            ^    refused [0-9]+(s|m|h[0-9]+m) ago, app (not recorded|[\x20-\x2B\x2D-\x7E]+), (day «[\x20-\x7E]*», segment «[\x20-\x7E]*»|no ingest metadata), reason [\x20-\x7E]+$
            """#)
        let itemLines = export.components(separatedBy: "\n").filter { $0.hasPrefix("    refused ") }
        XCTAssertEqual(itemLines.count, 3, export)
        for line in itemLines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            XCTAssertNotNil(grammar.firstMatch(in: line, range: range), "off-grammar item line: \(line)")
        }
        XCTAssertTrue(itemLines.contains { $0.contains("app not recorded") }, itemLines.joined(separator: "\n"))
        XCTAssertTrue(itemLines.contains { $0.contains("no ingest metadata") }, itemLines.joined(separator: "\n"))
        XCTAssertEqual(export.components(separatedBy: RefusedItemsExport.appVersionNote).count, 2, "the note appears once")
    }

    // MARK: - persistence

    func testAttentionRecordRoundTripsThroughTheSpoolCoder() throws {
        let fixture = #"{"appVersion":"1.0.0","attention":{"movedAt":"2024-04-20T15:00:00Z","reason":"http_client_error","shortDetail":"reason_code=segment_invalid"},"createdAt":"2024-04-20T14:40:00Z","diskState":"attention","endpoint":{"destinationKind":"observer_ingest","path":"\/app\/devices\/ingest"},"itemID":"00000000-0000-0000-0000-000000000050","meta":{},"observerIngest":{"day":"20240420","durationS":13,"ingestProtocolVersion":3,"platform":"ios","segment":"144000_13","sources":["audio"],"startedAt":"2024-04-20T14:40:00Z"},"payloadParts":[{"contentType":"audio\/mp4","filename":"audio.m4a","kind":"audio","partID":"audio","relativePath":"audio.m4a","requiredForDispatch":true}],"priority":{"basePriority":"normal","sourceKey":"audio","userInitiated":false},"retryCount":0,"schemaVersion":"solstone.transfer.item\/1","source":"audio"}"#

        let decoded = try TransferSpool.decoder().decode(TransferManifest.self, from: Data(fixture.utf8))
        XCTAssertNil(decoded.attention?.journalReasonCode)
        XCTAssertEqual(String(decoding: try TransferSpool.encoder().encode(decoded), as: UTF8.self), fixture)

        var withCode = decoded
        withCode.attention?.journalReasonCode = "segment_invalid"
        let encoded = try TransferSpool.encoder().encode(withCode)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""journalReasonCode":"segment_invalid""#))
        let roundTripped = try TransferSpool.decoder().decode(TransferManifest.self, from: encoded)
        XCTAssertEqual(roundTripped, withCode)
        XCTAssertEqual(try TransferSpool.encoder().encode(roundTripped), encoded)
    }

    // MARK: - export timestamps

    @MainActor
    func testExportTimesStay24HourUnderAForced12HourClock() async throws {
        let probeInstant = Date(timeIntervalSince1970: 1_713_628_644)
        func probe() -> String {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "HH"
            return formatter.string(from: probeInstant)
        }
        let key = "AppleICUForce12HourTime"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            Self.postClockPreferencesChanged()
        }
        UserDefaults.standard.set(true, forKey: key)
        Self.postClockPreferencesChanged()
        let forced = await Self.waitUntil { probe() != "15" }
        guard forced else {
            return XCTFail("a forced 12-hour clock was not applied, so this test would prove nothing")
        }

        let eventTime = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: .current,
            year: 2024, month: 4, day: 20, hour: 13, minute: 37, second: 24
        ).date)
        let log = DiagnosticLog()
        log.append(DiagnosticEvent(category: .upload, message: "probe event", timestamp: eventTime))

        let lines = log.snapshot(tunnel: TunnelManager()).components(separatedBy: "\n")

        let stamp = try NSRegularExpression(pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [\x21-\x7E]+$"#)
        let header = lines[1]
        XCTAssertNotNil(stamp.firstMatch(in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)), header)
        let eventLine = try XCTUnwrap(lines.first { $0.contains("probe event") })
        XCTAssertTrue(eventLine.hasPrefix("[2024-04-20 13:37:24 "), eventLine)
        XCTAssertTrue(eventLine.unicodeScalars.allSatisfy(\.isASCII), eventLine)
        XCTAssertTrue(header.unicodeScalars.allSatisfy(\.isASCII), header)

        UserDefaults.standard.removeObject(forKey: key)
        Self.postClockPreferencesChanged()
        _ = await Self.waitUntil { probe() == "15" }
    }

    // MARK: - duration totality

    func testDurationLabelIsTotal() {
        XCTAssertNil(LinkedDeviceIngestViewMapper.durationLabel(forSegmentKey: "140535_9223372036854775807"))
        XCTAssertNotNil(LinkedDeviceIngestViewMapper.durationLabel(forSegmentKey: "140535_3"))
        for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300, -Double.greatestFiniteMagnitude] {
            XCTAssertNil(OnThisPhoneItem.formattedDuration(value), "\(value)")
        }
        XCTAssertNotNil(OnThisPhoneItem.formattedDuration(3))
        XCTAssertNotNil(OnThisPhoneItem.formattedDuration(-3))
        XCTAssertNil(OnThisPhoneItem.formattedDuration(nil))
    }
}

private extension RefusedItemsExportTests {
    static let baseDate = Date(timeIntervalSince1970: 1_713_624_000)
    static let sourceKey = "audio"
    static let shareSourceKey = "share"
    static let audioPayloads = ["audio": Data("audio".utf8)]

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    static func attentionReason(_ outcome: TransferOutcome) -> TransferAttentionReason? {
        guard case .terminalAttention(let reason) = outcome else { return nil }
        return reason
    }

    static func ingestManifest(
        itemID: UUID,
        segment: String,
        createdAt: Date = RefusedItemsExportTests.baseDate
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: Self.sourceKey,
            createdAt: createdAt,
            priority: TransferPriorityInputs(sourceKey: Self.sourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "audio",
                    kind: .audio,
                    relativePath: "audio.m4a",
                    filename: "audio.m4a",
                    contentType: "audio/mp4"
                ),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                segment: segment,
                day: "20240420",
                startedAt: createdAt,
                durationS: 13,
                sources: ["audio"],
                ingestProtocolVersion: 3
            ),
            appVersion: "1.0.0"
        )
    }

    static func shareManifest(itemID: UUID) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: Self.shareSourceKey,
            createdAt: Self.baseDate,
            priority: TransferPriorityInputs(sourceKey: Self.shareSourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "file",
                    kind: .file,
                    relativePath: "file.txt",
                    filename: "file.txt",
                    contentType: "text/plain"
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: "/app/import/save",
                startPath: "/app/import/start"
            ),
            saveThenStart: TransferSaveThenStartState(phase: .savePending),
            appVersion: "1.0.0"
        )
    }

    func makeEngine(
        spool: TransferSpool? = nil,
        resolver: any TransferEndpointResolver = TransferEndpointResolverStub(
            .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
        )
    ) -> TransferEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        return TransferEngine(
            spool: spool ?? TransferSpool(rootURL: self.tempDirectory),
            transport: TransferTransport(sessionConfiguration: configuration),
            endpointResolver: resolver,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate)
        )
    }

    func seedAttention(
        spool: TransferSpool,
        manifest: TransferManifest,
        reason: String,
        detail: String,
        journalReasonCode: String?,
        movedAt: Date
    ) throws {
        let payloads = manifest.payloadParts.reduce(into: [String: Data]()) { $0[$1.partID] = Data("x".utf8) }
        let staged = try spool.stage(manifest: manifest, payloads: payloads)
        let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        _ = try spool.moveQueuedItemToAttention(
            queued,
            reason: reason,
            detail: detail,
            journalReasonCode: journalReasonCode,
            now: movedAt
        )
    }

    func storedAttentionManifestText(itemID: UUID) throws -> String {
        let manifestURL = TransferSpool(rootURL: self.tempDirectory).attentionDirectoryURL
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent(TransferSpool.manifestFilename, isDirectory: false)
        return try String(contentsOf: manifestURL, encoding: .utf8)
    }

    /// The exported file's text for the given sources' sync state, through the real export path.
    @MainActor
    func exportText(
        engine: TransferEngine,
        sources: [(name: String, key: String)] = [("audio", RefusedItemsExportTests.sourceKey)],
        now: Date
    ) async throws -> String {
        var rows: [SourceSyncStateLine] = []
        for source in sources {
            let detail = await SourceSyncStateDetail.build(from: engine, sourceKey: source.key)
            rows.append(SourceSyncStateLine(
                name: source.name, pending: 0, inFlight: 0, attention: detail.attentionItemCount, delivered: 0,
                lastUploadAt: nil, recentErrorCount: 0, recentErrorDetail: nil, detail: detail
            ))
        }
        let lines = syncStateSummaryLines(rows: rows, now: now)
        let url = try XCTUnwrap(DiagnosticLog().exportFileURL(tunnel: TunnelManager(), syncState: lines))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The lines of the "sync state by source" block in an exported file.
    static func syncStateSection(of export: String) throws -> [String] {
        let lines = export.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "--- sync state by source ---"))
        let end = try XCTUnwrap(lines[start...].firstIndex(of: "---"))
        return Array(lines[(start + 1)..<end])
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    /// The system's own signal that clock preferences changed; the process re-reads them.
    static func postClockPreferencesChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("AppleDatePreferencesChangedNotification" as CFString),
            nil,
            nil,
            true
        )
    }

    @MainActor
    static func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
