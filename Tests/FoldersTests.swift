// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO
import XCTest
@testable import solstone_swift

private nonisolated final class StubFolderClock: FolderClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _ms: Int64
    private let offset: Int
    var timeZone: TimeZone { TimeZone(secondsFromGMT: self.offset)! }

    init(ms: Int64, offsetSeconds: Int = 0) {
        self._ms = ms
        self.offset = offsetSeconds
    }

    func nowMs() -> Int64 {
        self.lock.withLock { self._ms }
    }

    func offsetSeconds(at ms: Int64) -> Int {
        self.offset
    }

    func advance(ms delta: Int64) {
        self.lock.withLock { self._ms += delta }
    }
}

private nonisolated final class StubFoldersTransport: FoldersTransport, @unchecked Sendable {
    private let lock = NSLock()
    var capability: Bool? = true
    var facets: (FolderFacetsAvailability, [FolderFacet]) = (.ready, [
        FolderFacet(name: "personal", title: "Personal", color: "#2f6fdd"),
        FolderFacet(name: "work", title: "Work", color: "#9A5B25"),
    ])
    var supported: FolderSupportedList? = .default
    var estimate: FolderBackfillEstimate? = FolderBackfillEstimate(
        segments: 2, days: 1, thoughts: 2, alreadyInJournal: 0, fromJournal: true
    )
    var nextOutcomes: [FolderDeliveryOutcome] = []
    private(set) var uploaded: [FolderSegmentDelivery] = []
    private(set) var estimateCalls: [(String, [FolderEstimateItem])] = []

    func checkCapability() async -> Bool? {
        self.lock.withLock { self.capability }
    }

    func fetchFacets() async -> (FolderFacetsAvailability, [FolderFacet]) {
        self.lock.withLock { self.facets }
    }

    func fetchSupported() async -> FolderSupportedList? {
        self.lock.withLock { self.supported }
    }

    func fetchEstimate(folderID: String, items: [FolderEstimateItem]) async -> FolderBackfillEstimate? {
        self.lock.withLock {
            self.estimateCalls.append((folderID, items))
            return self.estimate
        }
    }

    func uploadSegment(
        _ delivery: FolderSegmentDelivery,
        supported: FolderSupportedList,
        canSend: @escaping @Sendable () async -> Bool,
        readContent: @escaping @Sendable (FolderStagedContentFile) -> Data?
    ) async -> FolderDeliveryOutcome {
        guard await canSend() else { return .hold }
        // Exercise content reading just like the live client does.
        for staged in delivery.contentFiles {
            _ = readContent(staged)
        }
        return self.lock.withLock {
            self.uploaded.append(delivery)
            if !self.nextOutcomes.isEmpty {
                return self.nextOutcomes.removeFirst()
            }
            return .delivered
        }
    }

    func recordedUploads() -> [FolderSegmentDelivery] {
        self.lock.withLock { self.uploaded }
    }
}

private nonisolated final class ThreadCheckingFileSystem: FolderFileSystem, @unchecked Sendable {
    private let inner = LiveFolderFileSystem()
    private let lock = NSLock()
    private(set) var walkedOnMainThread = false
    var forceIncomplete = false

    func probePickedFolder(url: URL) throws -> FolderProbeResult {
        try self.inner.probePickedFolder(url: url)
    }

    func walk(bookmarkData: Data?, fallbackPath: String, isCloudProvider: Bool) throws -> FolderWalkOutcome {
        let onMain = Thread.isMainThread
        self.lock.withLock {
            if onMain { self.walkedOnMainThread = true }
        }
        var outcome = try self.inner.walk(bookmarkData: bookmarkData, fallbackPath: fallbackPath, isCloudProvider: isCloudProvider)
        if self.forceIncomplete {
            outcome.complete = false
            outcome.unreadable += 1
        }
        return outcome
    }

    func readFile(bookmarkData: Data?, fallbackPath: String, relPath: String, maxBytes: UInt64) throws -> Data? {
        try self.inner.readFile(bookmarkData: bookmarkData, fallbackPath: fallbackPath, relPath: relPath, maxBytes: maxBytes)
    }

    func fileExists(bookmarkData: Data?, fallbackPath: String, relPath: String) -> Bool {
        self.inner.fileExists(bookmarkData: bookmarkData, fallbackPath: fallbackPath, relPath: relPath)
    }

    func fileMetadata(bookmarkData: Data?, fallbackPath: String, relPath: String) -> FolderPlatformMetadata? {
        self.inner.fileMetadata(bookmarkData: bookmarkData, fallbackPath: fallbackPath, relPath: relPath)
    }
}

final class FoldersTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in self.tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        self.tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folders-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDirs.append(dir)
        return dir
    }

    private func writeFile(_ url: URL, data: Data, mtimeMs: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let date = Date(timeIntervalSince1970: Double(mtimeMs) / 1_000.0)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeTinyGIF() -> Data {
        // Minimal 1x1 GIF89a image.
        Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
        ])
    }

    // MARK: - Classification & Triage Ruleset 8

    func testPartialsJunkAndICloudStubsFilteredDeterministically() {
        XCTAssertTrue(FoldersClassifier.isPartialDownload("installer.dmg.crdownload"))
        XCTAssertTrue(FoldersClassifier.isPartialDownload("archive.tar.part"))
        XCTAssertTrue(FoldersClassifier.isPartialDownload("movie.mp4.download"))
        XCTAssertTrue(FoldersClassifier.isPartialDownload("doc.pdf.filepart"))
        XCTAssertTrue(FoldersClassifier.isPartialDownload("draft.tmp"))
        XCTAssertFalse(FoldersClassifier.isPartialDownload("report.pdf"))

        XCTAssertTrue(FoldersClassifier.isJunkEntry(".DS_Store"))
        XCTAssertTrue(FoldersClassifier.isJunkEntry(".git"))
        XCTAssertTrue(FoldersClassifier.isJunkEntry("Thumbs.db"))
        XCTAssertTrue(FoldersClassifier.isJunkEntry("~$contract.docx"))
        XCTAssertTrue(FoldersClassifier.isJunkEntry("notes.md~"))
        XCTAssertFalse(FoldersClassifier.isJunkEntry("todo.md"))

        XCTAssertTrue(FoldersClassifier.isICloudStubName(".report.pdf.icloud"))
        XCTAssertFalse(FoldersClassifier.isICloudStubName(".icloud"))
        XCTAssertFalse(FoldersClassifier.isICloudStubName("report.pdf"))
    }

    func testSortingTableRoutesKindsRespects64MiBCapAndSwitches() {
        let supported = FolderSupportedList.default
        let allOn = FolderKinds.allOn

        func assertClass(
            _ ext: String?,
            _ size: UInt64,
            screenshot: Bool = false,
            bytes: Data? = nil,
            kinds: FolderKinds = allOn,
            expectedKind: FolderFileKind,
            expectedDelivery: FolderDeliveryMode
        ) {
            let (kind, delivery) = FoldersClassifier.classifyFile(
                extensionLower: ext,
                sizeBytes: size,
                isScreenshot: screenshot,
                noteBytes: bytes,
                kinds: kinds,
                supported: supported
            )
            XCTAssertEqual(kind, expectedKind)
            XCTAssertEqual(delivery, expectedDelivery)
        }

        assertClass("md", 120, bytes: Data("short note".utf8), expectedKind: .note, expectedDelivery: .content)
        assertClass("pdf", 400_000, expectedKind: .document, expectedDelivery: .content)
        assertClass("vtt", 8_000, expectedKind: .transcript, expectedDelivery: .content)
        assertClass("png", 50_000, screenshot: true, expectedKind: .screenshot, expectedDelivery: .content)
        assertClass("png", 50_000, screenshot: false, expectedKind: .photo, expectedDelivery: .content)
        // Unsupported binary / office files -> metadataOnly when `other` is on.
        assertClass("docx", 120_000, expectedKind: .other, expectedDelivery: .metadataOnly)
        assertClass("bin", 10_000, expectedKind: .other, expectedDelivery: .metadataOnly)
        // Over 64 MiB -> metadataOnly even for PDF.
        assertClass("pdf", supported.maxContentBytes + 1, kinds: FolderKinds(other: false), expectedKind: .document, expectedDelivery: .metadataOnly)
        // Turning off documents with `other` on falls back to metadataOnly; both off ignores.
        var noDocs = allOn
        noDocs.documents = false
        assertClass("pdf", 10_000, kinds: noDocs, expectedKind: .document, expectedDelivery: .metadataOnly)
        noDocs.other = false
        assertClass("pdf", 10_000, kinds: noDocs, expectedKind: .document, expectedDelivery: .ignore)
    }

    @MainActor
    func testStructuredExportLargerThanANoteKeepsItsTranscriptBytes() async throws {
        let root = try self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentence = String(repeating: "conversation ", count: 512)
        let rows = (0..<640).map { "\($0 * 1000)\t\($0 * 1000 + 999)\t\(sentence)" }
        let data = Data(("start\tend\ttext\n" + rows.joined(separator: "\n")).utf8)
        var rules = FolderSupportedList.default
        rules.transcriptExtensions.insert("tsv")
        XCTAssertGreaterThan(UInt64(data.count), rules.maxNoteBytes)
        let now: Int64 = 1_795_700_000_000
        try self.writeFile(folder.appendingPathComponent("interview.tsv"), data: data, mtimeMs: now - 600_000)
        let transport = StubFoldersTransport()
        transport.supported = rules
        let engine = FoldersEngine(store: FoldersStore(fileURL: root.appendingPathComponent("ledger.json")),
                                   transport: transport, clock: StubFolderClock(ms: now))
        engine.isPairedProvider = { true }
        let selected = await engine.handlePickedFolder(url: folder)
        let id = try XCTUnwrap(selected)
        await engine.refreshJournalMetadata()
        engine.setKinds(folderID: id, kinds: FolderKinds(notes: false, other: false))
        let confirmed = await engine.confirmFolder(folderID: id, range: .everything)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(transport.recordedUploads().flatMap(\.contentFiles).map(\.relPath), ["interview.tsv"])
        XCTAssertEqual(engine.folder(id: id)?.files["interview.tsv"]?.kind, .transcript)
    }

    func testStructuredAndLongMarkdownPromoteToDocument() {
        let supported = FolderSupportedList.default
        var structured = "# Chapter One\n\n## Section A\n\n"
        for _ in 0..<1_500 {
            structured += "prose "
        }
        XCTAssertEqual(FoldersClassifier.classifyTextFile(Data(structured.utf8), supported: supported), .document)

        let shortNote = Data("# Todo\n\n- check build\n- ship\n".utf8)
        XCTAssertEqual(FoldersClassifier.classifyTextFile(shortNote, supported: supported), .note)
    }

    func testNoteNetLineDiffDetectsRealChangesAndSuppressesReverts() {
        XCTAssertNil(FoldersClassifier.netLineDiff(before: "a\nb\n", after: "a\nb\n"))
        let diff = FoldersClassifier.netLineDiff(
            before: "first\nsecond\nthird\n",
            after: "first\nsecond revised\nthird\nfourth\n"
        )
        XCTAssertNotNil(diff)
        XCTAssertTrue(diff!.contains("- second\n"))
        XCTAssertTrue(diff!.contains("+ second revised\n"))
        XCTAssertTrue(diff!.contains("+ fourth\n"))
    }

    func testOverlapDetectionAndFolderIDFormat() {
        let outcomeObsidian = FoldersClassifier.detectOverlap(
            candidateCanonicalPath: "/var/mobile/Vault/sub",
            obsidianVault: (canonicalPath: "/var/mobile/Vault", name: "field notes"),
            existingFolders: []
        )
        XCTAssertEqual(outcomeObsidian, .overlap(.obsidian(name: "field notes")))

        let outcomeDup = FoldersClassifier.detectOverlap(
            candidateCanonicalPath: "/var/mobile/Downloads",
            obsidianVault: nil,
            existingFolders: [(id: "downloads-12345678", canonicalPath: "/var/mobile/Downloads", name: "Downloads")]
        )
        XCTAssertEqual(outcomeDup, .alreadyAdded(id: "downloads-12345678", name: "Downloads"))

        let outcomeChild = FoldersClassifier.detectOverlap(
            candidateCanonicalPath: "/var/mobile/Downloads/Receipts",
            obsidianVault: nil,
            existingFolders: [(id: "downloads-12345678", canonicalPath: "/var/mobile/Downloads", name: "Downloads")]
        )
        XCTAssertEqual(outcomeChild, .overlap(.folder(id: "downloads-12345678", name: "Downloads")))

        let id = FoldersClassifier.makeFolderID(name: "My Work Docs!", canonicalPath: "/tmp/My Work Docs!")
        XCTAssertLessThanOrEqual(id.count, 64)
        XCTAssertNotNil(id.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression))
    }

    func testRangeUsesCivilMidnightAcrossDSTAndMonthEnds() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let iso = ISO8601DateFormatter()
        func ms(_ s: String) throws -> Int64 {
            Int64(try XCTUnwrap(iso.date(from: s)).timeIntervalSince1970 * 1_000)
        }
        let now = try ms("2024-08-31T17:45:00Z")
        XCTAssertEqual(FolderBackfillRange.fromToday.startMs(nowMs: now, timeZone: tz), try ms("2024-08-31T06:00:00Z"))
        XCTAssertEqual(FolderBackfillRange.last30Days.startMs(nowMs: now, timeZone: tz), try ms("2024-08-01T06:00:00Z"))
        XCTAssertEqual(FolderBackfillRange.last6Months.startMs(nowMs: now, timeZone: tz), try ms("2024-02-29T07:00:00Z"))
        let leap = try ms("2024-02-29T18:00:00Z")
        XCTAssertEqual(FolderBackfillRange.lastYear.startMs(nowMs: leap, timeZone: tz), try ms("2023-02-28T07:00:00Z"))
    }

    // MARK: - Protocol-v3 Wire Conformance

    func testParsesSupportedFacetsAndEstimatePayloads() throws {
        let supportedRaw = Data("""
        {
          "version": 1,
          "ruleset_version": 8,
          "window_seconds": 300,
          "max_file_bytes": 67108864,
          "max_note_bytes": 4194304,
          "max_image_pixels": 67108864,
          "document_revision_cooldown_seconds": 3600,
          "kinds": {
            "notes": { "extensions": ["md", "markdown", "txt", "log"], "mode": "first_sight_and_net_change" },
            "documents": {
              "extensions": ["pdf", "md", "markdown", "txt", "log"],
              "mode": "each_revision",
              "thresholds": {
                "structured_prose_min_words": 1500,
                "structured_prose_min_heading_levels": 2,
                "long_prose_min_words": 5000
              }
            },
            "transcripts": { "extensions": ["vtt", "srt", "txt"], "mode": "each_revision" },
            "screenshots": { "extensions": ["png", "jpg", "jpeg", "webp"], "convert_to_png_on_device": ["heic", "gif"], "mode": "once" },
            "photos": { "extensions": ["png", "jpg", "jpeg", "webp"], "convert_to_png_on_device": ["heic", "gif"], "mode": "once" },
            "other": { "extensions": [], "mode": "metadata_only" }
          }
        }
        """.utf8)
        let parsed = try XCTUnwrap(FoldersWire.parseSupportedList(supportedRaw))
        XCTAssertTrue(parsed.fromJournal)
        XCTAssertEqual(parsed.rulesetVersion, 8)
        XCTAssertEqual(parsed.maxContentBytes, 67_108_864)
        XCTAssertEqual(parsed.maxNoteBytes, 4_194_304)
        XCTAssertEqual(parsed.maxImagePixels, 67_108_864)
        XCTAssertEqual(parsed.documentRevisionCooldownMs, 3_600_000)
        XCTAssertTrue(parsed.documentExtensions.contains("pdf"))
        XCTAssertFalse(parsed.documentExtensions.contains("docx"))
        XCTAssertTrue(parsed.transcriptExtensions.contains("vtt"))
        XCTAssertTrue(parsed.convertibleImageExtensions.contains("heic"))

        let border = String(repeating: "=", count: 62)
        let examples: [(String, String)] = [
            ("log", "--- Log opened Tue Sep 3 00:00:00 2024\n00:00 -!- lio has joined\n00:01 <@lio> Ready.\n00:01 < val> Over here.\n00:02 <@lio> Coming."),
            ("txt", "\(border)\nGuild: Potters\nChannel: firing\n\(border)\n[4/7/2025 10:02 AM] lio\nReady.\n[4/7/2025 10:03 AM] val\nComing.\n\(border)\nExported 2 message(s)\n\(border)"),
            ("txt", "Unknown Speaker  0:04\nThe wind is picking up.\nUnknown Speaker  2:13\nThe smaller boats have tied up.\nTranscribed by https://otter.ai"),
            ("txt", "\u{200e}[17/08/2025, 09:01:01] Pia: Where is the shelf?\n[17/08/2025, 09:01:03] Ivo: Around the corner."),
            ("txt", "8/17/25, 9:01 AM - Pia: Where is it?\n8/17/25, 9:02\u{202f}AM - Ivo: At the shop."),
            ("json", #"{"language":"en","text":"hi","segments":[{"start":0,"end":1,"text":"hi"}]}"#),
            ("json", #"{"text":"hi","segments":[{"speaker":"A","start":0,"end":2,"text":"hi"}]}"#),
            ("json", #"{"version":"1.0","segments":[{"startTime":0,"endTime":1,"body":"hi"}]}"#),
            ("json", #"[{"type":"message","ts":"1730000000.000123","user":"A","text":"hi"}]"#),
            ("json", #"{"type":"personal_chat","messages":[{"type":"message","date_unixtime":"1730000000","text":"hi"}]}"#),
            ("tsv", "start\tend\ttext\n0\t120\tReady."),
            ("csv", "Speaker,Start Time,End Time,Sentence\nA,00:01,00:03,\"Hello, there\""),
            ("html", #"<div class="page_body chat_page"><div class="history"><div class="message default"><div class="text">Hi</div></div></div></div>"#),
            ("md", "**User:** Hello\n**Assistant:** Here I am."),
            ("txt", "10:07:10 From Ivo : Hold it.\n10:07:12 From Pia to Everyone : Holding.")
        ]
        for (ext, item) in examples {
            XCTAssertTrue(FolderTranscriptLayout.recognizes(ext, data: Data(item.utf8)))
        }
        for (ext, item) in [("json", #"{"rows":[{"text":"hi"}]}"#), ("csv", "name,items\nA,2"),
                            ("tsv", "start\tend\ttext\nabc\t123\tbroken"), ("html", "<p>message history text</p>"),
                            ("txt", "Unknown Speaker  0:04\nWind.\nUnknown Speaker  2:13\nBoats."),
                            ("txt", "I meant to find this later.\nTranscribed by https://otter.ai"),
                            ("txt", "Guild: Potters\nChannel: firing\n[4/7/2025 10:02 AM] lio\nReady."),
                            ("log", "Kiln maintenance notes\n00:01 <@lio> Ready.\n00:02 < val> Over here.\n00:03 <@lio> Coming."),
                            ("txt", "Groceries:\nBread\nMilk")] {
            XCTAssertFalse(FolderTranscriptLayout.recognizes(ext, data: Data(item.utf8)))
        }
        let facetsRaw = Data("""
        {
          "facets": [
            { "name": "work", "title": "Work", "color": "#2f6fdd" },
            { "name": "muted_one", "title": "Muted", "muted": true },
            { "name": "personal", "title": "Personal" }
          ]
        }
        """.utf8)
        let facets = try XCTUnwrap(FoldersWire.parseFacets(facetsRaw))
        XCTAssertEqual(facets.map(\.name), ["personal", "work"])

        let estimateRaw = Data("""
        {
          "items": 4,
          "segments": 2,
          "days": 1,
          "thoughts": 3,
          "already_in_journal": 1
        }
        """.utf8)
        let est = try XCTUnwrap(FoldersWire.parseEstimate(estimateRaw))
        XCTAssertEqual(est, FolderBackfillEstimate(segments: 2, days: 1, thoughts: 3, alreadyInJournal: 1, fromJournal: true))
    }

    func testMultipartBuilderConformsToProtocolV3AndConvertsGIFToPNG() throws {
        let t0: Int64 = 1_795_702_000_000 // 2026-11-27T14:06:40Z
        let stamp = FolderStamp(ms: t0, offsetSeconds: 0)
        let win = stamp.window()
        let gifBytes = self.makeTinyGIF()

        let evNote = FolderPendingEvent(
            id: "ev-note",
            relPath: "notes/plan.md",
            verb: .added,
            kind: .note,
            delivery: .content,
            eventMs: t0,
            observedMs: t0 + 1_000,
            offsetSeconds: 0,
            window: win,
            windowEndMs: stamp.windowEndMs(),
            metadata: FolderPlatformMetadata(
                sizeBytes: 12,
                modifiedMs: t0,
                extensionLower: "md",
                originURL: "https://example.org/plan.md",
                downloadedBy: "Safari"
            ),
            contentHash: folderSHA256Hex(Data("hello world\n".utf8)),
            notePayload: "hello world\n"
        )
        let evGif = FolderPendingEvent(
            id: "ev-gif",
            relPath: "images/tiny.gif",
            verb: .added,
            kind: .photo,
            delivery: .content,
            eventMs: t0 + 1_000,
            observedMs: t0 + 2_000,
            offsetSeconds: 0,
            window: win,
            windowEndMs: stamp.windowEndMs(),
            metadata: FolderPlatformMetadata(sizeBytes: UInt64(gifBytes.count), modifiedMs: t0 + 1_000, extensionLower: "gif"),
            contentHash: folderSHA256Hex(gifBytes)
        )
        let evRemoved = FolderPendingEvent(
            id: "ev-rem",
            relPath: "old/gone.pdf",
            verb: .removed,
            kind: .document,
            delivery: .metadataOnly,
            eventMs: t0 + 2_000,
            observedMs: t0 + 2_000,
            offsetSeconds: 0,
            window: win,
            windowEndMs: stamp.windowEndMs(),
            metadata: FolderPlatformMetadata(sizeBytes: 100, modifiedMs: t0 + 2_000, extensionLower: "pdf")
        )
        let evRenamed = FolderPendingEvent(
            id: "ev-ren",
            relPath: "docs/final.pdf",
            previousPath: "docs/draft.pdf",
            verb: .renamed,
            kind: .document,
            delivery: .metadataOnly,
            eventMs: t0 + 3_000,
            observedMs: t0 + 3_000,
            offsetSeconds: 0,
            window: win,
            windowEndMs: stamp.windowEndMs(),
            metadata: FolderPlatformMetadata(sizeBytes: 100, modifiedMs: t0 + 3_000, extensionLower: "pdf")
        )

        let delivery = FolderSegmentDelivery(
            folderID: "desktop-b2c3d4e5",
            folderName: "Desktop",
            facet: "work",
            kinds: .allOn,
            window: win,
            events: [evNote, evGif, evRemoved, evRenamed],
            contentFiles: [
                FolderStagedContentFile(
                    eventID: "ev-note",
                    relPath: "notes/plan.md",
                    kind: .note,
                    extensionLower: "md",
                    contentHash: evNote.contentHash,
                    notePayload: "hello world\n",
                    isRevision: false,
                    needsImageConvert: false
                ),
                FolderStagedContentFile(
                    eventID: "ev-gif",
                    relPath: "images/tiny.gif",
                    kind: .photo,
                    extensionLower: "gif",
                    contentHash: evGif.contentHash,
                    notePayload: nil,
                    isRevision: false,
                    needsImageConvert: true
                ),
            ]
        )

        XCTAssertThrowsError(try FoldersWire.buildMultipartBody(
            delivery: delivery, supported: .default, boundary: "BOUNDARY",
            readContent: { _ in nil }
        ), "a cached note cannot be sent once its file has disappeared")

        let built = try FoldersWire.buildMultipartBody(
            delivery: delivery,
            supported: .default,
            boundary: "BOUNDARY",
            readContent: { staged in
                staged.eventID == "ev-gif" ? gifBytes : Data("hello world\n".utf8)
            }
        )

        XCTAssertTrue(built.activityFileName.hasPrefix("folder_"))
        XCTAssertTrue(built.activityFileName.hasSuffix(".jsonl"))
        XCTAssertEqual(built.partNames, [built.activityFileName, "c_01.md", "c_02.png"])

        let bodyStr = String(decoding: built.body, as: UTF8.self)
        XCTAssertTrue(bodyStr.contains("\"source\":\"folder\""))
        XCTAssertTrue(bodyStr.contains("\"id\":\"desktop-b2c3d4e5\""))
        XCTAssertTrue(bodyStr.contains("\"facet\":\"work\""))
        XCTAssertTrue(bodyStr.contains("\"previous_path\":\"docs/draft.pdf\""))
        XCTAssertTrue(bodyStr.contains("\"origin_url\":\"https:\\/\\/example.org\\/plan.md\"") || bodyStr.contains("\"origin_url\":\"https://example.org/plan.md\""))
        XCTAssertTrue(bodyStr.contains("\"part\":\"c_01.md\""))
        XCTAssertTrue(bodyStr.contains("\"part\":\"c_02.png\""))
    }

    func testUploadReplyClassificationCoversContractAnswersTable() {
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(statusCode: 200, body: Data(#"{"status":"ok"}"#.utf8)),
            .delivered
        )
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(statusCode: 200, body: Data(#"{"status":"duplicate"}"#.utf8)),
            .delivered
        )
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(
                statusCode: 200,
                body: Data(#"{"status":"ok","refused_files":[{"path":"bad.pdf","part":"c_01.pdf","reason_code":"folder_file_invalid"}]}"#.utf8)
            ),
            .deliveredWithRefusedContent(["bad.pdf"])
        )
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(
                statusCode: 400,
                body: Data(#"{"reason_code":"folder_file_invalid","refused_files":[{"path":"corrupt.pdf"}]}"#.utf8)
            ),
            .allFilesRefused(["corrupt.pdf"])
        )
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(statusCode: 400, body: Data(#"{"reason_code":"folder_invalid"}"#.utf8)),
            .invalidPermanent
        )
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(statusCode: 400, body: Data(#"{"reason_code":"folder_ahead"}"#.utf8)),
            .hold
        )
        XCTAssertEqual(
            FoldersWire.classifyUploadReply(statusCode: 503, body: Data(#"{"reason_code":"journal_read_failed"}"#.utf8)),
            .hold
        )
    }

    // MARK: - End-to-End Engine Scenarios (Real Temp Directories)

    @MainActor
    func testPreviewSendsNothingConfirmDeliversAndSkipsPartialsJunkAndICloudStubs() async throws {
        let root = try self.makeTempDir()
        let folderDir = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let tBase: Int64 = 1_795_689_600_000 // 2026-11-27T10:40:00Z
        let clock = StubFolderClock(ms: tBase + 360_000) // 10:46:00Z (window closed)

        try self.writeFile(folderDir.appendingPathComponent("todo.md"), data: Data("# todo\n- test\n".utf8), mtimeMs: tBase + 60_000)
        try self.writeFile(folderDir.appendingPathComponent("contract.pdf"), data: Data("%PDF-1.4 ok".utf8), mtimeMs: tBase + 120_000)
        try self.writeFile(folderDir.appendingPathComponent("app.docx"), data: Data("PK\u{03}\u{04}".utf8), mtimeMs: tBase + 180_000)
        try self.writeFile(folderDir.appendingPathComponent("inprogress.iso.crdownload"), data: Data("part".utf8), mtimeMs: tBase + 190_000)
        try self.writeFile(folderDir.appendingPathComponent(".DS_Store"), data: Data("junk".utf8), mtimeMs: tBase + 190_000)
        try self.writeFile(folderDir.appendingPathComponent(".evicted.pdf.icloud"), data: Data("stub".utf8), mtimeMs: tBase + 190_000)

        let store = FoldersStore(fileURL: root.appendingPathComponent("ledger.json"))
        let intake = SourceIntakeStore(directoryURL: root.appendingPathComponent("intake", isDirectory: true))
        let transport = StubFoldersTransport()
        let fs = ThreadCheckingFileSystem()
        let engine = FoldersEngine(store: store, fileSystem: fs, transport: transport, clock: clock, intake: intake)
        engine.isPairedProvider = { true }

        let pickedID = await engine.handlePickedFolder(url: folderDir)
        let id = try XCTUnwrap(pickedID)
        let rawPreview = await engine.computePreview(folderID: id, range: .last30Days)
        let preview = try XCTUnwrap(rawPreview)
        XCTAssertEqual(preview.totalItems, 3)
        XCTAssertEqual(preview.notes, 1)
        XCTAssertEqual(preview.documents, 1)
        XCTAssertEqual(preview.other, 1)
        XCTAssertEqual(preview.contentItems, 2)
        XCTAssertEqual(preview.metadataOnlyItems, 1)
        XCTAssertEqual(preview.placeholdersSkipped, 1)
        // Nothing sent before confirm.
        XCTAssertTrue(transport.recordedUploads().isEmpty)
        XCTAssertFalse(fs.walkedOnMainThread, "Folder walk must execute off MainActor")

        let confirmed = await engine.confirmFolder(folderID: id, range: .last30Days)
        XCTAssertTrue(confirmed)
        let uploads = transport.recordedUploads()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads[0].events.count, 3)
        XCTAssertEqual(uploads[0].contentFiles.count, 2)
        XCTAssertEqual(uploads[0].window.segment, "104000_300")
        XCTAssertEqual(engine.folder(id: id)?.itemsTakenIn, 3)

        if case .ready(let snap) = intake.load() {
            XCTAssertEqual(snap.folders.total, 3)
        } else {
            XCTFail("expected ready intake snapshot")
        }
    }

    @MainActor
    func testNoteEditCoalescingRevertSuppressionAndOneHourDocumentRevisionCooldown() async throws {
        let root = try self.makeTempDir()
        let folderDir = root.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let t0: Int64 = 1_795_689_600_000
        let clock = StubFolderClock(ms: t0 + 60_000)
        let store = FoldersStore(fileURL: root.appendingPathComponent("ledger.json"))
        let transport = StubFoldersTransport()
        let engine = FoldersEngine(store: store, transport: transport, clock: clock)
        engine.isPairedProvider = { true }

        let pickedID = await engine.handlePickedFolder(url: folderDir)
        let id = try XCTUnwrap(pickedID)
        _ = await engine.confirmFolder(folderID: id, range: .fromToday)

        let noteURL = folderDir.appendingPathComponent("todo.md")
        let pdfURL = folderDir.appendingPathComponent("spec.pdf")
        try self.writeFile(noteURL, data: Data("line 1\nline 2\n".utf8), mtimeMs: t0 + 10_000)
        try self.writeFile(pdfURL, data: Data("%PDF-1.4 v1".utf8), mtimeMs: t0 + 20_000)

        await engine.scanAll()
        await engine.drainPending()
        XCTAssertTrue(transport.recordedUploads().isEmpty, "open 5-minute window must not send yet")

        // Close window -> first sight delivers both.
        clock.advance(ms: 250_000)
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 1)
        XCTAssertEqual(transport.recordedUploads()[0].events.count, 2)

        // Edit note twice in next window, and save a new PDF version.
        let edit1Ms = clock.nowMs()
        try self.writeFile(noteURL, data: Data("line 1\nline 2\ntemp\n".utf8), mtimeMs: edit1Ms)
        try self.writeFile(pdfURL, data: Data("%PDF-1.4 v2".utf8), mtimeMs: edit1Ms)
        clock.advance(ms: 10_000)
        await engine.scanAll()

        let edit2Ms = clock.nowMs()
        try self.writeFile(noteURL, data: Data("line 1\nline 2\nfinal\n".utf8), mtimeMs: edit2Ms)
        clock.advance(ms: 10_000)
        await engine.scanAll()

        // Close 5-minute window: note sends coalesced final text; PDF still waits 1h.
        clock.advance(ms: 300_000)
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 2)
        let noteUpload = transport.recordedUploads()[1]
        XCTAssertEqual(noteUpload.events.count, 1)
        XCTAssertEqual(noteUpload.events[0].relPath, "todo.md")
        XCTAssertEqual(noteUpload.events[0].verb, .edited)
        XCTAssertTrue(noteUpload.events[0].notePayload?.contains("final") == true)
        XCTAssertFalse(noteUpload.events[0].notePayload?.contains("temp") == true)

        // +45m: PDF still in 1-hour cool-down.
        clock.advance(ms: 45 * 60 * 1_000)
        await engine.scanAll()
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 2)

        // +65m: PDF cool-down elapsed -> sends revised document!
        clock.advance(ms: 20 * 60 * 1_000)
        await engine.scanAll()
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 3)
        let revUpload = transport.recordedUploads()[2]
        XCTAssertEqual(revUpload.events[0].relPath, "spec.pdf")
        XCTAssertEqual(revUpload.events[0].verb, .revised)
        XCTAssertTrue(revUpload.events[0].isRevision)
    }

    @MainActor
    func testDeleteBeforeSendRenamePauseOffRestartSetupAndRefusedFilesFallback() async throws {
        let root = try self.makeTempDir()
        let folderDir = root.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let t0: Int64 = 1_795_689_600_000
        let clock = StubFolderClock(ms: t0 + 10_000)
        let store = FoldersStore(fileURL: root.appendingPathComponent("ledger.json"))
        let transport = StubFoldersTransport()
        let engine = FoldersEngine(store: store, transport: transport, clock: clock)
        engine.isPairedProvider = { true }

        let pickedID = await engine.handlePickedFolder(url: folderDir)
        let id = try XCTUnwrap(pickedID)
        _ = await engine.confirmFolder(folderID: id, range: .fromToday)

        // Delete-before-send: `temp.md` disappears before window closes; `kept.md` stays.
        let keptURL = folderDir.appendingPathComponent("kept.md")
        let tempURL = folderDir.appendingPathComponent("temp.md")
        try self.writeFile(keptURL, data: Data("keep me".utf8), mtimeMs: t0 + 1_000)
        try self.writeFile(tempURL, data: Data("ephemeral".utf8), mtimeMs: t0 + 2_000)
        await engine.scanAll()
        let metadataOnly = folderDir.appendingPathComponent("download.bin")
        try self.writeFile(metadataOnly, data: Data([1]), mtimeMs: t0 + 3_000)
        await engine.scanAll()
        try FileManager.default.removeItem(at: tempURL)
        try FileManager.default.removeItem(at: metadataOnly)
        clock.advance(ms: 310_000)
        // Select the upload before another directory listing has had a chance to reconcile.
        let beforeRescan = await engine.nextDelivery()
        XCTAssertEqual(beforeRescan?.events.map(\.relPath), ["kept.md"])
        await engine.scanAll()
        await engine.drainPending()

        XCTAssertEqual(transport.recordedUploads().count, 1)
        XCTAssertEqual(transport.recordedUploads()[0].events.map(\.relPath), ["kept.md"])

        // Rename after delivery -> single `renamed` metadata-only event.
        let renamedURL = folderDir.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: keptURL, to: renamedURL)
        clock.advance(ms: 10_000)
        await engine.scanAll()
        clock.advance(ms: 310_000)
        await engine.drainPending()

        XCTAssertEqual(transport.recordedUploads().count, 2)
        XCTAssertEqual(transport.recordedUploads()[1].events[0].verb, .renamed)
        XCTAssertEqual(transport.recordedUploads()[1].events[0].previousPath, "kept.md")
        XCTAssertEqual(transport.recordedUploads()[1].events[0].relPath, "renamed.md")

        // Delete after delivery -> `removed` event.
        try FileManager.default.removeItem(at: renamedURL)
        clock.advance(ms: 10_000)
        await engine.scanAll()
        clock.advance(ms: 310_000)
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 3)
        XCTAssertEqual(transport.recordedUploads()[2].events[0].verb, .removed)

        // Pause holds sync without skipping changes; resume delivers them.
        engine.pause(folderID: id)
        let pausedURL = folderDir.appendingPathComponent("while-paused.md")
        try self.writeFile(pausedURL, data: Data("written while paused".utf8), mtimeMs: clock.nowMs())
        clock.advance(ms: 310_000)
        await engine.scanAll()
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 3, "paused folder must not send")
        XCTAssertEqual(engine.folder(id: id)?.pending.count, 1, "paused folder must still track changes")

        engine.setKinds(folderID: id, kinds: FolderKinds(notes: false))
        await engine.resume(folderID: id)
        XCTAssertTrue(transport.recordedUploads().last?.contentFiles.isEmpty == true)
        XCTAssertEqual(transport.recordedUploads().count, 4, "resuming must immediately deliver held changes")

        // Refused corrupt PDF falls back to details-only (`E4`).
        engine.setKinds(folderID: id, kinds: FolderKinds(other: false))
        let corruptURL = folderDir.appendingPathComponent("corrupt.pdf")
        try self.writeFile(corruptURL, data: Data("not a pdf".utf8), mtimeMs: clock.nowMs())
        clock.advance(ms: 310_000)
        await engine.scanAll()
        transport.nextOutcomes = [.allFilesRefused(["corrupt.pdf"]), .delivered]
        await engine.drainPending()
        XCTAssertEqual(engine.folder(id: id)?.fallbackToDetails, 1)
        XCTAssertEqual(transport.recordedUploads().count, 6)
        XCTAssertEqual(transport.recordedUploads()[5].events[0].delivery, .metadataOnly)
        XCTAssertTrue(transport.recordedUploads()[5].contentFiles.isEmpty)

        // Waiting material follows the new pairing. A separate setup is still required for history.
        let held = folderDir.appendingPathComponent("waiting.md")
        try self.writeFile(held, data: Data("held for pairing".utf8), mtimeMs: clock.nowMs())
        clock.advance(ms: 310_000)
        await engine.scanAll()
        engine.setFacet(folderID: id, facet: FolderFacet(name: "work", title: "Work"))
        engine.restartFirstSetup()
        let reset = try XCTUnwrap(engine.folder(id: id))
        XCTAssertEqual(reset.mode, .settingUp)
        XCTAssertTrue(reset.returning)
        XCTAssertEqual(reset.facet?.name, "work")
        XCTAssertEqual(reset.pending.map(\.relPath), ["waiting.md"])
        XCTAssertEqual(engine.waitingCount, 1)
        let refreshed = await engine.backgroundRefresh()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(transport.recordedUploads().last?.events.map(\.relPath), ["waiting.md"])
        XCTAssertEqual(engine.folder(id: id)?.mode, .settingUp)
        XCTAssertTrue(reset.files.values.allSatisfy { !$0.deliveredToJournal })

        // Pairing principle 8: ledger JSON stores zero journal identity.
        let ledgerRaw = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(ledgerRaw.contains("deviceID"))
        XCTAssertFalse(ledgerRaw.contains("pairingIdentity"))
        XCTAssertFalse(ledgerRaw.contains("journalHost"))
    }

    @MainActor
    func testIncompleteWalkNeverDeletesTrackedFilesAndChangeWhileAppOffIsPickedUp() async throws {
        let root = try self.makeTempDir()
        let folderDir = root.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let t0: Int64 = 1_795_689_600_000
        let clock = StubFolderClock(ms: t0 + 10_000)
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let transport = StubFoldersTransport()
        let fs = ThreadCheckingFileSystem()

        let store1 = FoldersStore(fileURL: ledgerURL)
        let engine1 = FoldersEngine(store: store1, fileSystem: fs, transport: transport, clock: clock)
        engine1.isPairedProvider = { true }

        let pickedID = await engine1.handlePickedFolder(url: folderDir)
        let id = try XCTUnwrap(pickedID)
        _ = await engine1.confirmFolder(folderID: id, range: .fromToday)

        let oneURL = folderDir.appendingPathComponent("one.md")
        try self.writeFile(oneURL, data: Data("first".utf8), mtimeMs: t0 + 1_000)
        await engine1.scanAll()
        clock.advance(ms: 310_000)
        await engine1.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 1)

        // Incomplete walk while file is gone must NOT emit `removed`.
        try FileManager.default.removeItem(at: oneURL)
        fs.forceIncomplete = true
        clock.advance(ms: 10_000)
        await engine1.scanAll()
        clock.advance(ms: 310_000)
        await engine1.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 1)
        XCTAssertGreaterThan(engine1.folder(id: id)?.cantRead ?? 0, 0)

        // Scenario 8: app closed; file created while app is off; reopen picks it up.
        fs.forceIncomplete = false
        let twoURL = folderDir.appendingPathComponent("two.md")
        try self.writeFile(twoURL, data: Data("created while off".utf8), mtimeMs: clock.nowMs() + 5_000)
        clock.advance(ms: 320_000)

        let store2 = FoldersStore(fileURL: ledgerURL)
        let engine2 = FoldersEngine(store: store2, fileSystem: fs, transport: transport, clock: clock)
        engine2.isPairedProvider = { true }
        await engine2.scanAll()
        await engine2.drainPending()
        XCTAssertTrue(transport.recordedUploads().flatMap(\.events).contains { $0.relPath == "two.md" && $0.verb == .added })
    }

    // MARK: - Worst-Signal-Wins Rollup & Source Declarations

    func testWorstSignalWinsTileRollupOrdering() {
        let empty = FoldersEngine.computeTileRollup(folders: [], isPaired: true, capabilityListed: true)
        XCTAssertEqual(empty.state, .readyToSetUp)
        XCTAssertFalse(empty.showsSubtext)

        let fOff = FolderRecord(id: "a", name: "A", displayLabel: "A", bookmarkData: nil, canonicalPath: "/a", mode: .off)
        let fPaused = FolderRecord(id: "b", name: "B", displayLabel: "B", bookmarkData: nil, canonicalPath: "/b", mode: .paused)
        let fOn = FolderRecord(id: "c", name: "C", displayLabel: "C", bookmarkData: nil, canonicalPath: "/c", mode: .on)
        let fSetup = FolderRecord(id: "d", name: "D", displayLabel: "D", bookmarkData: nil, canonicalPath: "/d", mode: .settingUp)
        let fAttn = FolderRecord(id: "e", name: "E", displayLabel: "E", bookmarkData: nil, canonicalPath: "/e", mode: .on, attention: .bookmarkInvalid)

        XCTAssertEqual(FoldersEngine.computeTileRollup(folders: [fOff], isPaired: true, capabilityListed: true).state, .off)
        XCTAssertEqual(FoldersEngine.computeTileRollup(folders: [fOff, fPaused], isPaired: true, capabilityListed: true).state, .paused)
        XCTAssertEqual(FoldersEngine.computeTileRollup(folders: [fPaused, fOn], isPaired: true, capabilityListed: true).state, .active)
        XCTAssertEqual(FoldersEngine.computeTileRollup(folders: [fOn, fSetup], isPaired: true, capabilityListed: true).state, .enrolling)
        XCTAssertEqual(FoldersEngine.computeTileRollup(folders: [fSetup, fAttn], isPaired: true, capabilityListed: true).state, .needsAttention)
    }

    func testPerFolderSourceDeclarationsHonorWireCapSeverityOrderingAndCapabilityGate() {
        var folders: [FolderRecord] = [
            FolderRecord(id: "off-1", name: "Off", displayLabel: "Off", bookmarkData: nil, canonicalPath: "/off", mode: .off),
            FolderRecord(id: "setup-1", name: "Setup", displayLabel: "Setup", bookmarkData: nil, canonicalPath: "/setup", mode: .settingUp),
            FolderRecord(id: "z-on", name: "Z", displayLabel: "Z", bookmarkData: nil, canonicalPath: "/z", mode: .on),
            FolderRecord(id: "a-on", name: "A", displayLabel: "A", bookmarkData: nil, canonicalPath: "/a", mode: .on),
            FolderRecord(id: "p-paused", name: "P", displayLabel: "P", bookmarkData: nil, canonicalPath: "/p", mode: .paused),
            FolderRecord(id: "b-attn", name: "B", displayLabel: "B", bookmarkData: nil, canonicalPath: "/b", mode: .paused, attention: .bookmarkInvalid),
        ]

        // Capability explicitly not listed -> omit all folder declarations.
        XCTAssertTrue(FoldersEngine.buildSourceDeclarations(folders: folders, capabilityListed: false, nonFolderCount: 4).isEmpty)

        // Normal ordering: needs_attention > paused > on, UTF-8 ID ascending tie-breaker; off/settingUp omitted.
        let normal = FoldersEngine.buildSourceDeclarations(folders: folders, capabilityListed: true, nonFolderCount: 4)
        XCTAssertEqual(normal, [
            SourceDeclaration(source: "folder", state: "needs_attention", detail: "b-attn"),
            SourceDeclaration(source: "folder", state: "paused", detail: "p-paused"),
            SourceDeclaration(source: "folder", state: "on", detail: "a-on"),
            SourceDeclaration(source: "folder", state: "on", detail: "z-on"),
        ])

        // Wire cap 64: folders never displace non-folder sources, and severity-first fills remaining slots.
        for i in 0..<70 {
            folders.append(FolderRecord(
                id: String(format: "extra-%02d", i),
                name: "Extra",
                displayLabel: "Extra",
                bookmarkData: nil,
                canonicalPath: "/extra/\(i)",
                mode: .on
            ))
        }
        let capped = FoldersEngine.buildSourceDeclarations(folders: folders, capabilityListed: true, nonFolderCount: 10)
        XCTAssertEqual(capped.count, 54)
        XCTAssertEqual(capped[0], SourceDeclaration(source: "folder", state: "needs_attention", detail: "b-attn"))
        XCTAssertEqual(capped[1], SourceDeclaration(source: "folder", state: "paused", detail: "p-paused"))
    }

    @MainActor
    func testActiveForegroundPollLoopPicksUpChangesWhileAppStaysOpen() async throws {
        let root = try self.makeTempDir()
        let folderDir = root.appendingPathComponent("LiveOpen", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let t0: Int64 = 1_795_689_600_000
        let clock = StubFolderClock(ms: t0 + 360_000)
        let store = FoldersStore(fileURL: root.appendingPathComponent("ledger.json"))
        let transport = StubFoldersTransport()
        let engine = FoldersEngine(store: store, transport: transport, clock: clock)
        engine.isPairedProvider = { true }
        engine.activePollIntervalSeconds = 0.05

        let picked = await engine.handlePickedFolder(url: folderDir)
        let id = try XCTUnwrap(picked)
        _ = await engine.confirmFolder(folderID: id, range: .fromToday)

        engine.setAppActive(true)
        defer { engine.setAppActive(false) }

        try self.writeFile(
            folderDir.appendingPathComponent("while-open.md"),
            data: Data("saved while open".utf8),
            mtimeMs: t0 + 60_000
        )

        // Wait up to 3 seconds for the active poll loop to pick up and deliver without a manual checkNow.
        for _ in 0..<30 {
            if !transport.recordedUploads().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(transport.recordedUploads().count, 1)
        XCTAssertEqual(transport.recordedUploads()[0].events.first?.relPath, "while-open.md")
    }

    @MainActor
    func testDocumentRevisionRevertDuringCooldownCancelsRevision() async throws {
        let root = try self.makeTempDir()
        let folderDir = root.appendingPathComponent("DocsRevert", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let t0: Int64 = 1_795_689_600_000
        let clock = StubFolderClock(ms: t0 + 10_000)
        let store = FoldersStore(fileURL: root.appendingPathComponent("ledger.json"))
        let transport = StubFoldersTransport()
        let engine = FoldersEngine(store: store, transport: transport, clock: clock)
        engine.isPairedProvider = { true }

        let picked = await engine.handlePickedFolder(url: folderDir)
        let id = try XCTUnwrap(picked)
        _ = await engine.confirmFolder(folderID: id, range: .fromToday)

        let pdfURL = folderDir.appendingPathComponent("brief.pdf")
        let v1 = Data("%PDF-1.4\noriginal version\n".utf8)
        let v2 = Data("%PDF-1.4\ntemporary edit\n".utf8)
        try self.writeFile(pdfURL, data: v1, mtimeMs: t0 + 1_000)
        await engine.scanAll()
        clock.advance(ms: 310_000)
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 1)

        // Edit during cooldown, then revert to original bytes before 1 hour elapses.
        try self.writeFile(pdfURL, data: v2, mtimeMs: clock.nowMs())
        clock.advance(ms: 5_000)
        await engine.scanAll()
        XCTAssertNotNil(engine.folder(id: id)?.files["brief.pdf"]?.pendingRevisionSaveMs)

        try self.writeFile(pdfURL, data: v1, mtimeMs: clock.nowMs())
        clock.advance(ms: 5_000)
        await engine.scanAll()
        XCTAssertNil(engine.folder(id: id)?.files["brief.pdf"]?.pendingRevisionSaveMs)

        clock.advance(ms: 3_700_000)
        await engine.scanAll()
        await engine.drainPending()
        XCTAssertEqual(transport.recordedUploads().count, 1, "reverted document must not emit a revision")
    }

    func testSymlinkOutsideRootIsExcludedFromWalkAndRead() throws {
        let root = try self.makeTempDir()
        let outsideDir = root.appendingPathComponent("Outside", isDirectory: true)
        let folderDir = root.appendingPathComponent("Inside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        let secretURL = outsideDir.appendingPathComponent("secret.txt")
        try Data("do not read".utf8).write(to: secretURL)
        try FileManager.default.createSymbolicLink(
            at: folderDir.appendingPathComponent("escape.txt"),
            withDestinationURL: secretURL
        )
        try FileManager.default.createSymbolicLink(
            at: folderDir.appendingPathComponent("escape-dir"),
            withDestinationURL: outsideDir
        )
        try Data("local ok".utf8).write(to: folderDir.appendingPathComponent("ok.txt"))

        let fs = LiveFolderFileSystem()
        let walk = try fs.walk(bookmarkData: nil, fallbackPath: folderDir.path, isCloudProvider: false)
        XCTAssertEqual(walk.files.map(\.relPath), ["ok.txt"])
        XCTAssertNil(try fs.readFile(bookmarkData: nil, fallbackPath: folderDir.path, relPath: "escape.txt", maxBytes: 1024))
        XCTAssertNil(try fs.readFile(bookmarkData: nil, fallbackPath: folderDir.path, relPath: "escape-dir/secret.txt", maxBytes: 1024))
    }
}
