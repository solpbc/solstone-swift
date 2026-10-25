// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum CalendarNoteChange: String, Codable, Equatable, Sendable {
    case added
    case changed
    case removed
}

/// An event's identity: the calendar's own id for the series and, for an occurrence of a
/// repeating event, its original start. It has no calendar or device part, so the same
/// meeting in two calendars is one event.
nonisolated struct CalendarIdentity: Hashable, Codable, Sendable {
    let event: String
    let occurrence: String?

    var key: String {
        "\(self.event)\u{1F}\(self.occurrence ?? "\u{0}")"
    }

    /// Lines in a file are sorted by `event`, then `occurrence` with `null` first.
    static func precedes(_ lhs: CalendarIdentity, _ rhs: CalendarIdentity) -> Bool {
        if lhs.event != rhs.event {
            return CalendarWire.precedes(lhs.event, rhs.event)
        }
        return CalendarWire.precedes(lhs.occurrence, rhs.occurrence)
    }
}

nonisolated struct CalendarNoteOrganizer: Equatable, Sendable {
    let name: String?
    let email: String?

    var json: CalendarJSON {
        .object(["name": .optional(self.name), "email": .optional(self.email)])
    }
}

nonisolated struct CalendarNoteAttendee: Equatable, Sendable {
    let name: String?
    let email: String?
    let status: String
    let you: Bool

    var json: CalendarJSON {
        .object([
            "name": .optional(self.name),
            "email": .optional(self.email),
            "status": .string(self.status),
            "you": .bool(self.you),
        ])
    }

    /// By email then name, `null` first; status and the owner's mark only break exact ties.
    static func precedes(_ lhs: CalendarNoteAttendee, _ rhs: CalendarNoteAttendee) -> Bool {
        if lhs.email != rhs.email { return CalendarWire.precedes(lhs.email, rhs.email) }
        if lhs.name != rhs.name { return CalendarWire.precedes(lhs.name, rhs.name) }
        if lhs.status != rhs.status { return CalendarWire.precedes(lhs.status, rhs.status) }
        return !lhs.you && rhs.you
    }
}

/// Everything a note says about an event except what kind of change it is and when.
nonisolated struct CalendarNoteContent: Equatable, Sendable {
    let identity: CalendarIdentity
    let calendar: String?
    /// The account the calendar belongs to. It rides with `calendar`.
    let account: String?
    let title: String?
    let location: String?
    let notes: String?
    let url: String?
    let start: String?
    let end: String?
    let allDay: Bool?
    let timeZone: String?
    let organizer: CalendarNoteOrganizer?
    let attendees: [CalendarNoteAttendee]
    let repeats: String?

    /// A `removed` note says only what was cancelled: the last title, calendar and account sent.
    static func removed(identity: CalendarIdentity, title: String?, calendar: String?, account: String?) -> CalendarNoteContent {
        CalendarNoteContent(
            identity: identity,
            calendar: calendar,
            account: account,
            title: title,
            location: nil,
            notes: nil,
            url: nil,
            start: nil,
            end: nil,
            allDay: nil,
            timeZone: nil,
            organizer: nil,
            attendees: [],
            repeats: nil
        )
    }

    var fields: [String: CalendarJSON] {
        [
            "v": .int(1),
            "event": .string(self.identity.event),
            "occurrence": .optional(self.identity.occurrence),
            "calendar": .optional(self.calendar),
            "account": .optional(self.account),
            "title": .optional(self.title),
            "location": .optional(self.location),
            "notes": .optional(self.notes),
            "url": .optional(self.url),
            "start": .optional(self.start),
            "end": .optional(self.end),
            "all_day": self.allDay.map(CalendarJSON.bool) ?? .null,
            "time_zone": .optional(self.timeZone),
            "organizer": self.organizer?.json ?? .null,
            "attendees": .array(self.attendees.map(\.json)),
            "repeats": .optional(self.repeats),
        ]
    }

    /// A fingerprint of every field a note carries except its change, `changed_at`,
    /// `calendar` and `account`. Two versions with the same fingerprint are the same event.
    /// Which followed calendar holds a copy is never a change by itself: switching a calendar
    /// off or on sends nothing, and the last calendar name and account sent stand until some
    /// other field changes.
    var fingerprint: String {
        var fields = self.fields
        fields.removeValue(forKey: "calendar")
        fields.removeValue(forKey: "account")
        return Self.digest(fields)
    }

    /// The same, leaving out `start` and `end` too: equal when a change only moved the event.
    var placementFreeFingerprint: String {
        var fields = self.fields
        fields.removeValue(forKey: "calendar")
        fields.removeValue(forKey: "account")
        fields.removeValue(forKey: "start")
        fields.removeValue(forKey: "end")
        return Self.digest(fields)
    }

    private static func digest(_ fields: [String: CalendarJSON]) -> String {
        String(CalendarWire.sha256Hex(Data(CalendarJSON.object(fields).serialized.utf8)).prefix(32))
    }
}

nonisolated struct CalendarNoteLine: Equatable, Sendable {
    let change: CalendarNoteChange
    let changedAt: CalendarWireInstant
    let content: CalendarNoteContent

    /// The line exactly as it is written, with no newline. `nil` when `changed_at` cannot be
    /// written.
    var json: String? {
        guard let changedAt = self.changedAt.rfc3339 else { return nil }
        var fields = self.content.fields
        fields["change"] = .string(self.change.rawValue)
        fields["changed_at"] = .string(changedAt)
        return CalendarJSON.object(fields).serialized
    }
}

/// Checks a note against the calendar note contract before it is put in a file. A phone
/// should never send a journal a line the journal would refuse.
nonisolated enum CalendarNoteValidator {
    enum Problem: Equatable, Sendable {
        case emptyEvent
        case occurrence
        case changedAt
        case allDay
        case start
        case end
        case endBeforeStart
        case removedCarriesDetail
        case attendeeStatus
        case tooLarge
    }

    static let statuses: Set<String> = ["accepted", "declined", "tentative", "pending", "unknown"]

    static func problem(with line: CalendarNoteLine) -> Problem? {
        let content = line.content
        guard !content.identity.event.isEmpty else { return .emptyEvent }
        if let occurrence = content.identity.occurrence, Shape(occurrence) == nil {
            return .occurrence
        }
        guard line.changedAt.rfc3339 != nil else { return .changedAt }
        guard content.attendees.allSatisfy({ self.statuses.contains($0.status) }) else { return .attendeeStatus }
        switch line.change {
        case .removed:
            guard content.location == nil, content.notes == nil, content.url == nil,
                  content.start == nil, content.end == nil, content.allDay == nil,
                  content.timeZone == nil, content.organizer == nil, content.attendees.isEmpty,
                  content.repeats == nil
            else {
                return .removedCarriesDetail
            }
        case .added, .changed:
            guard let allDay = content.allDay else { return .allDay }
            guard let startText = content.start, let start = Shape(startText) else { return .start }
            guard start.isDate == allDay else { return .start }
            if let endText = content.end {
                guard let end = Shape(endText), end.isDate == allDay, end.isFloating == start.isFloating else {
                    return .end
                }
                guard !end.isBefore(start) else { return .endBeforeStart }
            }
        }
        guard let json = line.json, json.utf8.count + 1 <= CalendarNoteFiles.maxBytes else { return .tooLarge }
        return nil
    }

    /// The shapes a date or time takes on the wire.
    private struct Shape {
        let isDate: Bool
        let isFloating: Bool
        /// Seconds since the epoch: of the instant for a zoned time, or of the wall-clock time
        /// read as UTC for a date or floating time.
        let seconds: Int64

        init?(_ text: String) {
            let bytes = Array(text.utf8)
            func number(_ range: Range<Int>) -> Int? {
                guard range.upperBound <= bytes.count else { return nil }
                var value = 0
                for byte in bytes[range] {
                    guard (48...57).contains(byte) else { return nil }
                    value = value * 10 + Int(byte - 48)
                }
                return value
            }
            func at(_ index: Int, _ character: Character) -> Bool {
                index < bytes.count && bytes[index] == character.asciiValue
            }
            guard let year = number(0..<4), at(4, "-"), let month = number(5..<7), at(7, "-"),
                  let day = number(8..<10)
            else {
                return nil
            }
            var components = DateComponents(year: year, month: month, day: day)
            if bytes.count == 10 {
                self.isDate = true
                self.isFloating = true
                guard let date = Self.date(components) else { return nil }
                self.seconds = date
                return
            }
            guard at(10, "T"), let hour = number(11..<13), at(13, ":"), let minute = number(14..<16),
                  at(16, ":"), let second = number(17..<19)
            else {
                return nil
            }
            components.hour = hour
            components.minute = minute
            components.second = second
            guard let wall = Self.date(components) else { return nil }
            self.isDate = false
            switch bytes.count {
            case 19:
                self.isFloating = true
                self.seconds = wall
            case 20 where at(19, "Z"):
                self.isFloating = false
                self.seconds = wall
            case 25 where (at(19, "+") || at(19, "-")) && at(22, ":"):
                guard let hours = number(20..<22), let minutes = number(23..<25) else { return nil }
                let offset = Int64(hours * 3600 + minutes * 60) * (at(19, "-") ? -1 : 1)
                self.isFloating = false
                self.seconds = wall - offset
            default:
                return nil
            }
        }

        func isBefore(_ other: Shape) -> Bool {
            self.seconds < other.seconds
        }

        private static func date(_ components: DateComponents) -> Int64? {
            let calendar = CalendarWire.gregorianUTC
            guard let date = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                      == DateComponents(
                          year: components.year,
                          month: components.month,
                          day: components.day,
                          hour: components.hour ?? 0,
                          minute: components.minute ?? 0,
                          second: components.second ?? 0
                      )
            else {
                return nil
            }
            return CalendarWire.wholeSeconds(date)
        }
    }
}

/// Turns one read event into what a note says about it.
nonisolated enum CalendarNoteBuilder {
    /// The identity of an event or occurrence. A moved occurrence's external id is the series
    /// id plus `/RID=…`; removing that suffix gives the series id, so a moved occurrence keeps
    /// the identity it had before it moved.
    static func identity(of event: CalendarEventRecord, deviceTimeZone: TimeZone) -> CalendarIdentity? {
        let external = event.externalID.flatMap { $0.isEmpty ? nil : $0 }
        let series: String
        if let external {
            if let range = external.range(of: "/RID=") {
                series = String(external[..<range.lowerBound])
            } else {
                series = external
            }
        } else {
            series = event.itemID
        }
        let eventID = series.isEmpty ? event.itemID : series
        guard !eventID.isEmpty else { return nil }
        guard self.repeats(event) else {
            return CalendarIdentity(event: eventID, occurrence: nil)
        }
        guard let original = event.occurrenceDate ?? event.start else { return nil }
        let occurrence: String?
        if event.isAllDay {
            occurrence = CalendarWire.dateOnly(original, in: deviceTimeZone)
        } else if event.timeZoneIdentifier != nil {
            occurrence = CalendarWire.utcZ(original)
        } else {
            occurrence = CalendarWire.floating(original, in: deviceTimeZone)
        }
        guard let occurrence else { return nil }
        return CalendarIdentity(event: eventID, occurrence: occurrence)
    }

    /// An occurrence counts as repeating when it has repeat rules, is detached, or its id
    /// carries `/RID=`.
    static func repeats(_ event: CalendarEventRecord) -> Bool {
        !event.repeatRules.isEmpty || event.isDetached || (event.externalID?.contains("/RID=") ?? false)
    }

    /// `nil` for an event with no start, which is skipped. `seriesRule` is the series' rule, for
    /// an occurrence that carries none of its own.
    static func content(
        of event: CalendarEventRecord,
        identity: CalendarIdentity,
        calendarName: String,
        accountName: String?,
        deviceTimeZone: TimeZone,
        seriesRule: CalendarRepeatRule?
    ) -> CalendarNoteContent? {
        guard let startDate = event.start else { return nil }
        let start: String?
        var end: String?
        let zone: String?
        if event.isAllDay {
            start = CalendarWire.dateOnly(startDate, in: deviceTimeZone)
            if let endDate = event.end, endDate >= startDate {
                // iOS gives an all-day event's end as the last instant of its last day; the
                // note's end is the day after.
                end = CalendarWire.dayAfter(endDate, in: deviceTimeZone)
            }
            zone = nil
        } else if let identifier = event.timeZoneIdentifier, let timeZone = TimeZone(identifier: identifier) {
            start = CalendarWire.zoned(startDate, in: timeZone)
            if let endDate = event.end, endDate >= startDate {
                end = CalendarWire.zoned(endDate, in: timeZone)
            }
            zone = timeZone.identifier
        } else {
            start = CalendarWire.floating(startDate, in: deviceTimeZone)
            if let endDate = event.end, endDate >= startDate {
                end = CalendarWire.floating(endDate, in: deviceTimeZone)
            }
            zone = nil
        }
        guard let start else { return nil }
        var repeats: String?
        if self.repeats(event) {
            repeats = event.repeatRules.first?.plainDescription ?? seriesRule?.plainDescription
        }
        return CalendarNoteContent(
            identity: identity,
            calendar: calendarName,
            account: self.nonEmpty(accountName?.trimmingCharacters(in: .whitespacesAndNewlines)),
            title: event.title,
            location: self.nonEmpty(event.location),
            notes: self.nonEmpty(event.notes),
            url: event.url?.absoluteString,
            start: start,
            end: end,
            allDay: event.isAllDay,
            timeZone: zone,
            organizer: event.organizer.flatMap { participant in
                let organizer = CalendarNoteOrganizer(name: self.nonEmpty(participant.name), email: self.email(participant.url))
                return organizer.name == nil && organizer.email == nil ? nil : organizer
            },
            attendees: event.attendees.map { participant in
                CalendarNoteAttendee(
                    name: self.nonEmpty(participant.name),
                    email: self.email(participant.url),
                    status: participant.status.wireValue,
                    you: participant.isCurrentUser
                )
            }.sorted(by: CalendarNoteAttendee.precedes),
            repeats: repeats
        )
    }

    /// An email comes from a participant's `mailto:` address.
    static func email(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let text = url.absoluteString
        guard let colon = text.firstIndex(of: ":") else { return nil }
        var address = String(text[text.index(after: colon)...])
        if let query = address.firstIndex(of: "?") {
            address = String(address[..<query])
        }
        return self.nonEmpty(address.removingPercentEncoding ?? address)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// A note ready to file: its identity, its written line and the window it belongs to.
nonisolated struct CalendarFiledLine: Equatable, Sendable, Codable {
    let identity: CalendarIdentity
    let json: String
    let window: CalendarWindow
}

/// One calendar note file, ready to go to the journal.
nonisolated struct CalendarNoteFile: Equatable, Sendable, Codable {
    let window: CalendarWindow
    let bytes: Data
    let sha256: String
    let lineCount: Int
    let identityKeys: [String]

    var name: String {
        "calendar_\(self.sha256).jsonl"
    }

    /// Derived from the file's bytes, so the same file is always the same transfer item.
    var itemID: UUID {
        CalendarNoteFiles.itemID(sha256: self.sha256)
    }
}

nonisolated enum CalendarNoteFiles {
    static let maxLines = 5_000
    static let maxBytes = 8 * 1024 * 1024

    /// Groups lines by window, sorts each window by identity, and splits a window into
    /// consecutive files of at most `maxLines` lines and `maxBytes` bytes. The same lines in
    /// any order give the same files.
    static func files(
        from lines: [CalendarFiledLine],
        maxLines: Int = Self.maxLines,
        maxBytes: Int = Self.maxBytes
    ) -> [CalendarNoteFile] {
        let byWindow = Dictionary(grouping: lines, by: \.window.key)
        var files: [CalendarNoteFile] = []
        for windowKey in byWindow.keys.sorted(by: CalendarWire.precedes) {
            var seen: Set<String> = []
            let sorted = byWindow[windowKey]!.sorted { lhs, rhs in
                if lhs.identity != rhs.identity {
                    return CalendarIdentity.precedes(lhs.identity, rhs.identity)
                }
                return CalendarWire.precedes(lhs.json, rhs.json)
            }.filter { seen.insert($0.identity.key).inserted }
            var chunk: [CalendarFiledLine] = []
            var chunkBytes = 0
            func flush() {
                guard !chunk.isEmpty else { return }
                files.append(self.file(chunk))
                chunk = []
                chunkBytes = 0
            }
            for line in sorted {
                let size = line.json.utf8.count + 1
                if chunk.count >= maxLines || (chunkBytes + size > maxBytes && !chunk.isEmpty) {
                    flush()
                }
                chunk.append(line)
                chunkBytes += size
            }
            flush()
        }
        return files
    }

    static func file(_ lines: [CalendarFiledLine]) -> CalendarNoteFile {
        var bytes = Data()
        for line in lines {
            bytes.append(contentsOf: line.json.utf8)
            bytes.append(0x0A)
        }
        return CalendarNoteFile(
            window: lines[0].window,
            bytes: bytes,
            sha256: CalendarWire.sha256Hex(bytes),
            lineCount: lines.count,
            identityKeys: lines.map(\.identity.key)
        )
    }

    static func itemID(sha256: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let hex = Array(sha256.utf8)
        for index in 0..<16 where index * 2 + 1 < hex.count {
            bytes[index] = (Self.nibble(hex[index * 2]) << 4) | Self.nibble(hex[index * 2 + 1])
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func nibble(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        case 65...70: byte - 55
        default: 0
        }
    }
}
