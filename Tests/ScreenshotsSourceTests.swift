// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreGraphics
import Foundation
import ImageIO
import os
import Photos
import SwiftUI
import XCTest

/// The screenshots source: identity, the span, pause, and what reaches the journal.
nonisolated final class ScreenshotsSourceTests: XCTestCase {
    private let roots = OSAllocatedUnfairLock<[URL]>(initialState: [])

    override func tearDown() {
        let urls = self.roots.withLock { roots in
            let copy = roots
            roots.removeAll()
            return copy
        }
        for root in urls {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    @MainActor
    func testScreenshotSubtypeIsThePhotosBit() {
        let raw = PHAssetMediaSubtype.photoScreenshot.rawValue
        XCTAssertNotEqual(raw, 0)
        XCTAssertTrue(ScreenshotsWire.isScreenshot(mediaSubtypeRaw: raw, screenshotRaw: raw))
        XCTAssertTrue(ScreenshotsWire.isScreenshot(mediaSubtypeRaw: raw | 1, screenshotRaw: raw))
        XCTAssertFalse(ScreenshotsWire.isScreenshot(mediaSubtypeRaw: 0, screenshotRaw: raw))
        XCTAssertFalse(ScreenshotsWire.isScreenshot(mediaSubtypeRaw: raw, screenshotRaw: 0))
        let predicate = ScreenshotsPhotoKit.predicate(onOrAfter: nil)
        XCTAssertTrue(predicate.predicateFormat.contains("mediaSubtypes"))
        XCTAssertTrue(predicate.predicateFormat.contains(String(Int(raw))))
        let dated = ScreenshotsPhotoKit.predicate(onOrAfter: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(dated.predicateFormat.contains("creationDate"))
    }

    func testPlacementMatchesTheJournalGoldenLine() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 3, hour: 14, minute: 32, second: 7
        )))
        let placement = ScreenshotsWire.placement(of: date, timeZone: zone)
        XCTAssertEqual(placement.capturedAt, "2026-11-03T14:32:07-07:00")
        XCTAssertEqual(placement.day, "20261103")
        XCTAssertEqual(placement.segment, "143207_1")
        XCTAssertEqual(placement.offsetSeconds, -7 * 3600)

        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let zulu = ScreenshotsWire.placement(of: date, timeZone: utc)
        XCTAssertTrue(zulu.capturedAt.hasSuffix("Z"))
        XCTAssertFalse(zulu.capturedAt.contains("."))
    }

    func testIdentityIsTheUnchangedBytes() {
        let original = Data("png-bytes-not-reencoded".utf8)
        let hash = ScreenshotsWire.sha256Hex(original)
        XCTAssertEqual(hash, ScreenshotsWire.sha256Hex(Data(original)))
        XCTAssertEqual(ScreenshotsWire.itemID(forHash: hash), ScreenshotsWire.itemID(forHash: hash))
        XCTAssertNotEqual(
            ScreenshotsWire.itemID(forHash: hash),
            ScreenshotsWire.itemID(forHash: ScreenshotsWire.sha256Hex(Data("other".utf8)))
        )
        XCTAssertEqual(ScreenshotsWire.filename(ext: "png"), "screenshot_screen.png")
        if case .accepted(let ext, let type) = ScreenshotsWire.kind(uniformTypeIdentifier: "public.png") {
            XCTAssertEqual(ext, "png")
            XCTAssertEqual(type, "image/png")
        } else {
            XCTFail("png is kept")
        }
        if case .refused = ScreenshotsWire.kind(uniformTypeIdentifier: "public.heic") {
        } else {
            XCTFail("heic is refused")
        }
        XCTAssertEqual(ScreenshotsWire.kind(uniformTypeIdentifier: "public.heif"), .refused)
        XCTAssertFalse(ScreenshotsVocabulary.refusedType.localizedCaseInsensitiveContains("heif"))
        XCTAssertFalse(ScreenshotsVocabulary.refusedType.localizedCaseInsensitiveContains("hdr"))
    }

    func testPngStaysExactAndHeicBecomesPngWithItsCaptureTime() throws {
        let png = try XCTUnwrap(Self.encodedImage(uti: "public.png", exifDate: "2026:11:03 14:32:07"))
        let kept = try XCTUnwrap(ScreenshotsWire.uploadBytes(data: png, uniformTypeIdentifier: "public.png"))
        XCTAssertEqual(kept.data, png)
        XCTAssertEqual(kept.ext, "png")
        XCTAssertEqual(kept.contentType, "image/png")

        let stamp = "2026:11:10 14:32:07"
        let heic = try XCTUnwrap(Self.encodedImage(uti: "public.heic", exifDate: stamp), "the heic encoder is unavailable")
        let converted = try XCTUnwrap(ScreenshotsWire.uploadBytes(data: heic, uniformTypeIdentifier: "public.heic"))
        XCTAssertEqual(converted.ext, "png")
        XCTAssertEqual(converted.contentType, "image/png")
        XCTAssertNotEqual(converted.data, heic)
        XCTAssertTrue(converted.data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertEqual(Self.exifDate(in: converted.data), stamp)
        XCTAssertEqual(Self.colorSpaceName(in: converted.data), CGColorSpace.displayP3 as String)
        XCTAssertNil(ScreenshotsWire.uploadBytes(data: Data("not-an-image".utf8), uniformTypeIdentifier: "public.heic"))
    }

    func testSpanLabelsMatchCalendarAndTheButtonFollowsTheChoice() {
        XCTAssertEqual(ScreenshotsVocabulary.spanHeader, CalendarVocabulary.spanHeader)
        XCTAssertEqual(
            ScreenshotsVocabulary.spanOrder.map(\.calendar),
            [.last30Days, .last6Months, .lastYear, .everything, .fromToday]
        )
        for span in ScreenshotsSpan.allCases {
            XCTAssertEqual(ScreenshotsVocabulary.spanLabel(span), CalendarVocabulary.spanLabel(span.calendar))
        }
        XCTAssertEqual(
            ScreenshotsVocabulary.confirmTitle(span: .fromToday, count: 4),
            CalendarVocabulary.startFromToday
        )
        XCTAssertEqual(
            ScreenshotsVocabulary.confirmTitle(span: .last30Days, count: 0),
            CalendarVocabulary.startFromToday
        )
        XCTAssertEqual(ScreenshotsVocabulary.confirmTitle(span: .last30Days, count: 1), "bring in 1 screenshot")
        XCTAssertEqual(ScreenshotsVocabulary.confirmTitle(span: .last30Days, count: 3), "bring in 3 screenshots")
        XCTAssertEqual(ScreenshotsVocabulary.progress(done: 1, total: 3, onPage: false), "1 of 3 in your journal")
        XCTAssertEqual(
            ScreenshotsVocabulary.progress(done: 1, total: 3, onPage: true),
            "1 of 3 screenshots in your journal"
        )
    }

    func testImportScreenCopy() {
        XCTAssertEqual(
            SourceVocabulary.importerWhatItAdds,
            "adds PDFs, audio and text you choose here, and the photos and files you send from the share sheet."
        )
        XCTAssertEqual(SourceVocabulary.importSubline, "photos and files")
        XCTAssertEqual(ScreenshotsVocabulary.importLine, "screenshots come in on their own.")
        XCTAssertEqual(ScreenshotsVocabulary.importAction(isOn: false), "set up screenshots")
        XCTAssertEqual(ScreenshotsVocabulary.importAction(isOn: true), "open screenshots")
        XCTAssertEqual(
            ScreenshotsVocabulary.photosUsage,
            "the solstone app takes in only your screenshots and adds them to your journal. other photos stay where they are."
        )
    }

    func testAccessLossAfterFullWasHeldNeedsAttention() {
        let never = ScreenshotsPresentation.viewState(Self.input(
            everOn: false, access: .limited, fullAccessWasHeld: false
        ))
        XCTAssertEqual(never.sourceState, .readyToSetUp)
        XCTAssertEqual(never.pageReason, ScreenshotsVocabulary.limitedAtPrompt)
        XCTAssertFalse(never.showsSubtext)
        XCTAssertFalse(never.showChooser)

        let lost = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, access: .limited, fullAccessWasHeld: true
        ))
        XCTAssertEqual(lost.sourceState, .needsAttention)
        XCTAssertEqual(lost.subtextOverride, ScreenshotsVocabulary.limitedTile)
        XCTAssertEqual(lost.pageReason, ScreenshotsVocabulary.limitedPage)
        XCTAssertTrue(lost.opensSettings)

        let restricted = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, access: .restricted, fullAccessWasHeld: true
        ))
        XCTAssertEqual(restricted.sourceState, .needsAttention)
        XCTAssertEqual(restricted.pageReason, ScreenshotsVocabulary.restricted)
        XCTAssertFalse(restricted.opensSettings)

        let turnedOff = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: false, access: .denied, fullAccessWasHeld: true
        ))
        XCTAssertEqual(turnedOff.sourceState, .off)
        XCTAssertNil(turnedOff.pageReason)
        XCTAssertFalse(turnedOff.opensSettings)
        XCTAssertFalse(turnedOff.switchOn)

        // Turned on again: it asks how far back, and its switch can still turn it off.
        let askingAgain = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, needsSpan: true, access: .full, fullAccessWasHeld: true
        ))
        XCTAssertEqual(askingAgain.sourceState, .readyToSetUp)
        XCTAssertTrue(askingAgain.switchOn)
        XCTAssertEqual(askingAgain.pageSubline, ScreenshotsVocabulary.readyToSetUpSubline)

        // The page says the pause's promise in full, under its verdict, as the tile does.
        let paused = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, paused: true, access: .full, fullAccessWasHeld: true
        ))
        XCTAssertEqual(paused.sourceState, .paused)
        XCTAssertEqual(paused.pageSubline, ScreenshotsVocabulary.pausedSubtext)
        XCTAssertNil(ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, access: .full, fullAccessWasHeld: true
        )).pageSubline)

        let held = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, access: .full, capabilityNotListed: true
        ))
        XCTAssertEqual(held.sourceState, .active)
        XCTAssertTrue(held.showS21)
        let unknown = ScreenshotsPresentation.viewState(Self.input(
            everOn: true, enabled: true, access: .full, capabilityNotListed: false
        ))
        XCTAssertFalse(unknown.showS21)
    }

    func testPauseWindowBounds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let open = [ScreenshotsPauseWindow(start: start, end: nil)]
        XCTAssertTrue(ScreenshotsWire.takenWhilePaused(created: start, windows: open))
        XCTAssertFalse(ScreenshotsWire.takenWhilePaused(created: start.addingTimeInterval(-1), windows: open))
        let closed = [ScreenshotsPauseWindow(start: start, end: end)]
        XCTAssertTrue(ScreenshotsWire.takenWhilePaused(created: end.addingTimeInterval(-1), windows: closed))
        XCTAssertFalse(ScreenshotsWire.takenWhilePaused(created: end, windows: closed))
    }

    func testWireCarriesScreenshotMetaOnlyForThisSource() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = try ObserverIngestMultipartBody.build(payload: ObserverIngestMultipartPayload(
            boundary: "Boundary-plain",
            day: "20261103",
            segment: "143207_1",
            source: "mobile-segment",
            platform: "ios",
            startedAt: started,
            durationS: 1,
            sources: ["audio"],
            parts: [ObserverIngestMultipartPart(filename: "audio.m4a", contentType: "audio/mp4", data: Data("audio".utf8))]
        ))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("screenshot"))

        let captured = "2026-11-03T14:32:07-07:00"
        let withShot = try ObserverIngestMultipartBody.build(payload: ObserverIngestMultipartPayload(
            boundary: "Boundary-shot",
            day: "20261103",
            segment: "143207_1",
            source: "screenshots",
            platform: "ios",
            startedAt: started,
            durationS: 1,
            sources: ["screenshots"],
            parts: [ObserverIngestMultipartPart(
                filename: "screenshot_screen.png", contentType: "image/png", data: Data("png".utf8)
            )],
            screenshot: TransferScreenshotMeta(v: 1, capturedAt: captured, takenFrom: "platform")
        ))
        let text = String(decoding: withShot, as: UTF8.self)
        XCTAssertTrue(text.contains(
            "\"screenshot\":{\"captured_at\":\"\(captured)\",\"taken_from\":\"platform\",\"v\":1}"
        ))
    }

    @MainActor
    func testBuilderPutsScreenshotMetaOnTheEnvelope() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let hash = ScreenshotsWire.sha256Hex(png)
        let upload = Self.upload(bytes: png, hash: hash, utiExt: "png", contentType: "image/png")
        let spool = TransferSpool(rootURL: self.makeRoot())
        let staged = try spool.stage(
            manifest: ScreenshotsTransfer.manifest(for: upload),
            payloads: [ScreenshotsTransfer.partID: png]
        )
        guard case .inMemory(let body) = try DefaultTransferBodyBuilder.build(item: staged.item, spool: spool) else {
            return XCTFail("expected an in-memory body")
        }
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"screenshot\":{\"captured_at\":\"2026-11-03T14:32:07-07:00\",\"taken_from\":\"platform\",\"v\":1}"))
        XCTAssertTrue(text.contains("\"submitted\":\"screenshot_screen.png\""))
        XCTAssertFalse(text.contains(hash))
    }

    @MainActor
    func testNothingSendsUntilConfirmAndTheBytesAreTheOriginal() async throws {
        let png = Data("exact-png".utf8)
        let rig = self.rig(assets: [Self.asset("today", age: -3_600, uti: "public.png")], exports: ["today": .bytes(png, uniformTypeIdentifier: "public.png")])
        await rig.engine.turnOn()
        XCTAssertTrue(rig.sender.sent.isEmpty)
        guard case .ready(let span, let count) = rig.engine.snapshot.confirm else {
            return XCTFail("expected a counted span")
        }
        XCTAssertEqual(span, .last30Days)
        XCTAssertEqual(count, 1)
        await rig.engine.confirm()
        let sent = try XCTUnwrap(rig.sender.sent.first)
        XCTAssertEqual(rig.sender.sent.count, 1)
        XCTAssertEqual(sent.bytes, png)
        XCTAssertEqual(sent.filename, "screenshot_screen.png")
        XCTAssertEqual(sent.hash, ScreenshotsWire.sha256Hex(png))
        XCTAssertEqual(sent.itemID, ScreenshotsWire.itemID(forHash: sent.hash))
    }

    @MainActor
    func testFromTodayKeepsTodaysShotsAndSaysStartFromToday() async {
        let rig = self.rig(assets: [
            Self.asset("old", age: -40 * 86_400, uti: "public.png"),
            Self.asset("today", age: 0, uti: "public.png"),
        ])
        await rig.engine.turnOn()
        await rig.engine.chooseSpan(.everything)
        guard case .ready(_, let all) = rig.engine.snapshot.confirm else { return XCTFail("count") }
        XCTAssertEqual(all, 2)
        await rig.engine.chooseSpan(.fromToday)
        guard case .ready(let span, let today) = rig.engine.snapshot.confirm else { return XCTFail("today") }
        XCTAssertEqual(span, .fromToday)
        XCTAssertEqual(today, 1)
        XCTAssertEqual(
            ScreenshotsVocabulary.confirmTitle(span: span, count: today),
            CalendarVocabulary.startFromToday
        )
        XCTAssertTrue(rig.sender.sent.isEmpty)
    }

    @MainActor
    func testUnconvertibleBytesStayFinalAndAreNotUploaded() async {
        let rig = self.rig(
            assets: [Self.asset("heic", age: -60, uti: "public.heic")],
            exports: ["heic": .bytes(Data("not-an-image".utf8), uniformTypeIdentifier: "public.heic")]
        )
        await rig.engine.turnOn()
        await rig.engine.confirm()
        XCTAssertTrue(rig.sender.sent.isEmpty)
        XCTAssertEqual(rig.engine.snapshot.finals.map(\.phase), [.refusedType])
        XCTAssertEqual(rig.engine.snapshot.progressDone, 1)
        XCTAssertEqual(rig.engine.snapshot.progressTotal, 1)
    }

    @MainActor
    func testHeicScreenshotIsSentAsPng() async throws {
        let stamp = "2026:11:10 16:08:13"
        let heic = try XCTUnwrap(Self.encodedImage(uti: "public.heic", exifDate: stamp))
        let rig = self.rig(
            assets: [Self.asset("hdr", age: -60, uti: "public.heic")],
            exports: ["hdr": .bytes(heic, uniformTypeIdentifier: "public.heic")]
        )
        await rig.engine.turnOn()
        await rig.engine.confirm()
        let sent = try XCTUnwrap(rig.sender.sent.first)
        XCTAssertEqual(rig.sender.sent.count, 1)
        XCTAssertEqual(sent.filename, "screenshot_screen.png")
        XCTAssertEqual(sent.contentType, "image/png")
        XCTAssertNotEqual(sent.bytes, heic)
        XCTAssertEqual(sent.hash, ScreenshotsWire.sha256Hex(sent.bytes))
        XCTAssertEqual(Self.exifDate(in: sent.bytes), stamp)
        XCTAssertTrue(rig.engine.snapshot.finals.isEmpty)
    }

    @MainActor
    func testRetryDoesNotMoveTheCountBackward() async {
        let rig = self.rig(assets: [Self.asset("cloud", age: -60, uti: "public.png")], exports: ["cloud": .failed])
        await rig.engine.turnOn()
        await rig.engine.confirm()
        XCTAssertEqual(rig.engine.snapshot.finals.map(\.phase), [.unreadable])
        XCTAssertEqual(rig.engine.snapshot.progressDone, 1)
        await rig.engine.retry("cloud")
        XCTAssertEqual(rig.engine.snapshot.progressDone, 1)
        XCTAssertTrue(rig.sender.sent.isEmpty)
    }

    @MainActor
    func testPausedWindowIsSkippedAndANewSpanCanBringItIn() async throws {
        let first = Data("first-png".utf8)
        let duringBytes = Data("during-png".utf8)
        let rig = self.rig(assets: [Self.asset("first", age: -3_600, uti: "public.png")], exports: [
            "first": .bytes(first, uniformTypeIdentifier: "public.png"),
        ])
        await rig.engine.turnOn()
        await rig.engine.confirm()
        XCTAssertEqual(rig.sender.sent.count, 1)
        rig.engine.noteDelivered(localIdentifier: "first", hash: rig.sender.sent[0].hash)
        rig.engine.pause()
        let during = Date().addingTimeInterval(0.05)
        try await Task.sleep(for: .milliseconds(80))
        rig.library.assets.append(Self.asset("during", created: during, uti: "public.png"))
        rig.library.exports["during"] = .bytes(duringBytes, uniformTypeIdentifier: "public.png")
        rig.library.changeResult = .delta(inserted: ["during"], updated: [], deleted: [], token: Data("next".utf8))
        await rig.engine.libraryChanged()
        XCTAssertEqual(rig.sender.sent.count, 1)
        await rig.engine.resume()
        await rig.engine.libraryChanged()
        XCTAssertEqual(rig.sender.sent.count, 1)

        rig.engine.turnOff()
        await rig.engine.turnOn()
        await rig.engine.chooseSpan(.everything)
        guard case .ready(_, let count) = rig.engine.snapshot.confirm else { return XCTFail("recount") }
        XCTAssertEqual(count, 1)
        await rig.engine.confirm()
        XCTAssertEqual(rig.sender.sent.count, 2)
        XCTAssertEqual(rig.sender.sent.last?.bytes, duringBytes)
    }

    @MainActor
    func testAChangeToAScreenshotFromBeforeTheChosenSpanDoesNotBringItIn() async {
        let rig = self.rig(assets: [
            Self.asset("old", age: -90 * 86_400, uti: "public.png"),
            Self.asset("recent", age: -3_600, uti: "public.png"),
        ], exports: [
            "old": .bytes(Data("old-png".utf8), uniformTypeIdentifier: "public.png"),
            "recent": .bytes(Data("recent-png".utf8), uniformTypeIdentifier: "public.png"),
            "new": .bytes(Data("new-png".utf8), uniformTypeIdentifier: "public.png"),
        ])
        await rig.engine.turnOn()
        await rig.engine.confirm()
        XCTAssertEqual(rig.sender.sent.map(\.localIdentifier), ["recent"])

        // Photos reports a favourite or a new date on the old screenshot, and a new one taken now.
        rig.library.assets.append(Self.asset("new", age: 0, uti: "public.png"))
        rig.library.changeResult = .delta(inserted: ["new"], updated: ["old"], deleted: [], token: Data("next".utf8))
        await rig.engine.libraryChanged()
        XCTAssertEqual(rig.sender.sent.map(\.localIdentifier), ["recent", "new"])

        // Off, then on again from today: what was taken while it was off, before today, stays out.
        rig.engine.turnOff()
        rig.library.assets.append(Self.asset("whileOff", age: -2 * 86_400, uti: "public.png"))
        rig.library.exports["whileOff"] = .bytes(Data("while-off-png".utf8), uniformTypeIdentifier: "public.png")
        await rig.engine.turnOn()
        await rig.engine.chooseSpan(.fromToday)
        await rig.engine.confirm()
        rig.library.changeResult = .delta(inserted: ["whileOff"], updated: [], deleted: [], token: Data("later".utf8))
        await rig.engine.libraryChanged()
        XCTAssertFalse(rig.sender.sent.map(\.localIdentifier).contains("whileOff"))
        XCTAssertFalse(rig.sender.sent.map(\.localIdentifier).contains("old"))
    }

    @MainActor
    func testSameJournalKeepsTheSourceOnAndANewJournalAsksAgain() async throws {
        let rig = self.rig(assets: [Self.asset("first", age: -3_600, uti: "public.png")], exports: [
            "first": .bytes(Data("first-png".utf8), uniformTypeIdentifier: "public.png"),
        ])
        var journal = "journal-a"
        rig.engine.journalIdentity = { journal }
        await rig.engine.turnOn()
        await rig.engine.confirm()
        rig.engine.pause()
        rig.engine.noteJournal()
        XCTAssertTrue(rig.engine.snapshot.paused)
        XCTAssertFalse(rig.engine.snapshot.needsSpan)
        await rig.engine.resume()

        journal = "journal-b"
        rig.engine.noteJournal()
        XCTAssertTrue(rig.engine.snapshot.needsSpan)
    }

    @MainActor
    func testANewJournalIsAskedWithItsOwnCount() async throws {
        let rig = self.rig(assets: [
            Self.asset("one", age: -3_600, uti: "public.png"),
            Self.asset("two", age: -7_200, uti: "public.png"),
        ], exports: [
            "one": .bytes(Data("one-png".utf8), uniformTypeIdentifier: "public.png"),
            "two": .bytes(Data("two-png".utf8), uniformTypeIdentifier: "public.png"),
        ])
        var journal = "journal-a"
        rig.engine.journalIdentity = { journal }
        await rig.engine.turnOn()
        await rig.engine.confirm()
        for upload in rig.sender.sent {
            rig.engine.noteDelivered(localIdentifier: upload.localIdentifier, hash: upload.hash)
        }
        // Off and on again against the same journal: nothing is left to bring in.
        rig.engine.turnOff()
        await rig.engine.turnOn()
        guard case .ready(_, let sameJournal) = rig.engine.snapshot.confirm else { return XCTFail("recount") }
        XCTAssertEqual(sameJournal, 0)

        // Another journal: the last count was that journal's, so it never shows as this one's.
        journal = "journal-b"
        rig.engine.noteJournal()
        XCTAssertTrue(rig.engine.snapshot.needsSpan)
        XCTAssertEqual(rig.engine.snapshot.confirm, .checking)
        for _ in 0..<200 {
            if case .ready = rig.engine.snapshot.confirm { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready(_, let newJournal) = rig.engine.snapshot.confirm else { return XCTFail("count for b") }
        XCTAssertEqual(newJournal, 2)
    }

    @MainActor
    func testTheInstallCountTellsTheScreenOnceForEachNewScreenshot() async {
        let library = FakeScreenshotsLibrary()
        library.status = .full
        library.assets = [Self.asset("one", age: -60, uti: "public.png")]
        library.exports = ["one": .bytes(Data("one-png".utf8), uniformTypeIdentifier: "public.png")]
        let sender = FakeScreenshotsSender()
        let intake = SourceIntakeStore(containerRoot: self.makeRoot(), timeZone: TimeZone(secondsFromGMT: 0)!)
        let engine = ScreenshotsSourceEngine(
            library: library,
            store: ScreenshotsStore(fileURL: self.makeRoot().appendingPathComponent("state.json")),
            sender: sender,
            intake: intake,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.journalIdentity = { "journal-a" }
        var told = 0
        engine.onIntakeRecorded = { told += 1 }
        await engine.turnOn()
        await engine.confirm()
        XCTAssertEqual(told, 1)
        engine.noteDelivered(localIdentifier: "one", hash: sender.sent[0].hash)
        XCTAssertEqual(told, 1)
    }

    func testStatusRowsKeepTheWidestNameWholeAndStackAboveTheDefaultSize() {
        XCTAssertEqual(
            StatusPaneIntakeColumns.widestName(["audio", "location", ScreenshotsVocabulary.label, "import"]),
            ScreenshotsVocabulary.label
        )
        XCTAssertEqual(StatusPaneIntakeColumns.widestName([]), "")
        XCTAssertFalse(StatusPaneIntakeColumns.stacks(.large))
        XCTAssertFalse(StatusPaneIntakeColumns.stacks(.small))
        XCTAssertTrue(StatusPaneIntakeColumns.stacks(.xLarge))
        XCTAssertTrue(StatusPaneIntakeColumns.stacks(.accessibility5))
    }

    @MainActor
    func testBackOnAJournalThatHasItNothingIsLeftWaiting() async throws {
        // A screenshot this journal has, set to go again for another journal and still waiting
        // when the owner came back, taken while the source was paused.
        let start = Date().addingTimeInterval(-600)
        let taken = start.addingTimeInterval(60)
        var document = ScreenshotsDocument()
        document.everOn = true
        document.enabled = true
        document.needsSpan = true
        document.fullAccessWasHeld = true
        document.journalIdentity = "journal-c"
        document.pauseWindows = [ScreenshotsPauseWindow(start: start, end: start.addingTimeInterval(120))]
        document.items = [ScreenshotsItem(
            localIdentifier: "paused", created: taken, phase: .pending, hash: "h", deliveredTo: nil,
            inFrozen: true, countedInProgress: false, exportAttempts: 0
        )]
        document.remember(hash: "h", localIdentifier: "paused", journal: "journal-a")
        let url = self.makeRoot().appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url)

        let library = FakeScreenshotsLibrary()
        library.status = .full
        library.assets = [Self.asset("paused", created: taken, uti: "public.png")]
        let sender = FakeScreenshotsSender()
        let engine = ScreenshotsSourceEngine(
            library: library, store: ScreenshotsStore(fileURL: url), sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.journalIdentity = { "journal-a" }
        await engine.chooseSpan(.fromToday)
        guard case .ready(_, let count) = engine.snapshot.confirm else { return XCTFail("count") }
        XCTAssertEqual(count, 0)
        await engine.confirm()
        XCTAssertEqual(engine.snapshot.waiting, 0)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    @MainActor
    func testHistoryExpiryDoesNotSendAScreenshotTwice() async {
        let png = Data("once".utf8)
        let rig = self.rig(assets: [Self.asset("once", age: -60, uti: "public.png")], exports: [
            "once": .bytes(png, uniformTypeIdentifier: "public.png"),
        ])
        await rig.engine.turnOn()
        await rig.engine.confirm()
        let sent = rig.sender.sent[0]
        rig.engine.noteDelivered(localIdentifier: "once", hash: sent.hash)
        rig.library.changeResult = .expired
        await rig.engine.libraryChanged()
        XCTAssertEqual(rig.sender.sent.count, 1)
    }

    @MainActor
    func testLimitedBeforeAndAfterFullAccess() async {
        let rig = self.rig(assets: [])
        rig.library.status = .limited
        await rig.engine.turnOn()
        XCTAssertEqual(rig.engine.snapshot.view.sourceState, .readyToSetUp)
        XCTAssertEqual(rig.engine.snapshot.view.pageReason, ScreenshotsVocabulary.limitedAtPrompt)
        XCTAssertTrue(rig.sender.sent.isEmpty)

        rig.library.status = .full
        await rig.engine.turnOn()
        await rig.engine.confirm()
        rig.library.status = .limited
        rig.engine.refreshAccess()
        XCTAssertEqual(rig.engine.snapshot.view.sourceState, .needsAttention)
        XCTAssertEqual(rig.engine.snapshot.view.pageReason, ScreenshotsVocabulary.limitedPage)
    }

    @MainActor
    func testCapabilityFailureIsNotTheHoldLine() async {
        let published = OSAllocatedUnfairLock<[ScreenshotsCapabilityGate.Capability]>(initialState: [])
        let read = OSAllocatedUnfairLock(initialState: JournalStatusReport.failed)
        let gate = ScreenshotsCapabilityGate(
            read: { _ in read.withLock { $0 } },
            retryDelay: .seconds(3_600)
        )
        await gate.connect(wake: {}, publish: { capability in
            published.withLock { $0.append(capability) }
        })
        let endpoint = TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:9")!, port: 9)
        let shot = ScreenshotsTransfer.manifest(for: Self.upload(
            bytes: Data("x".utf8), hash: ScreenshotsWire.sha256Hex(Data("x".utf8)), utiExt: "png", contentType: "image/png"
        ))
        let admitted = await gate.admits(manifest: shot, endpoint: endpoint)
        XCTAssertFalse(admitted)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(published.withLock { $0 }, [])

        read.withLock { $0 = .read(version: "3", capabilities: ["calendar"]) }
        let again = ScreenshotsCapabilityGate(
            read: { _ in .read(version: "3", capabilities: ["calendar"]) }
        )
        let held = expectation(description: "not listed")
        await again.connect(wake: {}, publish: { capability in
            if capability == .notListed { held.fulfill() }
        })
        _ = await again.admits(manifest: shot, endpoint: endpoint)
        await fulfillment(of: [held], timeout: 2)
    }

    @MainActor
    func testIntakeCountsAHashOnce() {
        let store = SourceIntakeStore(containerRoot: self.makeRoot(), timeZone: TimeZone(secondsFromGMT: 0)!)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(store.recordScreenshot(hash: "abc", now: now), .recorded)
        XCTAssertEqual(store.recordScreenshot(hash: "abc", now: now), .unchanged)
        guard case .ready(let snapshot) = store.load() else { return XCTFail("intake") }
        XCTAssertEqual(snapshot.screenshots.total, 1)
        XCTAssertEqual(
            SourceIntakeFormat.total(snapshot.screenshots, kind: .screenshots, locale: Locale(identifier: "en_US")),
            "1 screenshot"
        )
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-tests-\(UUID().uuidString)", isDirectory: true)
        self.roots.withLock { $0.append(root) }
        return root
    }

    @MainActor
    private func rig(
        assets: [ScreenshotsAsset],
        exports: [String: ScreenshotsExportResult] = [:]
    ) -> (library: FakeScreenshotsLibrary, sender: FakeScreenshotsSender, engine: ScreenshotsSourceEngine) {
        let library = FakeScreenshotsLibrary()
        library.status = .full
        library.assets = assets
        library.exports = exports
        let sender = FakeScreenshotsSender()
        let store = ScreenshotsStore(fileURL: self.makeRoot().appendingPathComponent("state.json"))
        let engine = ScreenshotsSourceEngine(
            library: library, store: store, sender: sender, timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.journalIdentity = { "journal-a" }
        return (library, sender, engine)
    }

    private static func encodedImage(uti: String, exifDate: String) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage()
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, uti as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    private static func exifDate(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    private static func colorSpaceName(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image.colorSpace?.name as String?
    }

    private static func asset(_ id: String, age: TimeInterval, uti: String) -> ScreenshotsAsset {
        self.asset(id, created: Date().addingTimeInterval(age), uti: uti)
    }

    private static func asset(_ id: String, created: Date, uti: String) -> ScreenshotsAsset {
        ScreenshotsAsset(
            localIdentifier: id, created: created, uniformTypeIdentifier: uti, pixelWidth: 100, pixelHeight: 100
        )
    }

    private static func upload(bytes: Data, hash: String, utiExt: String, contentType: String) -> ScreenshotsUpload {
        ScreenshotsUpload(
            localIdentifier: "local",
            itemID: ScreenshotsWire.itemID(forHash: hash),
            bytes: bytes,
            filename: ScreenshotsWire.filename(ext: utiExt),
            contentType: contentType,
            hash: hash,
            capturedAt: "2026-11-03T14:32:07-07:00",
            day: "20261103",
            segment: "143207_1",
            offsetSeconds: -7 * 3600,
            timeZoneIdentifier: "America/Denver",
            created: Date(timeIntervalSince1970: 1_762_000_000)
        )
    }

    private static func input(
        everOn: Bool,
        enabled: Bool = false,
        paused: Bool = false,
        needsSpan: Bool = false,
        access: ScreenshotsAccess,
        fullAccessWasHeld: Bool = false,
        capabilityNotListed: Bool = false
    ) -> ScreenshotsViewInput {
        ScreenshotsViewInput(
            everOn: everOn,
            enabled: enabled,
            paused: paused,
            needsSpan: needsSpan,
            access: access,
            fullAccessWasHeld: fullAccessWasHeld,
            paired: true,
            capabilityNotListed: capabilityNotListed,
            backfillOpen: false,
            progressDone: 0,
            progressTotal: 0
        )
    }
}

private final class FakeScreenshotsLibrary: ScreenshotsLibrary, @unchecked Sendable {
    var status: ScreenshotsAccess = .notDetermined
    var assets: [ScreenshotsAsset] = []
    var exports: [String: ScreenshotsExportResult] = [:]
    var changeResult: ScreenshotsChanges = .delta(inserted: [], updated: [], deleted: [], token: Data("token".utf8))
    var token = Data("token".utf8)

    func access() -> ScreenshotsAccess { self.status }
    func requestAccess() async -> ScreenshotsAccess {
        if self.status == .notDetermined { self.status = .full }
        return self.status
    }
    func screenshots(onOrAfter start: Date) async throws -> [ScreenshotsAsset] {
        self.assets.filter { $0.created >= start }
    }
    func asset(localIdentifier: String) async -> ScreenshotsAsset? {
        self.assets.first { $0.localIdentifier == localIdentifier }
    }
    func changes(since token: Data?) async -> ScreenshotsChanges { self.changeResult }
    func currentToken() -> Data? { self.token }
    func export(localIdentifier: String) async -> ScreenshotsExportResult {
        self.exports[localIdentifier] ?? .missing
    }
    func setObserving(_ on: Bool) {}
}

private final class FakeScreenshotsSender: ScreenshotsSending, @unchecked Sendable {
    var sent: [ScreenshotsUpload] = []

    func send(_ upload: ScreenshotsUpload) async throws {
        self.sent.append(upload)
    }
}
