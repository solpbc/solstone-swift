// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

@MainActor
final class SegmentWireTimeFormatterTests: XCTestCase {
    func testSegmentKeysOverrideLocaleAndCalendarPreferences() throws {
        let hostileSettings: [(String, Calendar.Identifier)] = [
            ("ar_SA", .gregorian), ("fa_IR", .gregorian),
            ("th_TH", .buddhist), ("ja_JP", .japanese),
        ]
        let cases = [
            ("2026-09-29T23:58:00Z", "Asia/Tokyo", "20260930", "085800", 32400),
            ("2026-11-01T07:15:00Z", "America/Denver", "20261101", "011500", -21600),
            ("2026-11-01T08:15:00Z", "America/Denver", "20261101", "011500", -25200),
            ("2026-03-08T09:05:00Z", "America/Denver", "20260308", "030500", -21600),
            ("2026-01-15T06:30:00Z", "Asia/Kolkata", "20260115", "120000", 19800),
        ]
        for (locale, calendar) in hostileSettings {
            for (instant, zoneID, day, clock, offset) in cases {
                let start = try XCTUnwrap(ISO8601DateFormatter().date(from: instant))
                let zone = try XCTUnwrap(TimeZone(identifier: zoneID))
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: locale)
                formatter.calendar = Calendar(identifier: calendar)
                formatter.timeZone = zone
                formatter.dateFormat = "yyyyMMddHHmmss"
                XCTAssertNotEqual(formatter.string(from: start), day + clock)
                SegmentWireTimeFormatter.configure(formatter)
                formatter.dateFormat = "yyyyMMddHHmmss"
                XCTAssertEqual(formatter.string(from: start), day + clock)
                XCTAssertEqual(zone.secondsFromGMT(for: start), offset)
                XCTAssertEqual(ObserverSegmentNaming.dayString(for: start, timeZone: zone), day)
                XCTAssertEqual(MobileSegmentUploader.dayString(for: start, timeZone: zone), day)
                XCTAssertEqual(ChunkSidecar.segmentString(for: start, durationSeconds: 300, timeZone: zone), clock + "_300")
                XCTAssertEqual(WatchCaptureStoragePaths.dayString(for: start, timeZone: zone), day)
                XCTAssertEqual(WatchCaptureStoragePaths.segmentString(for: start, durationSeconds: 300, timeZone: zone), clock + "_300")
                XCTAssertEqual(LinkedDeviceIngestViewMapper.segmentStart(forSegmentKey: clock + "_300", day: day, timeZone: TimeZone(secondsFromGMT: offset)!), start)
            }
        }
    }
}
