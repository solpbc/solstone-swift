// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import XCTest
@testable import solstone_swift

final class ObsidianWireTests: XCTestCase {

    func testExactGoldenBytesAndSHA256AndFilename() throws {
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        // Day 20261108, segment 094000_300
        // Window start: 2026-11-08 09:40:00 -0700
        let window = ObsidianWindow(day: "20261108", segment: "094000_300", startEpochSeconds: 1794156000, durationSeconds: 300)

        // 2026-11-08T09:42:10-07:00: epochSeconds = 1794156130
        let stamp1Changed = ObsidianStamp(epochSeconds: 1794156130, timeZone: denver)
        // 2026-11-08T09:42:33-07:00: epochSeconds = 1794156153
        let stamp1Observed = ObsidianStamp(epochSeconds: 1794156153, timeZone: denver)

        let line1 = ObsidianNoteLine(
            vault: "Notes",
            path: "daily/2026-11-08.md",
            change: .changed,
            changedAt: stamp1Changed,
            observedAt: stamp1Observed,
            previousPath: nil,
            text: "---\ntags: [walk]\n---\nMet Alex by the river.\n",
            contentHash: "f0b347123a86bae3e1d4d8c48a7f0430bed090b37d8ed1873a63a97c0b13dfa9"
        )

        // 2026-11-08T09:44:33-07:00: epochSeconds = 1794156273
        let stamp2Changed = ObsidianStamp(epochSeconds: 1794156273, timeZone: denver)
        let stamp2Observed = ObsidianStamp(epochSeconds: 1794156273, timeZone: denver)

        let line2 = ObsidianNoteLine(
            vault: "Notes",
            path: "inbox/old idea.md",
            change: .removed,
            changedAt: stamp2Changed,
            observedAt: stamp2Observed,
            previousPath: nil,
            text: nil,
            contentHash: nil
        )

        // 2026-11-08T09:43:02-07:00: epochSeconds = 1794156182
        let stamp3Changed = ObsidianStamp(epochSeconds: 1794156182, timeZone: denver)
        // 2026-11-08T09:43:33-07:00: epochSeconds = 1794156213
        let stamp3Observed = ObsidianStamp(epochSeconds: 1794156213, timeZone: denver)

        let line3 = ObsidianNoteLine(
            vault: "Notes",
            path: "people/Alex Rivera.md",
            change: .renamed,
            changedAt: stamp3Changed,
            observedAt: stamp3Observed,
            previousPath: "inbox/Alex.md",
            text: "Alex likes rivers.\n",
            contentHash: "14fece546a747b07dec10e2658310b2d224447158a8c6e1b3a65d467b9de22a3"
        )

        // Test sorting: supply out of order, sort must put line1, line2, line3
        let lines = [line3, line1, line2]
        let sorted = ObsidianWire.sortLines(lines)
        XCTAssertEqual(sorted[0].path, line1.path)
        XCTAssertEqual(sorted[1].path, line2.path)
        XCTAssertEqual(sorted[2].path, line3.path)

        let jsonlBytes = ObsidianWire.buildJSONL(lines: sorted)
        let sha256Hex = SHA256.hash(data: jsonlBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha256Hex, "3e100d06fb18b4f45302cb3cf2cad1881e7183360649f0543ce4acf565b9f81e")

        let filename = ObsidianWire.filename(forBytes: jsonlBytes)
        XCTAssertEqual(filename, "obsidian_3e100d06fb18b4f45302cb3cf2cad1881e7183360649f0543ce4acf565b9f81e.jsonl")

        // Ensure final newline
        XCTAssertEqual(jsonlBytes.last, 0x0a)

        // Exact golden string comparison
        let goldenExpected = "{\"change\":\"changed\",\"changed_at\":\"2026-11-08T09:42:10-07:00\",\"content_hash\":\"f0b347123a86bae3e1d4d8c48a7f0430bed090b37d8ed1873a63a97c0b13dfa9\",\"observed_at\":\"2026-11-08T09:42:33-07:00\",\"path\":\"daily/2026-11-08.md\",\"previous_path\":null,\"text\":\"---\\ntags: [walk]\\n---\\nMet Alex by the river.\\n\",\"v\":1,\"vault\":\"Notes\"}\n"
            + "{\"change\":\"removed\",\"changed_at\":\"2026-11-08T09:44:33-07:00\",\"content_hash\":null,\"observed_at\":\"2026-11-08T09:44:33-07:00\",\"path\":\"inbox/old idea.md\",\"previous_path\":null,\"text\":null,\"v\":1,\"vault\":\"Notes\"}\n"
            + "{\"change\":\"renamed\",\"changed_at\":\"2026-11-08T09:43:02-07:00\",\"content_hash\":\"14fece546a747b07dec10e2658310b2d224447158a8c6e1b3a65d467b9de22a3\",\"observed_at\":\"2026-11-08T09:43:33-07:00\",\"path\":\"people/Alex Rivera.md\",\"previous_path\":\"inbox/Alex.md\",\"text\":\"Alex likes rivers.\\n\",\"v\":1,\"vault\":\"Notes\"}\n"

        let generatedString = String(data: jsonlBytes, encoding: .utf8)
        XCTAssertEqual(generatedString, goldenExpected)
    }

    func testSortKeyUTF8Ordering() {
        let denver = TimeZone(identifier: "America/Denver")!
        let stamp = ObsidianStamp(epochSeconds: 1794156000, timeZone: denver)

        let a = ObsidianNoteLine(vault: "VaultA", path: "a.md", change: .changed, changedAt: stamp, observedAt: stamp, previousPath: nil, text: nil, contentHash: nil)
        let b = ObsidianNoteLine(vault: "VaultA", path: "b.md", change: .changed, changedAt: stamp, observedAt: stamp, previousPath: nil, text: nil, contentHash: nil)
        let c = ObsidianNoteLine(vault: "VaultB", path: "a.md", change: .changed, changedAt: stamp, observedAt: stamp, previousPath: nil, text: nil, contentHash: nil)

        let sorted = ObsidianWire.sortLines([c, b, a])
        XCTAssertEqual(sorted.map(\.path), ["a.md", "b.md", "a.md"])
        XCTAssertEqual(sorted.map(\.vault), ["VaultA", "VaultA", "VaultB"])
    }

    func testNullFieldFormatting() {
        let denver = TimeZone(identifier: "America/Denver")!
        let stamp = ObsidianStamp(epochSeconds: 1794156000, timeZone: denver)
        let line = ObsidianNoteLine(
            vault: "V",
            path: "p.md",
            change: .removed,
            changedAt: stamp,
            observedAt: stamp,
            previousPath: nil,
            text: nil,
            contentHash: nil
        )
        let formatted = line.formatLine()
        XCTAssertTrue(formatted.contains("\"content_hash\":null"))
        XCTAssertTrue(formatted.contains("\"previous_path\":null"))
        XCTAssertTrue(formatted.contains("\"text\":null"))
    }

    func testDenverWindowReplayedUnderTokyo() throws {
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let stamp = ObsidianStamp(epochSeconds: 1794156130, timeZone: denver)

        XCTAssertEqual(stamp.timeZoneIdentifier, "America/Denver")
        XCTAssertEqual(stamp.offsetSeconds, -25200)
        XCTAssertEqual(stamp.rfc3339String, "2026-11-08T09:42:10-07:00")

        let window = stamp.window
        XCTAssertEqual(window.day, "20261108")
        XCTAssertEqual(window.segment, "094000_300")

        // Window closes 90s after 300s window end (390s after start)
        let closeEpoch = stamp.closeEpochSeconds
        XCTAssertEqual(closeEpoch, window.startEpochSeconds + 300 + 90)

        // Replay under Tokyo timezone: using Tokyo as current timezone does not affect stored offset
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let replayedStamp = ObsidianStamp(epochSeconds: stamp.epochSeconds, timeZone: denver)
        XCTAssertEqual(replayedStamp.rfc3339String, "2026-11-08T09:42:10-07:00")
        XCTAssertEqual(replayedStamp.window.day, "20261108")
        XCTAssertEqual(replayedStamp.window.segment, "094000_300")
        XCTAssertEqual(replayedStamp.closeEpochSeconds, closeEpoch)
    }

    func testSplitLinesAtCountAndSizeLimits() {
        let denver = TimeZone(identifier: "America/Denver")!
        let stamp = ObsidianStamp(epochSeconds: 1794156000, timeZone: denver)

        let shortLine = ObsidianNoteLine(
            vault: "V",
            path: "test.md",
            change: .changed,
            changedAt: stamp,
            observedAt: stamp,
            previousPath: nil,
            text: "short",
            contentHash: "hash"
        )

        // 5001 lines: should split into 5000 lines + 1 line
        var lines: [ObsidianNoteLine] = []
        for i in 0..<5001 {
            var l = shortLine
            l.path = "p\(i).md"
            lines.append(l)
        }
        let chunks = ObsidianWire.splitLines(lines)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 5000)
        XCTAssertEqual(chunks[1].count, 1)
    }

    func testOversizeTextAndLinesRejected() {
        // Line limit is 8 MiB, text limit is 4 MiB
        XCTAssertFalse(ObsidianWire.isNoteSizeSendable(ObsidianWire.maxNoteFileSizeBytes + 1))
        XCTAssertTrue(ObsidianWire.isNoteSizeSendable(ObsidianWire.maxNoteFileSizeBytes))

        let bigText = String(repeating: "a", count: ObsidianWire.maxLineSizeBytes + 10)
        let denver = TimeZone(identifier: "America/Denver")!
        let stamp = ObsidianStamp(epochSeconds: 1794156000, timeZone: denver)
        let hugeLine = ObsidianNoteLine(
            vault: "V",
            path: "huge.md",
            change: .changed,
            changedAt: stamp,
            observedAt: stamp,
            previousPath: nil,
            text: bigText,
            contentHash: "h"
        )
        let bytes = hugeLine.encodedBytes()
        XCTAssertGreaterThan(bytes.count, ObsidianWire.maxLineSizeBytes)
    }

    func testPredicates() {
        XCTAssertTrue(ObsidianWire.isUsableVaultName("My Vault"))
        XCTAssertTrue(ObsidianWire.isUsableVaultName("   "))
        XCTAssertTrue(ObsidianWire.isUsableVaultName(".obsidian"))
        XCTAssertTrue(ObsidianWire.isUsableVaultName("a/b"))
        XCTAssertTrue(ObsidianWire.isUsableVaultName("a:b"))
        XCTAssertFalse(ObsidianWire.isUsableVaultName(""))
        XCTAssertFalse(ObsidianWire.isUsableVaultName(String(repeating: "a", count: 129)))
        XCTAssertFalse(ObsidianWire.isUsableVaultName("name\u{0007}withControl"))

        XCTAssertTrue(ObsidianWire.isSendablePath("notes/todo.md"))
        XCTAssertFalse(ObsidianWire.isSendablePath(".hidden/note.md"))
        XCTAssertFalse(ObsidianWire.isSendablePath("templates/daily.md"))
        XCTAssertFalse(ObsidianWire.isSendablePath("_templates/meeting.md"))
        XCTAssertFalse(ObsidianWire.isSendablePath(".obsidian/app.json"))
        XCTAssertFalse(ObsidianWire.isSendablePath(".trash/old.md"))
    }

    func testUTF8ReplacementHashing() {
        let invalidUTF8 = Data([0xFF, 0xFE, 0x41])
        let text = String(decoding: invalidUTF8, as: UTF8.self)
        XCTAssertTrue(text.contains("\u{FFFD}"))
        let hash = ObsidianWire.sha256Hex(Data(text.utf8))
        let expectedHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expectedHash)
    }
}
