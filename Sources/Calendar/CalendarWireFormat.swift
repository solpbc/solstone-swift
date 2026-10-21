// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation

/// One instant as a calendar note writes it: whole seconds, and the offset it is written in.
/// An offset of `nil` means the instant is written in UTC with `Z`.
nonisolated struct CalendarWireInstant: Equatable, Hashable, Sendable {
    let seconds: Int64
    let offsetSeconds: Int?

    /// The instant as wall-clock time in `timeZone` at that moment. A zone whose offset then
    /// has seconds (some zones before 1972) cannot be written with an offset, so it is UTC.
    init(_ date: Date, timeZone: TimeZone) {
        self.init(seconds: CalendarWire.wholeSeconds(date), timeZone: timeZone)
    }

    init(seconds: Int64, timeZone: TimeZone) {
        self.seconds = seconds
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
        self.offsetSeconds = offset % 60 == 0 ? offset : nil
    }

    init(seconds: Int64, offsetSeconds: Int?) {
        self.seconds = seconds
        self.offsetSeconds = offsetSeconds
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(self.seconds))
    }

    /// Seconds since the epoch of the wall-clock time this instant is written as.
    var wallSeconds: Int64 {
        self.seconds + Int64(self.offsetSeconds ?? 0)
    }

    /// RFC 3339 with its offset, or `Z`. `nil` outside years 1 to 9999.
    var rfc3339: String? {
        guard let wall = CalendarWire.wallClock(self.wallSeconds) else { return nil }
        guard let offset = self.offsetSeconds else {
            return "\(wall.dateTime)Z"
        }
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        return "\(wall.dateTime)\(sign)\(CalendarWire.pad(magnitude / 3600, 2)):\(CalendarWire.pad((magnitude % 3600) / 60, 2))"
    }

    /// The journal's 5-minute window that holds this instant's written wall-clock time.
    var window: CalendarWindow? {
        guard let wall = CalendarWire.wallClock(self.wallSeconds) else { return nil }
        let secondOfDay = wall.hour * 3600 + wall.minute * 60 + wall.second
        let windowSecond = secondOfDay - secondOfDay % CalendarWindow.length
        return CalendarWindow(
            day: "\(CalendarWire.pad(wall.year, 4))\(CalendarWire.pad(wall.month, 2))\(CalendarWire.pad(wall.day, 2))",
            segment: "\(CalendarWire.pad(windowSecond / 3600, 2))\(CalendarWire.pad((windowSecond % 3600) / 60, 2))00_\(CalendarWindow.length)",
            start: Date(timeIntervalSince1970: TimeInterval(self.seconds - Int64(secondOfDay - windowSecond))),
            offsetSeconds: self.offsetSeconds ?? 0
        )
    }
}

/// A 5-minute window on the journal's 300-second grid, named the way the journal names it.
nonisolated struct CalendarWindow: Equatable, Hashable, Sendable, Codable {
    static let length = 300

    let day: String
    let segment: String
    /// When the window starts, as read in the offset of the note that named it.
    let start: Date
    let offsetSeconds: Int

    var key: String {
        "\(self.day)/\(self.segment)"
    }

    static func == (lhs: CalendarWindow, rhs: CalendarWindow) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.key)
    }
}

/// Date and time text for calendar notes. Everything here uses a fixed Gregorian calendar
/// and fixed digits, whatever calendar, locale or clock style the device is set to.
nonisolated enum CalendarWire {
    struct WallClock: Equatable, Sendable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int

        var date: String {
            "\(CalendarWire.pad(self.year, 4))-\(CalendarWire.pad(self.month, 2))-\(CalendarWire.pad(self.day, 2))"
        }

        var dateTime: String {
            "\(self.date)T\(CalendarWire.pad(self.hour, 2)):\(CalendarWire.pad(self.minute, 2)):\(CalendarWire.pad(self.second, 2))"
        }
    }

    static let utc = TimeZone(secondsFromGMT: 0)!

    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = self.utc
        return calendar
    }

    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    /// Truncates to whole seconds. Never rounds: 10:04:59.6 is 10:04:59.
    static func wholeSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// Wall-clock fields of `wallSeconds` read as UTC. `nil` outside years 1 to 9999.
    static func wallClock(_ wallSeconds: Int64) -> WallClock? {
        let components = self.gregorianUTC.dateComponents(
            [.era, .year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(wallSeconds))
        )
        guard components.era == 1,
              let year = components.year, (1...9999).contains(year),
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second
        else {
            return nil
        }
        return WallClock(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// `YYYY-MM-DD` of the day `date` falls on in `timeZone`.
    static func dateOnly(_ date: Date, in timeZone: TimeZone) -> String? {
        let seconds = self.wholeSeconds(date)
        let offset = timeZone.secondsFromGMT(for: date)
        return self.wallClock(seconds + Int64(offset))?.date
    }

    /// The day after `date`'s day in `timeZone`, as `YYYY-MM-DD`.
    static func dayAfter(_ date: Date, in timeZone: TimeZone) -> String? {
        let seconds = self.wholeSeconds(date)
        let offset = timeZone.secondsFromGMT(for: date)
        return self.wallClock(seconds + Int64(offset) + 86_400)?.date
    }

    /// Wall-clock time with no offset, as a floating event is written.
    static func floating(_ date: Date, in timeZone: TimeZone) -> String? {
        let seconds = self.wholeSeconds(date)
        let offset = timeZone.secondsFromGMT(for: date)
        return self.wallClock(seconds + Int64(offset))?.dateTime
    }

    /// UTC with `Z`, whole seconds.
    static func utcZ(_ date: Date) -> String? {
        CalendarWireInstant(seconds: self.wholeSeconds(date), offsetSeconds: nil).rfc3339
    }

    /// RFC 3339 in `timeZone`'s offset at that instant, or UTC with `Z` where that offset has
    /// seconds.
    static func zoned(_ date: Date, in timeZone: TimeZone) -> String? {
        CalendarWireInstant(date, timeZone: timeZone).rfc3339
    }

    /// The start of `date`'s day in `timeZone`.
    static func startOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        self.gregorian(in: timeZone).startOfDay(for: date)
    }

    /// The start of the year `date` falls in, in `timeZone`.
    static func startOfYear(_ date: Date, in timeZone: TimeZone) -> Date {
        let calendar = self.gregorian(in: timeZone)
        let year = calendar.component(.year, from: date)
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
    }

    static func adding(years: Int, to date: Date, in timeZone: TimeZone) -> Date {
        self.gregorian(in: timeZone).date(byAdding: .year, value: years, to: date) ?? date
    }

    static func adding(days: Int, to date: Date, in timeZone: TimeZone) -> Date {
        self.gregorian(in: timeZone).date(byAdding: .day, value: days, to: date) ?? date
    }

    static func adding(months: Int, to date: Date, in timeZone: TimeZone) -> Date {
        self.gregorian(in: timeZone).date(byAdding: .month, value: months, to: date) ?? date
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Orders text by its UTF-8 bytes, the same on every device and in every locale.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Orders optional text with `nil` first, then by UTF-8 bytes.
    static func precedes(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return false
        case (nil, _):
            return true
        case (_, nil):
            return false
        case (let lhs?, let rhs?):
            return self.precedes(lhs, rhs)
        }
    }
}

/// A JSON value written the one way calendar notes write it: compact, keys sorted, and every
/// string escaped the same way, so the same note is always the same bytes.
nonisolated indirect enum CalendarJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([CalendarJSON])
    case object([String: CalendarJSON])

    static func optional(_ value: String?) -> CalendarJSON {
        value.map(CalendarJSON.string) ?? .null
    }

    var serialized: String {
        var output = ""
        self.write(into: &output)
        return output
    }

    private func write(into output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .string(let value):
            Self.writeString(value, into: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(into: &output)
            }
            output += "]"
        case .object(let fields):
            output += "{"
            for (index, key) in fields.keys.sorted(by: CalendarWire.precedes).enumerated() {
                if index > 0 { output += "," }
                Self.writeString(key, into: &output)
                output += ":"
                fields[key]!.write(into: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += "\\u00" + String(format: "%02x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
