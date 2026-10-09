// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Rewrites a segment name an older build stored in the 12-hour form into the 24-hour name of the
/// same date and time.
///
/// Builds up to 2.0.6 (115) formatted a segment's clock with the device's locale. With the 12-hour
/// preference forced on, that gave `85000<U+202F>AM_13` for 08:50:00 and 13 seconds: a clock with
/// no leading zero, a narrow no-break space, and a day-period marker. The journal refuses such a
/// name, and every later build sent the stored name again as it was. The day is unaffected.
///
/// Nothing here guesses. A name is rewritten only when it matches the 12-hour form exactly, its
/// day is eight ASCII digits, and the item's own start instant agrees with the rewritten clock to
/// within a plausible time zone offset. Everything else is left as it is, and counted.
nonisolated enum TransferSegmentRepair {
    /// The day-period marker as it was stored. The case is kept because the persistent tally
    /// counts each form separately.
    enum DayPeriod: String, CaseIterable, Sendable {
        case upperAM = "AM"
        case upperPM = "PM"
        case lowerAM = "am"
        case lowerPM = "pm"

        var isMorning: Bool { self == .upperAM || self == .lowerAM }
    }

    struct Repair: Equatable, Sendable {
        /// The 24-hour name, `HHmmss_<same duration digits>`.
        let segment: String
        let dayPeriod: DayPeriod
    }

    enum Verdict: Equatable, Sendable {
        /// The segment already has the wire form `^[0-9]{6}_[0-9]+$`. Nothing to do.
        case wireForm
        case repairable(Repair)
        /// The segment is not in the wire form and is not exactly the 12-hour form either (or the
        /// 12-hour form has a day that is not eight ASCII digits).
        case noTwelveHourMatch
        /// The segment is in the 12-hour form, but its date and time do not fit the item's start
        /// instant at any plausible zone offset.
        case sanityCheckFailed
    }

    /// The farthest behind and ahead of GMT a wall clock can be: -12:00 and +14:00.
    static let minimumOffsetSeconds = -43_200
    static let maximumOffsetSeconds = 50_400
    /// Zone offsets are whole multiples of 15 minutes.
    static let offsetGranularitySeconds = 900
    /// A start instant that was rounded when it was stored can sit a second from the clock.
    static let offsetToleranceSeconds = 1

    static func verdict(for ingest: TransferObserverIngestMetadata) -> Verdict {
        let segment = Array(ingest.segment.unicodeScalars)
        if Self.isWireForm(segment) {
            return .wireForm
        }
        guard let day = Self.parseDay(ingest.day),
              let twelveHour = Self.parseTwelveHour(segment)
        else {
            return .noTwelveHourMatch
        }
        let hour24: Int
        switch (twelveHour.dayPeriod.isMorning, twelveHour.hour) {
        case (true, 12): hour24 = 0
        case (true, let hour): hour24 = hour
        case (false, 12): hour24 = 12
        case (false, let hour): hour24 = hour + 12
        }
        guard let offset = Self.offsetSeconds(
            day: day,
            hour: hour24,
            minute: twelveHour.minute,
            second: twelveHour.second,
            startedAt: ingest.startedAt
        ), Self.isPlausibleOffset(offset)
        else {
            return .sanityCheckFailed
        }
        let clock = String(format: "%02d%02d%02d", hour24, twelveHour.minute, twelveHour.second)
        return .repairable(Repair(segment: "\(clock)_\(twelveHour.duration)", dayPeriod: twelveHour.dayPeriod))
    }

    /// Whether `day + clock`, read as a GMT wall time, sits a plausible zone offset from the start
    /// instant: between -12:00 and +14:00 inclusive, and within a second of a multiple of 15
    /// minutes. The offset is signed and is never reduced modulo a day.
    static func isPlausibleOffset(_ offset: Int) -> Bool {
        guard offset >= Self.minimumOffsetSeconds, offset <= Self.maximumOffsetSeconds else { return false }
        let remainder = ((offset % Self.offsetGranularitySeconds) + Self.offsetGranularitySeconds)
            % Self.offsetGranularitySeconds
        return remainder <= Self.offsetToleranceSeconds
            || remainder >= Self.offsetGranularitySeconds - Self.offsetToleranceSeconds
    }

    /// Seconds from the start instant (whole seconds, fraction dropped) to the wall time read as
    /// GMT. `nil` when the day is not a real calendar date or the start instant cannot be placed.
    static func offsetSeconds(day: Day, hour: Int, minute: Int, second: Int, startedAt: Date) -> Int? {
        guard (1...12).contains(day.month), day.day >= 1,
              day.day <= Self.daysInMonth(year: day.year, month: day.month)
        else { return nil }
        let start = startedAt.timeIntervalSince1970
        guard start.isFinite, abs(start) < 1e11 else { return nil }
        let wall = Self.daysFromCivil(year: day.year, month: day.month, day: day.day) * 86_400
            + hour * 3_600 + minute * 60 + second
        return wall - Int(start.rounded(.down))
    }

    struct Day: Equatable, Sendable {
        let year: Int
        let month: Int
        let day: Int
    }

    /// `^[0-9]{8}$` over the scalars. Whether it is a real date is the sanity check's to say.
    static func parseDay(_ value: String) -> Day? {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 8 else { return nil }
        var digits: [Int] = []
        for scalar in scalars {
            guard let digit = Self.digit(scalar) else { return nil }
            digits.append(digit)
        }
        let year = digits[0] * 1_000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        let month = digits[4] * 10 + digits[5]
        return Day(year: year, month: month, day: digits[6] * 10 + digits[7])
    }

    // MARK: - grammar

    struct TwelveHour: Equatable, Sendable {
        let hour: Int
        let minute: Int
        let second: Int
        let dayPeriod: DayPeriod
        /// The duration digits exactly as stored.
        let duration: String
    }

    /// `^[0-9]{6}_[0-9]+$`, over the scalars, so that neither a line terminator at the end nor
    /// another script's digits can match.
    static func isWireForm(_ scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.count >= 8, scalars[6] == "_" else { return false }
        return scalars[0..<6].allSatisfy { Self.digit($0) != nil }
            && scalars[7...].allSatisfy { Self.digit($0) != nil }
    }

    /// Exactly `^(1[0-2]|0?[1-9])([0-5][0-9])([0-5][0-9])\u{202F}(AM|PM|am|pm)_([0-9]+)$`.
    static func parseTwelveHour(_ scalars: [Unicode.Scalar]) -> TwelveHour? {
        var clockDigits: [Int] = []
        var index = 0
        while index < scalars.count, let digit = Self.digit(scalars[index]) {
            clockDigits.append(digit)
            index += 1
        }
        // Five digits is a one-digit hour; six is a two-digit hour with or without a leading zero.
        guard clockDigits.count == 5 || clockDigits.count == 6 else { return nil }
        let hourDigitCount = clockDigits.count - 4
        // After the clock: U+202F, two day-period scalars, `_`, then at least one duration digit.
        guard scalars.count >= index + 5, scalars[index].value == 0x202F else { return nil }
        let hour = hourDigitCount == 1 ? clockDigits[0] : clockDigits[0] * 10 + clockDigits[1]
        let minute = clockDigits[hourDigitCount] * 10 + clockDigits[hourDigitCount + 1]
        let second = clockDigits[hourDigitCount + 2] * 10 + clockDigits[hourDigitCount + 3]
        guard (1...12).contains(hour), minute <= 59, second <= 59 else { return nil }
        let dayPeriodText = String(String.UnicodeScalarView([scalars[index + 1], scalars[index + 2]]))
        guard let dayPeriod = DayPeriod(rawValue: dayPeriodText), scalars[index + 3] == "_" else { return nil }
        let durationScalars = scalars[(index + 4)...]
        guard !durationScalars.isEmpty, durationScalars.allSatisfy({ Self.digit($0) != nil }) else { return nil }
        return TwelveHour(
            hour: hour,
            minute: minute,
            second: second,
            dayPeriod: dayPeriod,
            duration: String(String.UnicodeScalarView(durationScalars))
        )
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        (0x30...0x39).contains(scalar.value) ? Int(scalar.value) - 0x30 : nil
    }

    // MARK: - calendar

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days from 1970-01-01 to the given proleptic Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// How many attention items keep a segment name that is not in the wire form, split by why the
/// repair left them alone. Recomputed from the items as they are, never stored.
nonisolated struct UnrepairedSegmentNameCounts: Equatable, Sendable {
    var noTwelveHourMatch = 0
    var sanityCheckFailed = 0

    init(noTwelveHourMatch: Int = 0, sanityCheckFailed: Int = 0) {
        self.noTwelveHourMatch = noTwelveHourMatch
        self.sanityCheckFailed = sanityCheckFailed
    }

    init(manifests: [TransferManifest]) {
        for manifest in manifests {
            guard let ingest = manifest.observerIngest else { continue }
            switch TransferSegmentRepair.verdict(for: ingest) {
            case .noTwelveHourMatch: self.noTwelveHourMatch += 1
            case .sanityCheckFailed: self.sanityCheckFailed += 1
            case .wireForm, .repairable: break
            }
        }
    }

    var isEmpty: Bool { self.noTwelveHourMatch == 0 && self.sanityCheckFailed == 0 }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            noTwelveHourMatch: lhs.noTwelveHourMatch + rhs.noTwelveHourMatch,
            sanityCheckFailed: lhs.sanityCheckFailed + rhs.sanityCheckFailed
        )
    }
}

/// What the spool has done about 12-hour segment names, kept in one small file in the spool root
/// so it outlives the items it counts. It holds counts and two times and nothing that names an
/// item, a day or a segment.
nonisolated struct SegmentRepairTally: Codable, Equatable, Sendable {
    var repaired: Int
    /// Repairs by the marker as it was stored: `AM`, `PM`, `am`, `pm`.
    var repairedByForm: [String: Int]
    /// Attempts that failed on a delete or a write; a later launch tries the item again.
    var failures: Int
    var firstRepairedAt: Date?
    var lastRepairedAt: Date?

    static let empty = SegmentRepairTally(repaired: 0, repairedByForm: [:], failures: 0)

    init(
        repaired: Int = 0,
        repairedByForm: [String: Int] = [:],
        failures: Int = 0,
        firstRepairedAt: Date? = nil,
        lastRepairedAt: Date? = nil
    ) {
        self.repaired = repaired
        self.repairedByForm = repairedByForm
        self.failures = failures
        self.firstRepairedAt = firstRepairedAt
        self.lastRepairedAt = lastRepairedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.repaired = Swift.max(0, try container.decodeIfPresent(Int.self, forKey: .repaired) ?? 0)
        self.repairedByForm = (try container.decodeIfPresent([String: Int].self, forKey: .repairedByForm) ?? [:]).mapValues { Swift.max(0, $0) }
        self.failures = Swift.max(0, try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0)
        self.firstRepairedAt = try container.decodeIfPresent(Date.self, forKey: .firstRepairedAt)
        self.lastRepairedAt = try container.decodeIfPresent(Date.self, forKey: .lastRepairedAt)
    }

    var isEmpty: Bool { self.repaired == 0 && self.failures == 0 }

    mutating func noteRepair(dayPeriod: TransferSegmentRepair.DayPeriod, at date: Date) {
        self.repaired = Self.counted(self.repaired)
        self.repairedByForm[dayPeriod.rawValue] = Self.counted(self.repairedByForm[dayPeriod.rawValue, default: 0])
        self.firstRepairedAt = Swift.min(self.firstRepairedAt ?? date, date)
        self.lastRepairedAt = Swift.max(self.lastRepairedAt ?? date, date)
    }

    mutating func noteFailure() {
        self.failures = Self.counted(self.failures)
    }

    /// One more, without ever trapping: the tally is read back from a file, and a count in it that
    /// is negative or already at the largest value must not stop the launch that repairs an item.
    private static func counted(_ value: Int) -> Int {
        value >= Int.max ? Int.max : Swift.max(0, value) + 1
    }
}
