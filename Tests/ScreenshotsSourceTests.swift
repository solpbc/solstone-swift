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
    func testANewPairingAsksHowFarBackAgainAndSendsNothingUntilConfirm() async throws {
        let rig = self.rig(assets: [
            Self.asset("one", age: -3_600, uti: "public.png"),
            Self.asset("two", age: -7_200, uti: "public.png"),
        ], exports: [
            "one": .bytes(Data("one-png".utf8), uniformTypeIdentifier: "public.png"),
            "two": .bytes(Data("two-png".utf8), uniformTypeIdentifier: "public.png"),
        ])
        await rig.engine.turnOn()
        await rig.engine.confirm()
        for upload in rig.sender.sent {
            rig.engine.noteDelivered(localIdentifier: upload.localIdentifier, hash: upload.hash)
        }
        XCTAssertEqual(rig.sender.sent.count, 2)
        // Off and on again with the same pairing: nothing is left to bring in.
        rig.engine.turnOff()
        await rig.engine.turnOn()
        guard case .ready(_, let samePairing) = rig.engine.snapshot.confirm else { return XCTFail("recount") }
        XCTAssertEqual(samePairing, 0)
        await rig.engine.confirm()
        rig.engine.pause()

        rig.engine.restartFirstSetup()
        XCTAssertEqual(rig.engine.snapshot.view.sourceState, .readyToSetUp)
        XCTAssertTrue(rig.engine.snapshot.view.showChooser)
        XCTAssertTrue(rig.engine.snapshot.paused)
        XCTAssertEqual(rig.engine.snapshot.access, .full)
        try await self.waitForCount(rig.engine)
        guard case .ready(_, let newPairing) = rig.engine.snapshot.confirm else { return XCTFail("fresh count") }
        XCTAssertEqual(newPairing, 2)

        // Nothing goes before the owner confirms.
        rig.library.changeResult = .delta(inserted: [], updated: ["one"], deleted: [], token: Data("next".utf8))
        await rig.engine.libraryChanged()
        await rig.engine.foreground()
        XCTAssertEqual(rig.sender.sent.count, 2)

        await rig.engine.confirm()
        XCTAssertEqual(rig.sender.sent.map(\.localIdentifier).sorted(), ["one", "one", "two", "two"])
        XCTAssertTrue(rig.engine.snapshot.paused)
    }

    @MainActor
    func testANewPairingLeavesAnOffSourceOffAndItsTurnOnBringsEverythingAgain() async throws {
        let rig = self.rig(assets: [Self.asset("one", age: -3_600, uti: "public.png")], exports: [
            "one": .bytes(Data("one-png".utf8), uniformTypeIdentifier: "public.png"),
        ])
        await rig.engine.turnOn()
        await rig.engine.confirm()
        rig.engine.noteDelivered(localIdentifier: "one", hash: rig.sender.sent[0].hash)
        rig.engine.turnOff()

        rig.engine.restartFirstSetup()
        XCTAssertEqual(rig.engine.snapshot.view.sourceState, .off)
        XCTAssertFalse(rig.engine.snapshot.needsSpan)

        await rig.engine.turnOn()
        guard case .ready(_, let count) = rig.engine.snapshot.confirm else { return XCTFail("count") }
        XCTAssertEqual(count, 1)
        await rig.engine.confirm()
        XCTAssertEqual(rig.sender.sent.map(\.localIdentifier), ["one", "one"])
    }

    @MainActor
    func testARelaunchRestartsNothing() async throws {
        let url = self.makeRoot().appendingPathComponent("state.json")
        let library = FakeScreenshotsLibrary()
        library.status = .full
        library.assets = [Self.asset("one", age: -3_600, uti: "public.png")]
        library.exports = ["one": .bytes(Data("one-png".utf8), uniformTypeIdentifier: "public.png")]
        let sender = FakeScreenshotsSender()
        let engine = ScreenshotsSourceEngine(
            library: library, store: ScreenshotsStore(fileURL: url), sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.isPaired = { true }
        await engine.turnOn()
        await engine.confirm()
        engine.noteDelivered(localIdentifier: "one", hash: sender.sent[0].hash)

        let relaunched = ScreenshotsSourceEngine(
            library: library, store: ScreenshotsStore(fileURL: url), sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        relaunched.isPaired = { true }
        library.changeResult = .expired
        await relaunched.launch()
        XCTAssertEqual(relaunched.snapshot.view.sourceState, .active)
        XCTAssertEqual(sender.sent.count, 1)
    }

    /// Photos reports a change for every edit, sync and new photo. A change that brings in no
    /// screenshot does not rewrite the source's record.
    @MainActor
    func testLibraryChangesWithNoNewScreenshotDoNotRewriteTheRecord() async throws {
        let url = self.makeRoot().appendingPathComponent("state.json")
        let library = FakeScreenshotsLibrary()
        library.status = .full
        library.assets = [Self.asset("one", age: -3_600, uti: "public.png")]
        library.exports = ["one": .bytes(Data("one-png".utf8), uniformTypeIdentifier: "public.png")]
        let sender = FakeScreenshotsSender()
        let engine = ScreenshotsSourceEngine(
            library: library, store: ScreenshotsStore(fileURL: url), sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.isPaired = { true }
        await engine.turnOn()
        await engine.confirm()
        engine.noteDelivered(localIdentifier: "one", hash: sender.sent[0].hash)
        func identity() throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        }
        let written = try identity()
        let checkedBefore = try XCTUnwrap(engine.snapshot.lastChecked)
        for index in 0..<20 {
            library.changeResult = .delta(inserted: ["photo-\(index)"], updated: ["one"], deleted: [],
                                          token: Data("token-\(index)".utf8))
            await engine.libraryChanged()
        }
        XCTAssertEqual(try identity(), written)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(engine.snapshot.lastChecked), checkedBefore)

        library.assets.append(Self.asset("two", age: -60, uti: "public.png"))
        library.exports["two"] = .bytes(Data("two-png".utf8), uniformTypeIdentifier: "public.png")
        library.changeResult = .delta(inserted: ["two"], updated: [], deleted: [], token: Data("token-two".utf8))
        await engine.libraryChanged()
        XCTAssertNotEqual(try identity(), written)
        XCTAssertEqual(sender.sent.map(\.localIdentifier), ["one", "two"])
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

    @MainActor
    private func waitForCount(_ engine: ScreenshotsSourceEngine) async throws {
        for _ in 0..<200 {
            if case .ready = engine.snapshot.confirm { return }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        engine.isPaired = { true }
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

    // MARK: - Phase 1 Startup & Foreground Unblock Tests

    @MainActor
    func testCatchUpConfirmAndRescanUseBatchedAssetFetchAndAsyncToken() async throws {
        let url = self.makeRoot().appendingPathComponent("state.json")
        let library = FakeScreenshotsLibrary()
        library.status = .full
        let initial = Self.asset("init-1", age: -3_600, uti: "public.png")
        let newA = Self.asset("new-a", age: -60, uti: "public.png")
        let newB = Self.asset("new-b", age: -30, uti: "public.png")
        library.assets = [initial]
        library.exports = [
            "init-1": .bytes(Data("init-1".utf8), uniformTypeIdentifier: "public.png"),
            "new-a": .bytes(Data("new-a".utf8), uniformTypeIdentifier: "public.png"),
            "new-b": .bytes(Data("new-b".utf8), uniformTypeIdentifier: "public.png"),
        ]
        library.token = Data("tok-confirm".utf8)
        let sender = FakeScreenshotsSender()
        let engine = ScreenshotsSourceEngine(
            library: library, store: ScreenshotsStore(fileURL: url), sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        // Keep isPaired == true so confirm/catchUp + pump both run; verify confirm/catchUp use batched assets(localIdentifiers:)
        // and never call asset(localIdentifier:) for non-screenshots or already-known items (only pump's export calls asset for real screenshots).
        engine.isPaired = { true }

        await engine.turnOn()
        await engine.confirm()
        XCTAssertGreaterThanOrEqual(library.currentTokenAsyncCalls, 1)
        XCTAssertEqual(library.assetsBatchCalls, [["init-1"]])
        XCTAssertEqual(library.singleAssetCalls, ["init-1"])

        // Delta with known ID ("init-1") plus two new screenshots and two non-screenshots fetches only unknown IDs in one batch call.
        library.resetCallTracking()
        library.assets = [initial, newA, newB]
        library.changeResult = .delta(
            inserted: ["new-a", "new-b", "non-shot-1", "non-shot-2"],
            updated: ["init-1"],
            deleted: [],
            token: Data("tok-delta".utf8)
        )
        await engine.libraryChanged()
        XCTAssertEqual(library.assetsBatchCalls.count, 1)
        XCTAssertEqual(Set(library.assetsBatchCalls[0]), Set(["new-a", "new-b", "non-shot-1", "non-shot-2"]))
        XCTAssertFalse(library.assetsBatchCalls[0].contains("init-1"))
        XCTAssertEqual(Set(library.singleAssetCalls), Set(["new-a", "new-b"]))
        XCTAssertFalse(library.singleAssetCalls.contains("non-shot-1"))
        XCTAssertFalse(library.singleAssetCalls.contains("non-shot-2"))
        XCTAssertFalse(library.singleAssetCalls.contains("init-1"))

        // Expired token rescan uses currentTokenAsync().
        library.resetCallTracking()
        library.token = Data("tok-rescan".utf8)
        library.changeResult = .expired
        await engine.libraryChanged()
        XCTAssertEqual(library.currentTokenAsyncCalls, 1)
        XCTAssertEqual(library.singleAssetCalls, [])
    }

    @MainActor
    func testScreenshotsPhotoKitOffMainRunnerFilterHelperAndHardwareIsolationGuard() async throws {
        // Positive: runOffMain executes off the main thread.
        let ranOffMain = await ScreenshotsPhotoKit.runOffMain { !Thread.isMainThread }
        XCTAssertTrue(ranOffMain)
        let ranOffMainThrowing = try await ScreenshotsPhotoKit.runOffMainThrowing { !Thread.isMainThread }
        XCTAssertTrue(ranOffMainThrowing)
        // Negative twin: @MainActor body executes on the main thread.
        XCTAssertTrue(Thread.isMainThread)

        // Pure filter-before-resource helper skips non-screenshots before invoking map.
        var mappedIDs: [String] = []
        let filtered = ScreenshotsPhotoKit.filterAndMapAssets(
            [("cam-1", false), ("shot-1", true), ("cam-2", false), ("shot-2", true)],
            isScreenshot: { $0.1 },
            map: { item in
                mappedIDs.append(item.0)
                return Self.asset(item.0, age: -10, uti: "public.png")
            }
        )
        XCTAssertEqual(mappedIDs, ["shot-1", "shot-2"])
        XCTAssertEqual(filtered.map(\.localIdentifier), ["shot-1", "shot-2"])

        // Structural guard: all 6 async methods route off-main and the hardware isolation stays intact.
        let photoKitURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Screenshots/ScreenshotsPhotoKit.swift")
        let source = try String(contentsOf: photoKitURL, encoding: .utf8)
        XCTAssertTrue(source.contains("nonisolated final class ScreenshotsPhotoKit:"))
        XCTAssertTrue(source.contains("private nonisolated final class ExportBox:"))
        XCTAssertTrue(source.contains("{ @Sendable chunk in"))
        XCTAssertTrue(source.contains("completionHandler: { @Sendable error in"))
        let methodOffMainMarkers: [(String, String)] = [
            ("func screenshots(onOrAfter", "Self.runOffMainThrowing"),
            ("func asset(localIdentifier", "Self.runOffMain"),
            ("func assets(localIdentifiers", "Self.runOffMain"),
            ("func changes(since", "Self.runOffMain"),
            ("func currentTokenAsync()", "Self.runOffMain"),
            ("func export(localIdentifier", "Task.detached(priority: .utility)"),
        ]
        for (signature, marker) in methodOffMainMarkers {
            let start = try XCTUnwrap(source.range(of: signature), "missing \(signature)")
            let window = source[start.lowerBound..<source.index(start.lowerBound, offsetBy: min(400, source.distance(from: start.lowerBound, to: source.endIndex)))]
            XCTAssertTrue(window.contains(marker), "\(signature) must route off-main via \(marker)")
        }
    }

    @MainActor
    func testCatchUpCoalescesLaunchAndForegroundAndWaitsForFollowUpOnChangeResumeAndBackgroundRefresh() async throws {
        let url = self.makeRoot().appendingPathComponent("state.json")
        let library = FakeScreenshotsLibrary()
        library.status = .full
        let first = Self.asset("first", age: -3_600, uti: "public.png")
        library.assets = [first]
        library.exports = ["first": .bytes(Data("first".utf8), uniformTypeIdentifier: "public.png")]
        let sender = FakeScreenshotsSender()
        let engine = ScreenshotsSourceEngine(
            library: library, store: ScreenshotsStore(fileURL: url), sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.isPaired = { true }
        await engine.turnOn()
        await engine.confirm()
        library.resetCallTracking()

        // 1. Overlapping launch() + foreground() coalesce into a single changes() pass.
        let gate = AsyncGate()
        let entered = AsyncGate()
        library.onChanges = { _ in
            entered.open()
            await gate.wait()
            return .delta(inserted: [], updated: [], deleted: [], token: Data("tok-1".utf8))
        }
        let launchTask = Task { await engine.launch() }
        await entered.wait()
        let foregroundTask = Task { await engine.foreground() }
        await Task.yield()
        gate.open()
        await launchTask.value
        await foregroundTask.value
        XCTAssertEqual(library.changesCallCount, 1)

        // 2. libraryChanged(), resume(), and backgroundRefresh() arriving mid-catchUp schedule
        //    one follow-up pass and DO NOT return until that follow-up pass completes.
        for label in ["libraryChanged", "resume", "backgroundRefresh"] {
            library.resetCallTracking()
            let pass1Entered = AsyncGate()
            let pass1Release = AsyncGate()
            let pass2Entered = AsyncGate()
            let pass2Release = AsyncGate()
            let passCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
            let pass2Completed = OSAllocatedUnfairLock<Bool>(initialState: false)
            library.onChanges = { _ in
                let pass = passCounter.withLock { n -> Int in n += 1; return n }
                if pass == 1 {
                    pass1Entered.open()
                    await pass1Release.wait()
                    return .delta(inserted: [], updated: [], deleted: [], token: Data("p1".utf8))
                } else {
                    pass2Entered.open()
                    await pass2Release.wait()
                    pass2Completed.withLock { $0 = true }
                    return .delta(inserted: [], updated: [], deleted: [], token: Data("p2".utf8))
                }
            }

            let inFlight = Task { await engine.foreground() }
            await pass1Entered.wait()
            if label == "resume" {
                engine.pause()
            }
            let follower = Task {
                switch label {
                case "libraryChanged":
                    await engine.libraryChanged()
                case "resume":
                    await engine.resume()
                default:
                    _ = await engine.backgroundRefresh()
                }
            }
            await Task.yield()
            pass1Release.open()
            await pass2Entered.wait()
            XCTAssertFalse(pass2Completed.withLock { $0 }, "\(label) must not return before pass 2 completes")
            pass2Release.open()
            await inFlight.value
            await follower.value
            XCTAssertTrue(pass2Completed.withLock { $0 }, "\(label) must finish pass 2 before returning")
            XCTAssertEqual(library.changesCallCount, 2, "\(label) should run exactly 2 passes")
        }
    }

    @MainActor
    func testMidAwaitInterruptionsLeaveStoreUnmutatedAndPreservePendingItemsOnRestart() async throws {
        // 1. turnOff(), restartFirstSetup(), and chooseSpan(_:) mid-confirm() discard partial state,
        //    and foreground() mid-confirm() does not launch .expired rescan.
        for interrupt in ["turnOff", "restartFirstSetup", "chooseSpan"] {
            let url = self.makeRoot().appendingPathComponent("confirm-\(interrupt).json")
            let library = FakeScreenshotsLibrary()
            library.status = .full
            library.assets = [Self.asset("c-1", age: -100, uti: "public.png")]
            library.exports = ["c-1": .bytes(Data("c-1".utf8), uniformTypeIdentifier: "public.png")]
            let sender = FakeScreenshotsSender()
            let store = ScreenshotsStore(fileURL: url)
            let engine = ScreenshotsSourceEngine(
                library: library, store: store, sender: sender,
                timeZone: TimeZone(identifier: "America/Denver")!
            )
            engine.isPaired = { true }
            await engine.turnOn()

            let entered = AsyncGate()
            let release = AsyncGate()
            library.onAssetsBatch = { ids in
                entered.open()
                await release.wait()
                return ids.compactMap { id in library.assets.first { $0.localIdentifier == id } }
            }
            library.changeResult = .expired
            let confirmTask = Task { await engine.confirm() }
            await entered.wait()
            // Foreground mid-confirm() must NOT run catchUp / .expired rescan!
            await engine.foreground()
            XCTAssertEqual(library.changesCallCount, 0)

            let docBeforeInterrupt = store.document
            switch interrupt {
            case "turnOff":
                engine.turnOff()
            case "restartFirstSetup":
                engine.restartFirstSetup()
            default:
                await engine.chooseSpan(.last30Days)
            }
            release.open()
            await confirmTask.value

            XCTAssertEqual(store.document.everOn, interrupt == "turnOff" ? false : docBeforeInterrupt.everOn)
            XCTAssertFalse(store.document.enabled, "\(interrupt) mid-confirm must not leave source enabled")
            XCTAssertNil(store.document.liveFloor, "\(interrupt) mid-confirm must not persist liveFloor")
            XCTAssertEqual(store.document.progressTotal, 0, "\(interrupt) mid-confirm must not persist progressTotal")
            XCTAssertEqual(sender.sent.count, 0)
        }

        // 2. turnOff() mid-catchUp .delta and between rescan's screenshots() and currentTokenAsync()
        //    leaves store.document unmutated.
        do {
            let url = self.makeRoot().appendingPathComponent("delta-interrupt.json")
            let library = FakeScreenshotsLibrary()
            library.status = .full
            let first = Self.asset("d-1", age: -3_600, uti: "public.png")
            let second = Self.asset("d-2", age: -10, uti: "public.png")
            library.assets = [first]
            library.exports = [
                "d-1": .bytes(Data("d-1".utf8), uniformTypeIdentifier: "public.png"),
                "d-2": .bytes(Data("d-2".utf8), uniformTypeIdentifier: "public.png"),
            ]
            let sender = FakeScreenshotsSender()
            let store = ScreenshotsStore(fileURL: url)
            let engine = ScreenshotsSourceEngine(
                library: library, store: store, sender: sender,
                timeZone: TimeZone(identifier: "America/Denver")!
            )
            engine.isPaired = { true }
            await engine.turnOn()
            await engine.confirm()
            let savedToken = store.document.changeToken

            library.assets = [first, second]
            library.changeResult = .delta(inserted: ["d-2"], updated: [], deleted: ["d-1"], token: Data("new-tok".utf8))
            let entered = AsyncGate()
            let release = AsyncGate()
            library.onAssetsBatch = { ids in
                entered.open()
                await release.wait()
                return ids.compactMap { id in library.assets.first { $0.localIdentifier == id } }
            }
            let catchUpTask = Task { await engine.libraryChanged() }
            await entered.wait()
            engine.turnOff()
            release.open()
            await catchUpTask.value

            XCTAssertFalse(store.document.enabled)
            XCTAssertEqual(store.document.changeToken, savedToken, "interrupted delta must not advance token")
            XCTAssertNotNil(store.document.items.first { $0.localIdentifier == "d-1" }, "interrupted delta must not apply pre-await deletions")
            XCTAssertNil(store.document.items.first { $0.localIdentifier == "d-2" }, "interrupted delta must not insert new items")
        }

        do {
            let url = self.makeRoot().appendingPathComponent("rescan-interrupt.json")
            let library = FakeScreenshotsLibrary()
            library.status = .full
            let first = Self.asset("r-1", age: -3_600, uti: "public.png")
            let second = Self.asset("r-2", age: -10, uti: "public.png")
            library.assets = [first]
            library.exports = [
                "r-1": .bytes(Data("r-1".utf8), uniformTypeIdentifier: "public.png"),
                "r-2": .bytes(Data("r-2".utf8), uniformTypeIdentifier: "public.png"),
            ]
            let sender = FakeScreenshotsSender()
            let store = ScreenshotsStore(fileURL: url)
            let engine = ScreenshotsSourceEngine(
                library: library, store: store, sender: sender,
                timeZone: TimeZone(identifier: "America/Denver")!
            )
            engine.isPaired = { true }
            await engine.turnOn()
            await engine.confirm()
            let savedToken = store.document.changeToken

            library.assets = [first, second]
            library.changeResult = .expired
            let enteredToken = AsyncGate()
            let releaseToken = AsyncGate()
            library.onCurrentTokenAsync = {
                enteredToken.open()
                await releaseToken.wait()
                return Data("post-rescan-tok".utf8)
            }
            let rescanTask = Task { await engine.libraryChanged() }
            await enteredToken.wait()
            engine.restartFirstSetup()
            releaseToken.open()
            await rescanTask.value

            XCTAssertEqual(store.document.changeToken, savedToken)
            XCTAssertNil(store.document.items.first { $0.localIdentifier == "r-2" }, "interrupted rescan must not commit items")
        }

        // 3. Pending items survive restartFirstSetup() across an in-flight accept().
        do {
            let url = self.makeRoot().appendingPathComponent("accept-restart.json")
            let library = FakeScreenshotsLibrary()
            library.status = .full
            let item = Self.asset("p-1", age: -60, uti: "public.png")
            library.assets = [item]
            let png = Self.pngBytes(width: 4, height: 4)
            library.exports = ["p-1": .bytes(png, uniformTypeIdentifier: "public.png")]
            let sender = FakeScreenshotsSender()
            let store = ScreenshotsStore(fileURL: url)
            let engine = ScreenshotsSourceEngine(
                library: library, store: store, sender: sender,
                timeZone: TimeZone(identifier: "America/Denver")!
            )
            engine.isPaired = { true }
            await engine.turnOn()
            let exportEntered = AsyncGate()
            let exportRelease = AsyncGate()
            library.onExport = { _ in
                exportEntered.open()
                await exportRelease.wait()
                return .bytes(png, uniformTypeIdentifier: "public.png")
            }
            let confirmTask = Task { await engine.confirm() }
            await exportEntered.wait()
            engine.restartFirstSetup()
            exportRelease.open()
            await confirmTask.value
            XCTAssertEqual(sender.sent.map(\.localIdentifier), ["p-1"])
            XCTAssertEqual(store.document.items.first { $0.localIdentifier == "p-1" }?.phase, .queued)
        }
    }

    @MainActor
    func testBoundedChangeTokenPersistenceForExpiredRescanLargeDeltaAndBackground() async throws {
        enum SampleError: Error { case photoKitFailed }
        let url = self.makeRoot().appendingPathComponent("persist-token.json")
        let library = FakeScreenshotsLibrary()
        library.status = .full
        let seed = Self.asset("seed", age: -3_600, uti: "public.png")
        library.assets = [seed]
        library.exports = ["seed": .bytes(Data("seed".utf8), uniformTypeIdentifier: "public.png")]
        library.token = Data("tok-0".utf8)
        let sender = FakeScreenshotsSender()
        let store = ScreenshotsStore(fileURL: url)
        let engine = ScreenshotsSourceEngine(
            library: library, store: store, sender: sender,
            timeZone: TimeZone(identifier: "America/Denver")!
        )
        engine.isPaired = { true }
        await engine.turnOn()
        await engine.confirm()

        func persistedToken() throws -> Data? {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ScreenshotsDocument.self, from: data).changeToken
        }

        XCTAssertEqual(try persistedToken(), Data("tok-0".utf8))

        // 1. Failed .expired rescan does NOT persist a new changeToken.
        library.screenshotsError = SampleError.photoKitFailed
        library.token = Data("tok-failed-rescan".utf8)
        library.changeResult = .expired
        await engine.libraryChanged()
        XCTAssertEqual(try persistedToken(), Data("tok-0".utf8))

        // 2. Successful .expired rescan DOES persist changeToken.
        library.screenshotsError = nil
        library.token = Data("tok-rescan-ok".utf8)
        library.changeResult = .expired
        await engine.libraryChanged()
        XCTAssertEqual(try persistedToken(), Data("tok-rescan-ok".utf8))

        // 3. Large delta (>=50 IDs) DOES persist changeToken even with zero new screenshots.
        let nonScreenshots = (0..<50).map { "camera-photo-\($0)" }
        library.changeResult = .delta(
            inserted: nonScreenshots,
            updated: [],
            deleted: [],
            token: Data("tok-large-delta".utf8)
        )
        await engine.libraryChanged()
        XCTAssertEqual(try persistedToken(), Data("tok-large-delta".utf8))

        // 4. Small delta does NOT rewrite disk, then background() DOES persist the advanced token.
        library.changeResult = .delta(
            inserted: ["camera-small-1"],
            updated: [],
            deleted: [],
            token: Data("tok-bg".utf8)
        )
        await engine.libraryChanged()
        XCTAssertEqual(try persistedToken(), Data("tok-large-delta".utf8))
        engine.background()
        XCTAssertEqual(try persistedToken(), Data("tok-bg".utf8))
    }

    private static func pngBytes(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var raw = Data(count: bytesPerRow * height)
        let image: CGImage = raw.withUnsafeMutableBytes { ptr in
            let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
        let mutable = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return mutable as Data
    }
}

private nonisolated final class AsyncGate: @unchecked Sendable {
    private struct State {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func open() {
        let waiters = self.state.withLock { s -> [CheckedContinuation<Void, Never>] in
            guard !s.opened else { return [] }
            s.opened = true
            let copy = s.waiters
            s.waiters.removeAll()
            return copy
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = self.state.withLock { s -> Bool in
                if s.opened { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private nonisolated final class FakeScreenshotsLibrary: ScreenshotsLibrary, @unchecked Sendable {
    private struct State {
        var status: ScreenshotsAccess = .notDetermined
        var assets: [ScreenshotsAsset] = []
        var exports: [String: ScreenshotsExportResult] = [:]
        var changeResult: ScreenshotsChanges = .delta(inserted: [], updated: [], deleted: [], token: Data("token".utf8))
        var token = Data("token".utf8)
        var screenshotsError: (any Error)?
        var assetsBatchCalls: [[String]] = []
        var singleAssetCalls: [String] = []
        var currentTokenAsyncCalls = 0
        var changesCallCount = 0
        var onChanges: (@Sendable (Data?) async -> ScreenshotsChanges)?
        var onAssetsBatch: (@Sendable ([String]) async -> [ScreenshotsAsset])?
        var onCurrentTokenAsync: (@Sendable () async -> Data?)?
        var onExport: (@Sendable (String) async -> ScreenshotsExportResult)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var status: ScreenshotsAccess {
        get { self.state.withLock { $0.status } }
        set { self.state.withLock { $0.status = newValue } }
    }
    var assets: [ScreenshotsAsset] {
        get { self.state.withLock { $0.assets } }
        set { self.state.withLock { $0.assets = newValue } }
    }
    var exports: [String: ScreenshotsExportResult] {
        get { self.state.withLock { $0.exports } }
        set { self.state.withLock { $0.exports = newValue } }
    }
    var changeResult: ScreenshotsChanges {
        get { self.state.withLock { $0.changeResult } }
        set { self.state.withLock { $0.changeResult = newValue } }
    }
    var token: Data {
        get { self.state.withLock { $0.token } }
        set { self.state.withLock { $0.token = newValue } }
    }
    var screenshotsError: (any Error)? {
        get { self.state.withLock { $0.screenshotsError } }
        set { self.state.withLock { $0.screenshotsError = newValue } }
    }
    var assetsBatchCalls: [[String]] { self.state.withLock { $0.assetsBatchCalls } }
    var singleAssetCalls: [String] { self.state.withLock { $0.singleAssetCalls } }
    var currentTokenAsyncCalls: Int { self.state.withLock { $0.currentTokenAsyncCalls } }
    var changesCallCount: Int { self.state.withLock { $0.changesCallCount } }
    var onChanges: (@Sendable (Data?) async -> ScreenshotsChanges)? {
        get { self.state.withLock { $0.onChanges } }
        set { self.state.withLock { $0.onChanges = newValue } }
    }
    var onAssetsBatch: (@Sendable ([String]) async -> [ScreenshotsAsset])? {
        get { self.state.withLock { $0.onAssetsBatch } }
        set { self.state.withLock { $0.onAssetsBatch = newValue } }
    }
    var onCurrentTokenAsync: (@Sendable () async -> Data?)? {
        get { self.state.withLock { $0.onCurrentTokenAsync } }
        set { self.state.withLock { $0.onCurrentTokenAsync = newValue } }
    }
    var onExport: (@Sendable (String) async -> ScreenshotsExportResult)? {
        get { self.state.withLock { $0.onExport } }
        set { self.state.withLock { $0.onExport = newValue } }
    }

    func resetCallTracking() {
        self.state.withLock {
            $0.assetsBatchCalls = []
            $0.singleAssetCalls = []
            $0.currentTokenAsyncCalls = 0
            $0.changesCallCount = 0
        }
    }

    func access() -> ScreenshotsAccess { self.status }
    func requestAccess() async -> ScreenshotsAccess {
        self.state.withLock { state in
            if state.status == .notDetermined { state.status = .full }
            return state.status
        }
    }
    func screenshots(onOrAfter start: Date) async throws -> [ScreenshotsAsset] {
        let (error, assets) = self.state.withLock { ($0.screenshotsError, $0.assets) }
        if let error { throw error }
        return assets.filter { $0.created >= start }
    }
    func asset(localIdentifier: String) async -> ScreenshotsAsset? {
        self.state.withLock { state in
            state.singleAssetCalls.append(localIdentifier)
            return state.assets.first { $0.localIdentifier == localIdentifier }
        }
    }
    func assets(localIdentifiers: [String]) async -> [ScreenshotsAsset] {
        guard !localIdentifiers.isEmpty else { return [] }
        let hook = self.state.withLock { state -> (@Sendable ([String]) async -> [ScreenshotsAsset])? in
            state.assetsBatchCalls.append(localIdentifiers)
            return state.onAssetsBatch
        }
        if let hook {
            return await hook(localIdentifiers)
        }
        let wanted = Set(localIdentifiers)
        return self.state.withLock { state in
            state.assets.filter { wanted.contains($0.localIdentifier) }
        }
    }
    func changes(since token: Data?) async -> ScreenshotsChanges {
        let (hook, fallback) = self.state.withLock { state -> ((@Sendable (Data?) async -> ScreenshotsChanges)?, ScreenshotsChanges) in
            state.changesCallCount += 1
            return (state.onChanges, state.changeResult)
        }
        if let hook {
            return await hook(token)
        }
        return fallback
    }
    func currentToken() -> Data? { self.token }
    func currentTokenAsync() async -> Data? {
        let (hook, fallback) = self.state.withLock { state -> ((@Sendable () async -> Data?)?, Data) in
            state.currentTokenAsyncCalls += 1
            return (state.onCurrentTokenAsync, state.token)
        }
        if let hook {
            return await hook()
        }
        return fallback
    }
    func export(localIdentifier: String) async -> ScreenshotsExportResult {
        let (hook, fallback) = self.state.withLock { ($0.onExport, $0.exports[localIdentifier] ?? .missing) }
        if let hook {
            return await hook(localIdentifier)
        }
        return fallback
    }
    func setObserving(_ on: Bool) {}
}

private nonisolated final class FakeScreenshotsSender: ScreenshotsSending, @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<[ScreenshotsUpload]>(initialState: [])

    var sent: [ScreenshotsUpload] {
        get { self.storage.withLock { $0 } }
        set { self.storage.withLock { $0 = newValue } }
    }

    func send(_ upload: ScreenshotsUpload) async throws {
        self.storage.withLock { $0.append(upload) }
    }
}
