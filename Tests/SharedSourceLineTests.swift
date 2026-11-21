// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

/// The separator wrap rule: a line from another device breaks only after a separator or inside a
/// long name, so a state or a time is never split and no line starts with a separator.
@MainActor
final class SharedSourceLineTests: XCTestCase {
    private let held: Character = "\u{00A0}"

    private func device(_ entry: KnownSources.Entry, name: String, seen: Date) -> KnownSources.Device {
        KnownSources.Device(cid: "other", display_label: name, device_type: "laptop",
                            device_last_seen_at: ISO8601DateFormatter().string(from: seen), sources: [entry])
    }

    private func entry(_ source: String, detail: String?, state: String?) -> KnownSources.Entry {
        KnownSources.Entry(source: source, origin: "declared", detail: detail, state: state,
                           declared_at: nil, last_synced_at: nil)
    }

    func testWrappingLineHoldsStateAndTimeAndTheSpaceBeforeEachSeparator() {
        let now = Date()
        let seen = now.addingTimeInterval(-240)
        let cases: [(KnownSources.Entry, Bool)] = [
            (entry("obsidian", detail: "field notes from the long weekend", state: "needs_attention"), false),
            (entry("obsidian", detail: "field notes from the long weekend", state: "needs_attention"), true),
            (entry("calendar", detail: nil, state: "paused"), true),
            (entry("calendar", detail: nil, state: nil), true),
        ]
        for (entry, detail) in cases {
            let device = device(entry, name: "work laptop in the downstairs office", seen: seen)
            let shown = SharedSourceCopy.line(device: device, entry: entry, detail: detail, now: now)
            let wrapping = SharedSourceCopy.wrappingLine(device: device, entry: entry, detail: detail, now: now)
            XCTAssertEqual(String(wrapping.map { $0 == held ? " " : $0 }), shown)

            let fields = SharedSourceCopy.fields(device: device, entry: entry, detail: detail, now: now)
            let name = detail ? entry.detail : device.display_label
            let unbroken = name == nil ? fields : Array(fields.dropFirst())
            for field in unbroken where field.contains(" ") {
                XCTAssertTrue(wrapping.contains(String(field.map { $0 == " " ? held : $0 })), "\(field) can split")
            }
            if let name { XCTAssertTrue(wrapping.hasPrefix(name), "a long name keeps its own spaces") }
            let separator = String(held) + "·"
            XCTAssertEqual(wrapping.components(separatedBy: separator).count, fields.count,
                           "every separator holds to the part before it")
        }
    }

    func testTileNameGivesWayFirstWithNoSpaceBeforeTheEllipsis() {
        XCTAssertEqual(SharedSourceCopy.tileName("work laptop"), "work laptop")
        let long = SharedSourceCopy.tileName("work laptop in the downstairs office")
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 20)
        XCTAssertFalse(long.dropLast().last?.isWhitespace ?? true)
    }
}
