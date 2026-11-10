// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os

private nonisolated let sourceIntakeLog = Logger(subsystem: "app.solstone.swift", category: "source-intake")

// `flock` is both a function and a struct, so a Swift import of the name is ambiguous.
@_silgen_name("flock")
private nonisolated func sourceIntakeFlock(_ fd: Int32, _ operation: Int32) -> Int32

nonisolated enum SourceIntakeError: Error, Equatable {
    case lockTimeout
}

nonisolated enum SourceIntakeResult: Equatable, Sendable {
    case recorded
    case unchanged
    /// The file is unreadable, or this caller does not fail the keep.
    case skipped
    case lockTimeout
    /// Calendar has not seeded yet. The caller flags the identity and does not create the file.
    case flagOnly
    /// The replace did not land. The caller leaves its own retry mark.
    case failed
}

nonisolated struct ObsidianUnappliedIntakeOp: Codable, Equatable, Sendable {
    var hash: String
    var intakeTime: Date
    var sequence: UInt64 = 0
    var kind: Kind = .keep
    var previousHash: String? = nil
    var baselineHashes: [String] = []

    enum Kind: String, Codable, Sendable { case seed, keep, move, remove }
}

nonisolated struct SourceIntakeLane: Equatable, Sendable {
    var total: Int
    var last: Date?
}

nonisolated struct SourceIntakeSnapshot: Equatable, Sendable {
    var started: String
    var audio: SourceIntakeLane
    var screen: SourceIntakeLane
    var location: SourceIntakeLane
    var calendar: SourceIntakeLane
    var safari: SourceIntakeLane
    var watch: SourceIntakeLane
    var obsidian: SourceIntakeLane
    var imports: SourceIntakeLane

    static let empty = SourceIntakeSnapshot(
        started: "",
        audio: SourceIntakeLane(total: 0, last: nil),
        screen: SourceIntakeLane(total: 0, last: nil),
        location: SourceIntakeLane(total: 0, last: nil),
        calendar: SourceIntakeLane(total: 0, last: nil),
        safari: SourceIntakeLane(total: 0, last: nil),
        watch: SourceIntakeLane(total: 0, last: nil),
        obsidian: SourceIntakeLane(total: 0, last: nil),
        imports: SourceIntakeLane(total: 0, last: nil)
    )
}

nonisolated enum SourceIntakeLoad: Equatable, Sendable {
    case unreadable
    case ready(SourceIntakeSnapshot)
}

nonisolated struct SourceIntakeReading: Equatable, Sendable {
    var time: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var isFix: Bool
}

nonisolated struct SourceIntakeSafariVisit: Equatable, Sendable {
    var instance: String
    var tab: String
    var url: String
}

nonisolated enum SourceIntakeDurationSource: Equatable, Sendable {
    case audio
    case screen
}

nonisolated enum SourceIntakeCalendarGate: Equatable, Sendable {
    case flagOnly(seen: Set<String>)
    case increment(seen: Set<String>)

    var seen: Set<String> {
        switch self {
        case .flagOnly(let seen), .increment(let seen):
            seen
        }
    }
}

nonisolated struct SourceIntakeCalendarLedger: Equatable, Sendable {
    var events: Int
    var seeded: Bool
    var seen: [String]
    var last: Date?
}

/// One install's private intake totals. The file lives in the app group, is excluded from
/// backup, and is never cleared. Callers in other processes share it through the lock file.
nonisolated final class SourceIntakeStore: @unchecked Sendable {
    static let directoryName = "SourceIntake"
    static let fileName = "intake.json"
    static let lockName = "intake.lock"

    let directoryURL: URL
    let timeZone: TimeZone
    var testFailNextReplace = false
    var testLockTimeout = false

    private let fileManager: FileManager

    init(containerRoot: URL, timeZone: TimeZone = .autoupdatingCurrent, fileManager: FileManager = .default) {
        self.directoryURL = containerRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
        self.timeZone = timeZone
        self.fileManager = fileManager
    }

    init(directoryURL: URL, timeZone: TimeZone = .autoupdatingCurrent, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.timeZone = timeZone
        self.fileManager = fileManager
    }

    var intakeFileURL: URL {
        self.directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    var lockFileURL: URL {
        self.directoryURL.appendingPathComponent(Self.lockName, isDirectory: false)
    }

    func load() -> SourceIntakeLoad {
        switch self.loadFile() {
        case .absent:
            return .ready(.empty)
        case .unreadable:
            return .unreadable
        case .ready(let file):
            return .ready(file.snapshot(parse: self.parseStamp))
        }
    }

    func lockFileInode() -> UInt64? {
        let path = self.lockFileURL.path
        guard self.fileManager.fileExists(atPath: path) else { return nil }
        guard let attributes = try? self.fileManager.attributesOfItem(atPath: path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return number.uint64Value
    }

    @discardableResult
    func recordDuration(source: SourceIntakeDurationSource, segmentID: UUID, duration: TimeInterval, now: Date) -> SourceIntakeResult {
        guard duration > 0 else { return .unchanged }
        let key = segmentID.uuidString.lowercased()
        let seconds = Int(duration.rounded(.down))
        return self.mutate(now: now, create: true) { file in
            var lane = file.lane(source)
            guard !lane.seen.contains(key) else { return false }
            lane.seen.append(key)
            lane.seconds += max(0, seconds)
            lane.last = self.stamp(now)
            file.setLane(source, lane)
            return true
        }
    }

    @discardableResult
    func recordLocation(segmentID: UUID, readings: [SourceIntakeReading], now: Date) -> SourceIntakeResult {
        let key = segmentID.uuidString.lowercased()
        return self.mutate(now: now, create: true) { file in
            guard !file.location.seen.contains(key) else { return false }
            guard self.foldLocation(readings, into: &file.location) else { return false }
            file.location.seen.append(key)
            return true
        }
    }

    @discardableResult
    func recordSafariVisits(_ visits: [SourceIntakeSafariVisit], now: Date) throws -> SourceIntakeResult {
        let result = self.mutate(now: now, create: true) { file in
            self.foldSafari(visits, now: now, into: &file)
        }
        if result == .lockTimeout {
            throw SourceIntakeError.lockTimeout
        }
        return result
    }

    @discardableResult
    func recordImport(itemID: String, now: Date) -> SourceIntakeResult {
        self.mutate(now: now, create: true) { file in
            guard !file.imports.seen.contains(itemID) else { return false }
            file.imports.seen.append(itemID)
            file.imports.items += 1
            file.imports.last = self.stamp(now)
            return true
        }
    }

    @discardableResult
    func seedObsidianVault(vaultID: String, seenHashes: [String]) -> SourceIntakeResult {
        let now = Date()
        return self.mutate(now: now, create: true) { file in
            var lane = file.obsidian ?? ObsidianLane()
            guard !lane.seededVaults.contains(vaultID) else { return false }
            lane.seededVaults.append(vaultID)
            for hash in seenHashes {
                if !lane.seen.contains(hash) {
                    lane.seen.append(hash)
                }
            }
            file.obsidian = lane
            return true
        }
    }

    @discardableResult
    func recordObsidianNew(vaultID: String, seenHash: String, now: Date) -> SourceIntakeResult {
        self.mutate(now: now, create: true) { file in
            var lane = file.obsidian ?? ObsidianLane()
            guard !lane.seen.contains(seenHash) else { return false }
            lane.seen.append(seenHash)
            lane.notes += 1
            lane.last = self.stamp(now)
            file.obsidian = lane
            return true
        }
    }

    /// Ordered replay is part of the same locked replacement as the count.
    /// A replayed rename must never remove the seen mark of a later new note
    /// that reused its old path.
    @discardableResult
    func applyObsidianOperation(vaultID: String, operation: ObsidianUnappliedIntakeOp) -> SourceIntakeResult {
        var outOfOrder = false
        let result = self.mutate(now: operation.intakeTime, create: true) { file in
            var lane = file.obsidian ?? ObsidianLane()
            var sequences = lane.appliedSequences ?? [:]
            guard operation.sequence > sequences[vaultID, default: 0] else { return false }
            guard operation.sequence == sequences[vaultID, default: 0] + 1 else { outOfOrder = true; return false }
            var seen = Set(lane.seen)
            switch operation.kind {
            case .seed:
                seen.formUnion(operation.baselineHashes)
                if !lane.seededVaults.contains(vaultID) { lane.seededVaults.append(vaultID) }
            case .keep:
                if seen.insert(operation.hash).inserted {
                    lane.notes += 1
                    let stamp = self.stamp(operation.intakeTime)
                    if lane.last.flatMap(self.parseStamp).map({ operation.intakeTime > $0 }) ?? true { lane.last = stamp }
                }
            case .move:
                if let previous = operation.previousHash { seen.remove(previous) }
                seen.insert(operation.hash)
            case .remove:
                seen.remove(operation.hash)
            }
            sequences[vaultID] = operation.sequence
            lane.appliedSequences = sequences
            lane.seen = seen.sorted()
            file.obsidian = lane
            return true
        }
        return outOfOrder ? .failed : result
    }

    @discardableResult
    func recordWatch(id: UUID, duration: TimeInterval, lost: Bool, now: Date) -> SourceIntakeResult {
        let key = id.uuidString.lowercased()
        return self.mutate(now: now, create: true) { file in
            guard !file.watch.seen.contains(key) else { return false }
            file.watch.seen.append(key)
            if lost || duration <= 0 {
                return true
            }
            file.watch.seconds += max(0, Int(duration.rounded(.down)))
            file.watch.last = self.stamp(now)
            return true
        }
    }

    func calendarGate() -> SourceIntakeCalendarGate {
        do {
            return try self.withLock {
                switch self.loadFile() {
                case .absent, .unreadable:
                    return .flagOnly(seen: [])
                case .ready(let file):
                    let seen = Set(file.calendar.seen)
                    if file.calendar.seeded {
                        return .increment(seen: seen)
                    }
                    return .flagOnly(seen: seen)
                }
            }
        } catch {
            sourceIntakeLog.error("intake calendar gate skipped")
            return .flagOnly(seen: [])
        }
    }

    func calendarLedger() -> SourceIntakeCalendarLedger? {
        guard case .ready(let file) = self.loadFile() else { return nil }
        return SourceIntakeCalendarLedger(
            events: file.calendar.events,
            seeded: file.calendar.seeded,
            seen: file.calendar.seen,
            last: file.calendar.last.flatMap(self.parseStamp)
        )
    }

    func calendarSeen() -> Set<String>? {
        guard let ledger = self.calendarLedger(), ledger.seeded else { return nil }
        return Set(ledger.seen)
    }

    @discardableResult
    func seedCalendar(history: [String], pending: [String], now: Date) -> SourceIntakeResult {
        self.mutate(now: now, create: true) { file in
            guard !file.calendar.seeded else { return false }
            let pendingSet = Set(pending)
            let fresh = pendingSet.subtracting(file.calendar.seen).subtracting(Set(history))
            if file.calendar.events > 0 {
                file.calendar.events += fresh.count
            } else {
                file.calendar.events = fresh.count
            }
            if !fresh.isEmpty {
                file.calendar.last = self.stamp(now)
            }
            var seen = Set(file.calendar.seen)
            seen.formUnion(history)
            seen.formUnion(pendingSet)
            file.calendar.seen = seen.sorted()
            file.calendar.seeded = true
            return true
        }
    }

    @discardableResult
    func recordCalendarNew(keys: [String], now: Date) -> SourceIntakeResult {
        do {
            return try self.withLock {
                switch self.loadFile() {
                case .absent, .unreadable:
                    return .flagOnly
                case .ready(var file):
                    guard file.calendar.seeded else { return .flagOnly }
                    let fresh = Set(keys).subtracting(file.calendar.seen)
                    guard !fresh.isEmpty else { return .unchanged }
                    if self.consumeReplaceFailure() { return .failed }
                    file.calendar.events += fresh.count
                    file.calendar.seen.append(contentsOf: fresh.sorted())
                    file.calendar.last = self.stamp(now)
                    try self.write(file)
                    return .recorded
                }
            }
        } catch SourceIntakeError.lockTimeout {
            sourceIntakeLog.error("intake calendar increment skipped result=lock")
            return .lockTimeout
        } catch {
            sourceIntakeLog.error("intake calendar increment skipped result=write")
            return .failed
        }
    }

    private nonisolated enum CursorTime {
        case none
        case time(Date)
        case broken
    }

    private func foldLocation(_ readings: [SourceIntakeReading], into lane: inout LocationLane) -> Bool {
        let initial: Date?
        switch self.cursorTime(lane.cursor) {
        case .broken:
            return false
        case .none:
            initial = nil
        case .time(let time):
            initial = time
        }
        let ordered = readings.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.isFix && !rhs.isFix
        }
        var cursor = lane.cursor
        var acceptedTime = initial
        var added = 0
        var newest: Date?
        for reading in ordered {
            if let acceptedTime, reading.time <= acceptedTime { continue }
            guard Self.accepts(reading) else { continue }
            if let cursor {
                let distance = Self.haversineMetres(
                    lat1: cursor.lat, lon1: cursor.lon, lat2: reading.latitude, lon2: reading.longitude
                )
                if distance > cursor.hAcc && distance > reading.horizontalAccuracy {
                    added += Int(distance.rounded(.down))
                }
            }
            cursor = Cursor(t: self.stamp(reading.time), lat: reading.latitude, lon: reading.longitude, hAcc: reading.horizontalAccuracy)
            acceptedTime = reading.time
            newest = reading.time
        }
        lane.metres += added
        lane.cursor = cursor
        if let newest {
            lane.last = self.stamp(newest)
        }
        return true
    }

    private func cursorTime(_ cursor: Cursor?) -> CursorTime {
        guard let cursor else { return .none }
        guard let time = self.parseStamp(cursor.t) else { return .broken }
        return .time(time)
    }

    private func foldSafari(_ visits: [SourceIntakeSafariVisit], now: Date, into file: inout File) -> Bool {
        var added = 0
        for visit in visits {
            if file.safari.tabs[visit.instance]?[visit.tab] == visit.url { continue }
            file.safari.tabs[visit.instance, default: [:]][visit.tab] = visit.url
            added += 1
        }
        guard added > 0 else { return false }
        file.safari.pages += added
        file.safari.last = self.stamp(now)
        return true
    }

    private static func accepts(_ reading: SourceIntakeReading) -> Bool {
        reading.latitude.isFinite && reading.longitude.isFinite && reading.horizontalAccuracy.isFinite
            && (-90...90).contains(reading.latitude)
            && (-180...180).contains(reading.longitude)
            && reading.horizontalAccuracy >= 0
    }

    static func haversineMetres(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radius = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = (lat2 - lat1) * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return radius * c
    }

    private func mutate(now: Date, create: Bool, _ body: (inout File) -> Bool) -> SourceIntakeResult {
        do {
            return try self.withLock {
                switch self.loadFile() {
                case .unreadable:
                    sourceIntakeLog.error("intake count skipped result=unreadable")
                    return .skipped
                case .absent:
                    guard create else { return .flagOnly }
                    var file = File.empty(started: self.localDay(now))
                    guard body(&file) else { return .unchanged }
                    if self.consumeReplaceFailure() { return .failed }
                    try self.write(file)
                    return .recorded
                case .ready(var file):
                    guard body(&file) else { return .unchanged }
                    if self.consumeReplaceFailure() { return .failed }
                    try self.write(file)
                    return .recorded
                }
            }
        } catch SourceIntakeError.lockTimeout {
            sourceIntakeLog.error("intake count skipped result=lock")
            return .lockTimeout
        } catch {
            sourceIntakeLog.error("intake count skipped result=write")
            return .failed
        }
    }

    private func consumeReplaceFailure() -> Bool {
        guard self.testFailNextReplace else { return false }
        self.testFailNextReplace = false
        return true
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        if self.testLockTimeout {
            self.testLockTimeout = false
            throw SourceIntakeError.lockTimeout
        }
        try self.ensureDirectory()
        let fd = Darwin.open(self.lockFileURL.path, Darwin.O_RDWR | Darwin.O_CREAT, 0o644)
        guard fd >= 0 else { throw SourceIntakeError.lockTimeout }
        defer { Darwin.close(fd) }
        let deadline = Date().addingTimeInterval(2)
        while sourceIntakeFlock(fd, Darwin.LOCK_EX | Darwin.LOCK_NB) != 0 {
            if Date() >= deadline {
                throw SourceIntakeError.lockTimeout
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { _ = sourceIntakeFlock(fd, Darwin.LOCK_UN) }
        return try body()
    }

    private func ensureDirectory() throws {
        try self.fileManager.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var directory = self.directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let lock = self.lockFileURL
        if !self.fileManager.fileExists(atPath: lock.path) {
            guard self.fileManager.createFile(atPath: lock.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var lockURL = lock
        try lockURL.setResourceValues(values)
    }

    private func write(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var file = file
        file.sortSeen()
        let data = try encoder.encode(file)
        let temp = self.directoryURL.appendingPathComponent(".intake-write-\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            if self.fileManager.fileExists(atPath: self.intakeFileURL.path) {
                _ = try self.fileManager.replaceItemAt(self.intakeFileURL, withItemAt: temp)
            } else {
                try self.fileManager.moveItem(at: temp, to: self.intakeFileURL)
            }
        } catch {
            try? self.fileManager.removeItem(at: temp)
            throw error
        }
        try? self.fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: self.intakeFileURL.path
        )
        var written = self.intakeFileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try written.setResourceValues(values)
    }

    private nonisolated enum Loaded {
        case absent
        case unreadable
        case ready(File)
    }

    private func loadFile() -> Loaded {
        let url = self.intakeFileURL
        guard self.fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .unreadable }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return .unreadable }
        guard self.stampsReadable(file) else { return .unreadable }
        return .ready(file)
    }

    /// A present stamp that is not a time makes the whole file unreadable. The bytes stay as they are.
    private func stampsReadable(_ file: File) -> Bool {
        let stamps = [
            file.audio.last, file.screen.last, file.location.last, file.calendar.last,
            file.safari.last, file.watch.last, file.imports.last, file.obsidian?.last, file.location.cursor?.t,
        ]
        for stamp in stamps {
            if let stamp, self.parseStamp(stamp) == nil { return false }
        }
        return true
    }

    private func localDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func parseStamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

nonisolated private extension SourceIntakeStore {
    nonisolated struct File: Codable {
        var version: Int
        var started: String
        var audio: DurationLane
        var screen: DurationLane
        var location: LocationLane
        var calendar: CalendarLane
        var safari: SafariLane
        var watch: DurationLane
        var imports: CountLane
        var obsidian: ObsidianLane?

        nonisolated enum CodingKeys: String, CodingKey {
            case version
            case started
            case audio
            case screen
            case location
            case calendar
            case safari
            case watch
            case imports = "import"
            case obsidian
        }

        init(
            version: Int,
            started: String,
            audio: DurationLane,
            screen: DurationLane,
            location: LocationLane,
            calendar: CalendarLane,
            safari: SafariLane,
            watch: DurationLane,
            imports: CountLane,
            obsidian: ObsidianLane? = nil
        ) {
            self.version = version
            self.started = started
            self.audio = audio
            self.screen = screen
            self.location = location
            self.calendar = calendar
            self.safari = safari
            self.watch = watch
            self.imports = imports
            self.obsidian = obsidian
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decode(Int.self, forKey: .version)
            self.started = try container.decode(String.self, forKey: .started)
            self.audio = try container.decode(DurationLane.self, forKey: .audio)
            self.screen = try container.decode(DurationLane.self, forKey: .screen)
            self.location = try container.decode(LocationLane.self, forKey: .location)
            self.calendar = try container.decode(CalendarLane.self, forKey: .calendar)
            self.safari = try container.decode(SafariLane.self, forKey: .safari)
            self.watch = try container.decode(DurationLane.self, forKey: .watch)
            self.imports = try container.decode(CountLane.self, forKey: .imports)
            self.obsidian = try container.decodeIfPresent(ObsidianLane.self, forKey: .obsidian)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.version, forKey: .version)
            try container.encode(self.started, forKey: .started)
            try container.encode(self.audio, forKey: .audio)
            try container.encode(self.screen, forKey: .screen)
            try container.encode(self.location, forKey: .location)
            try container.encode(self.calendar, forKey: .calendar)
            try container.encode(self.safari, forKey: .safari)
            try container.encode(self.watch, forKey: .watch)
            try container.encode(self.imports, forKey: .imports)
            if let obsidian {
                try container.encode(obsidian, forKey: .obsidian)
            }
        }

        static func empty(started: String) -> File {
            File(
                version: 1,
                started: started,
                audio: DurationLane(),
                screen: DurationLane(),
                location: LocationLane(),
                calendar: CalendarLane(),
                safari: SafariLane(),
                watch: DurationLane(),
                imports: CountLane(),
                obsidian: nil
            )
        }

        mutating func sortSeen() {
            self.audio.seen.sort()
            self.screen.seen.sort()
            self.location.seen.sort()
            self.calendar.seen.sort()
            self.watch.seen.sort()
            self.imports.seen.sort()
            self.obsidian?.seen.sort()
            self.obsidian?.seededVaults.sort()
        }

        func lane(_ source: SourceIntakeDurationSource) -> DurationLane {
            switch source {
            case .audio: self.audio
            case .screen: self.screen
            }
        }

        mutating func setLane(_ source: SourceIntakeDurationSource, _ lane: DurationLane) {
            switch source {
            case .audio: self.audio = lane
            case .screen: self.screen = lane
            }
        }

        func snapshot(parse: (String) -> Date?) -> SourceIntakeSnapshot {
            SourceIntakeSnapshot(
                started: self.started,
                audio: self.audio.lane(parse: parse),
                screen: self.screen.lane(parse: parse),
                location: self.location.lane(parse: parse),
                calendar: SourceIntakeLane(total: self.calendar.events, last: self.calendar.last.flatMap(parse)),
                safari: SourceIntakeLane(total: self.safari.pages, last: self.safari.last.flatMap(parse)),
                watch: self.watch.lane(parse: parse),
                obsidian: SourceIntakeLane(total: self.obsidian?.notes ?? 0, last: self.obsidian?.last.flatMap(parse)),
                imports: SourceIntakeLane(total: self.imports.items, last: self.imports.last.flatMap(parse))
            )
        }
    }

    nonisolated struct DurationLane: Codable {
        var seconds: Int = 0
        var last: String?
        var seen: [String] = []

        func lane(parse: (String) -> Date?) -> SourceIntakeLane {
            SourceIntakeLane(total: self.seconds, last: self.last.flatMap(parse))
        }
    }

    nonisolated struct LocationLane: Codable {
        var metres: Int = 0
        var last: String?
        var seen: [String] = []
        var cursor: Cursor?

        func lane(parse: (String) -> Date?) -> SourceIntakeLane {
            SourceIntakeLane(total: self.metres, last: self.last.flatMap(parse))
        }
    }

    nonisolated struct Cursor: Codable {
        var t: String
        var lat: Double
        var lon: Double
        var hAcc: Double
    }

    nonisolated struct CalendarLane: Codable {
        var events: Int = 0
        var last: String?
        var seen: [String] = []
        var seeded: Bool = false
    }

    nonisolated struct SafariLane: Codable {
        var pages: Int = 0
        var last: String?
        var tabs: [String: [String: String]] = [:]
    }

    nonisolated struct CountLane: Codable {
        var items: Int = 0
        var last: String?
        var seen: [String] = []
    }

    nonisolated struct ObsidianLane: Codable {
        var notes: Int = 0
        var last: String?
        var seen: [String] = []
        var seededVaults: [String] = []
        var appliedSequences: [String: UInt64]? = nil

        enum CodingKeys: String, CodingKey {
            case notes
            case last
            case seen
            case seededVaults = "seeded_vaults"
            case appliedSequences = "applied_sequences"
        }
    }
}
