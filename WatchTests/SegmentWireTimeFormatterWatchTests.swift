// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

final class SegmentWireTimeFormatterWatchTests: XCTestCase {
    func testWatchSegmentKeysIgnoreLocaleAndCalendarPreferences() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-29T23:58:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let hostileSettings: [(String, Calendar.Identifier)] = [
            ("ar_SA", .gregorian), ("fa_IR", .gregorian),
            ("th_TH", .buddhist), ("ja_JP", .japanese),
        ]
        for (locale, calendar) in hostileSettings {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: locale)
            formatter.calendar = Calendar(identifier: calendar)
            formatter.timeZone = zone
            formatter.dateFormat = "yyyyMMddHHmmss"
            XCTAssertNotEqual(formatter.string(from: start), "20260930085800")
            SegmentWireTimeFormatter.configure(formatter)
            formatter.dateFormat = "yyyyMMddHHmmss"
            XCTAssertEqual(formatter.string(from: start), "20260930085800")
            XCTAssertEqual(WatchCaptureStoragePaths.dayString(for: start, timeZone: zone), "20260930")
            XCTAssertEqual(WatchCaptureStoragePaths.segmentString(for: start, durationSeconds: 300, timeZone: zone), "085800_300")
        }
    }
}
