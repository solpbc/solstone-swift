// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation

nonisolated enum FolderConstants {
    /// Maximum bytes of a file whose content is eligible for device ingest (64 MiB).
    static let maxContentBytes: UInt64 = 64 * 1024 * 1024
    /// Maximum bytes of a note eligible for edit tracking (4 MiB).
    static let maxNoteBytes: UInt64 = 4 * 1024 * 1024
    /// Default maximum pixel count for images sent to the journal.
    static let maxImagePixels: UInt64 = 67_108_864
    /// Quiet wait (1 hour) before a saved revision of an already-sent document or transcript is sent again.
    static let documentRevisionCooldownMs: Int64 = 60 * 60 * 1_000
    /// Five-minute segment window duration in milliseconds.
    static let windowMs: Int64 = 300_000
    /// Minimum age after last modification before hashing/reading a newly written file.
    static let settleMs: Int64 = 2_000
    /// Maximum companion content files per protocol-v3 folder segment upload
    /// (64 files total including the activity JSONL).
    static let maxUploadContentParts: Int = 63
    /// Maximum preview items sent to `POST /app/devices/ingest/folder/estimate`.
    static let maxEstimateItems: Int = 50_000
    /// Maximum UTF-8 bytes for a relative path in the activity JSONL.
    static let maxRelativePathBytes: Int = 1_024
    /// Wire source identifier for folder ingest.
    static let wireSource = "folder"
    /// Capability name advertised in `/api/system/status`.
    static let capability = "folder"
    /// Backoff schedule for transient delivery failures.
    static let retryMs: [Int64] = [30_000, 120_000, 600_000, 1_800_000]
}

/// Owner-chosen file kinds to bring in from a folder. All six default on.
nonisolated struct FolderKinds: Codable, Equatable, Hashable, Sendable {
    var notes: Bool = true
    var documents: Bool = true
    var transcripts: Bool = true
    var screenshots: Bool = true
    var photos: Bool = true
    var other: Bool = true

    static let allOn = FolderKinds()

    var anySelected: Bool {
        self.notes || self.documents || self.transcripts || self.screenshots || self.photos || self.other
    }

    func isEnabled(for kind: FolderFileKind) -> Bool {
        switch kind {
        case .note: self.notes
        case .document: self.documents
        case .transcript: self.transcripts
        case .screenshot: self.screenshots
        case .photo: self.photos
        case .other: self.other
        }
    }

    /// Names of enabled kinds in stable UI and wire order.
    var enabledNames: [String] {
        var out: [String] = []
        if self.notes { out.append("notes") }
        if self.documents { out.append("documents") }
        if self.transcripts { out.append("transcripts") }
        if self.screenshots { out.append("screenshots") }
        if self.photos { out.append("photos") }
        if self.other { out.append("other") }
        return out
    }
}

/// Deterministic kind assigned to a file on the device.
nonisolated enum FolderFileKind: String, Codable, Equatable, Hashable, Sendable {
    case note
    case document
    case transcript
    case screenshot
    case photo
    case other

    /// Wire `kind_hint` sent on protocol-v3 folder activity lines and estimate items.
    var kindHint: String? {
        switch self {
        case .note: "notes"
        case .document: "documents"
        case .transcript: "transcripts"
        case .screenshot: "screenshots"
        case .photo: "photos"
        case .other: nil
        }
    }
}

/// Whether a file's bytes leave the device, only its metadata goes, or it is skipped.
nonisolated enum FolderDeliveryMode: String, Codable, Equatable, Hashable, Sendable {
    case content
    case metadataOnly = "metadata_only"
    case ignore
}

/// Activity verb recorded for a file event inside a five-minute window.
nonisolated enum FolderActivityVerb: String, Codable, Equatable, Hashable, Sendable {
    case added
    case edited
    case revised
    case renamed
    case removed

    /// Canonical wire `event` string for protocol-v3 folder activity JSONL.
    var wireEvent: String {
        switch self {
        case .added: "added"
        case .edited, .revised: "changed"
        case .renamed: "renamed"
        case .removed: "removed"
        }
    }
}

/// Lifecycle mode of one configured folder.
nonisolated enum FolderMode: String, Codable, Equatable, Hashable, Sendable {
    /// Picked, not yet confirmed. Nothing leaves the device.
    case settingUp = "setting_up"
    /// Active: scans and sends five-minute segments.
    case on
    /// Paused individually: keeps tracking changes locally without skipping,
    /// and holds delivery until resumed.
    case paused
    /// Turned off: stops tracking and drops unsent queue; already-delivered journal material stays.
    case off
}

/// Fatal folder-level condition that puts a folder into `needs attention`.
nonisolated enum FolderAttention: String, Codable, Equatable, Hashable, Sendable {
    case bookmarkInvalid = "bookmark_invalid"
    case providerRefused = "provider_refused"
    case unreadable
}

/// Existing source that overlaps a candidate folder.
nonisolated enum FolderOverlapTarget: Codable, Equatable, Hashable, Sendable {
    case obsidian(name: String)
    case folder(id: String, name: String)
}

/// Outcome of validating a newly chosen folder URL before setup begins.
nonisolated enum FolderPathCheckResult: Equatable, Sendable {
    case ready(name: String, label: String, canonicalPath: String, isCloudProvider: Bool)
    case alreadyAdded(folderID: String, name: String)
    case overlaps(name: String, label: String, canonicalPath: String, isCloudProvider: Bool, target: FolderOverlapTarget)
    case refusedLocal
    case refusedProvider
}

/// One facet available on the paired journal.
nonisolated struct FolderFacet: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var title: String
    var color: String?

    var id: String { self.name }
}

/// Availability of the journal's facet list.
nonisolated enum FolderFacetsAvailability: String, Codable, Equatable, Sendable {
    case ready
    case unpaired
    case offline
}

/// How far back to bring in existing files during setup or `bring in older files`.
nonisolated enum FolderBackfillRange: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case last30Days
    case last6Months
    case lastYear
    case everything
    case fromToday

    var id: String { self.rawValue }

    func startMs(nowMs: Int64, timeZone: TimeZone) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(nowMs) / 1_000))
        let start: Date?
        switch self {
        case .last30Days: start = calendar.date(byAdding: .day, value: -30, to: today)
        case .last6Months: start = calendar.date(byAdding: .month, value: -6, to: today)
        case .lastYear: start = calendar.date(byAdding: .year, value: -1, to: today)
        case .fromToday: start = today
        case .everything: return Int64.min
        }
        return Int64((start ?? today).timeIntervalSince1970 * 1_000)
    }
}

/// Supported file-type table published by `GET /app/devices/ingest/folder/supported`,
/// with local ruleset-8 defaults used until the paired journal answers.
nonisolated struct FolderSupportedList: Codable, Equatable, Sendable {
    var noteExtensions: Set<String>
    var documentExtensions: Set<String>
    var transcriptExtensions: Set<String>
    var acceptedImageExtensions: Set<String>
    var convertibleImageExtensions: Set<String>
    var maxContentBytes: UInt64
    var maxNoteBytes: UInt64
    var maxImagePixels: UInt64
    var documentRevisionCooldownMs: Int64
    var rulesetVersion: Int
    var noteStructuredWords: Int
    var noteHeadingLevels: Int
    var noteLongWords: Int
    var fromJournal: Bool

    static let `default` = FolderSupportedList(
        noteExtensions: ["md", "markdown", "txt", "log"],
        documentExtensions: ["pdf"],
        transcriptExtensions: ["vtt", "srt"],
        acceptedImageExtensions: ["png", "jpg", "jpeg", "webp"],
        convertibleImageExtensions: ["heic", "heif", "tif", "tiff", "gif", "bmp"],
        maxContentBytes: FolderConstants.maxContentBytes,
        maxNoteBytes: FolderConstants.maxNoteBytes,
        maxImagePixels: FolderConstants.maxImagePixels,
        documentRevisionCooldownMs: FolderConstants.documentRevisionCooldownMs,
        rulesetVersion: 8,
        noteStructuredWords: 1_500,
        noteHeadingLevels: 2,
        noteLongWords: 5_000,
        fromJournal: false
    )
}

/// One item sent to `POST /app/devices/ingest/folder/estimate`.
nonisolated struct FolderEstimateItem: Codable, Equatable, Sendable {
    var path: String
    var at: String
    var fileType: String?
    var kindHint: String?
    var contentHash: String?
    var hasContent: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case at
        case fileType = "file_type"
        case kindHint = "kind_hint"
        case contentHash = "content_hash"
        case hasContent = "has_content"
    }
}

/// Non-money backfill work estimate (segments, days, thoughts).
nonisolated struct FolderBackfillEstimate: Codable, Equatable, Sendable {
    var segments: Int
    var days: Int
    var thoughts: Int
    var alreadyInJournal: Int
    var fromJournal: Bool
}

/// Preview counts and date range shown before confirmation.
nonisolated struct FolderPreviewSummary: Codable, Equatable, Sendable {
    var range: FolderBackfillRange
    var totalItems: Int = 0
    var contentItems: Int = 0
    var contentBytes: UInt64 = 0
    var metadataOnlyItems: Int = 0
    var notes: Int = 0
    var documents: Int = 0
    var transcripts: Int = 0
    var screenshots: Int = 0
    var photos: Int = 0
    var other: Int = 0
    var oldestMs: Int64? = nil
    var newestMs: Int64? = nil
    var unreadable: Int = 0
    var placeholdersSkipped: Int = 0
    var failed: Bool = false
    var estimate: FolderBackfillEstimate? = nil
}

/// Platform metadata attached to a folder activity line.
nonisolated struct FolderPlatformMetadata: Codable, Equatable, Sendable {
    var sizeBytes: UInt64 = 0
    var modifiedMs: Int64 = 0
    var createdMs: Int64? = nil
    var extensionLower: String? = nil
    var originURL: String? = nil
    var referrerURL: String? = nil
    var downloadedBy: String? = nil
    var sourceApp: String? = nil
    var whereFroms: [String]? = nil
    var quarantine: String? = nil
    var xattrs: [String: String]? = nil
}

/// Five-minute segment window aligned to the owner's local calendar.
nonisolated struct FolderWindow: Codable, Equatable, Hashable, Comparable, Sendable {
    var day: String
    var segment: String

    static func < (lhs: FolderWindow, rhs: FolderWindow) -> Bool {
        if lhs.day != rhs.day {
            return lhs.day < rhs.day
        }
        return lhs.segment < rhs.segment
    }
}

/// Timestamp paired with its local UTC offset in seconds.
nonisolated struct FolderStamp: Equatable, Sendable {
    var ms: Int64
    var offsetSeconds: Int

    var date: Date {
        Date(timeIntervalSince1970: Double(self.ms) / 1_000.0)
    }

    func rfc3339() -> String {
        Self.formatRFC3339(ms: self.ms, offsetSeconds: self.offsetSeconds)
    }

    func window() -> FolderWindow {
        let localSec = self.localSecondsFloor()
        let dayIndex = Self.floorDiv(localSec, 86_400)
        let secOfDay = Self.floorMod(localSec, 86_400)
        let alignedSec = (secOfDay / 300) * 300
        let (year, month, day) = Self.civilFromDays(dayIndex)
        let hour = alignedSec / 3_600
        let minute = (alignedSec % 3_600) / 60
        let second = alignedSec % 60
        return FolderWindow(
            day: String(format: "%04d%02d%02d", year, month, day),
            segment: String(format: "%02d%02d%02d_300", hour, minute, second)
        )
    }

    func windowEndMs() -> Int64 {
        let localSec = self.localSecondsFloor()
        let secOfDay = Self.floorMod(localSec, 86_400)
        let alignedSec = (secOfDay / 300) * 300
        let dayStartLocalSec = localSec - secOfDay
        let endLocalSec = dayStartLocalSec + alignedSec + 300
        let endUtcSec = endLocalSec - Int64(self.offsetSeconds)
        return endUtcSec * 1_000
    }

    private func localSecondsFloor() -> Int64 {
        Self.floorDiv(self.ms, 1_000) + Int64(self.offsetSeconds)
    }

    static func formatRFC3339(ms: Int64, offsetSeconds: Int) -> String {
        let utcSec = Self.floorDiv(ms, 1_000)
        let localSec = utcSec + Int64(offsetSeconds)
        let dayIndex = Self.floorDiv(localSec, 86_400)
        let secOfDay = Self.floorMod(localSec, 86_400)
        let (year, month, day) = Self.civilFromDays(dayIndex)
        let hour = secOfDay / 3_600
        let minute = (secOfDay % 3_600) / 60
        let second = secOfDay % 60
        if offsetSeconds == 0 {
            return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
        }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absOff = abs(offsetSeconds)
        let offH = absOff / 3_600
        let offM = (absOff % 3_600) / 60
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            year, month, day, hour, minute, second, sign, offH, offM
        )
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    private static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
        a - Self.floorDiv(a, b) * b
    }

    /// Howard Hinnant's civil-from-days algorithm (days since 1970-01-01).
    private static func civilFromDays(_ zInput: Int64) -> (Int, Int, Int) {
        let z = zInput + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = y + (m <= 2 ? 1 : 0)
        return (Int(year), Int(m), Int(d))
    }
}

/// Clock abstraction for deterministic five-minute windowing and cool-down tests.
nonisolated protocol FolderClock: Sendable {
    var timeZone: TimeZone { get }
    func nowMs() -> Int64
    func offsetSeconds(at ms: Int64) -> Int
}

nonisolated extension FolderClock {
    func now() -> FolderStamp {
        let ms = self.nowMs()
        return FolderStamp(ms: ms, offsetSeconds: self.offsetSeconds(at: ms))
    }

    func stamp(at ms: Int64) -> FolderStamp {
        FolderStamp(ms: ms, offsetSeconds: self.offsetSeconds(at: ms))
    }
}

nonisolated struct SystemFolderClock: FolderClock {
    var timeZone: TimeZone

    init(timeZone: TimeZone = .autoupdatingCurrent) {
        self.timeZone = timeZone
    }

    func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000.0).rounded(.towardZero))
    }

    func offsetSeconds(at ms: Int64) -> Int {
        self.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1_000.0))
    }
}

/// Stable file identity used for rename detection across safe-saves and moves.
nonisolated struct FolderFileIdentity: Codable, Equatable, Hashable, Sendable {
    var documentIdentifier: UInt64?
    var device: UInt64?
    var inode: UInt64?

    func matches(_ other: FolderFileIdentity) -> Bool {
        if let lhsDoc = self.documentIdentifier, let rhsDoc = other.documentIdentifier, lhsDoc != 0 {
            return lhsDoc == rhsDoc
        }
        if let ld = self.device, let li = self.inode,
           let rd = other.device, let ri = other.inode, li != 0 {
            return ld == rd && li == ri
        }
        return false
    }
}

/// One queued event inside a five-minute folder segment.
nonisolated struct FolderPendingEvent: Codable, Equatable, Sendable {
    var id: String
    var relPath: String
    var previousPath: String? = nil
    var verb: FolderActivityVerb
    var kind: FolderFileKind
    var delivery: FolderDeliveryMode
    var eventMs: Int64
    var observedMs: Int64
    var offsetSeconds: Int
    var window: FolderWindow
    var windowEndMs: Int64
    var metadata: FolderPlatformMetadata
    var contentHash: String? = nil
    var notePayload: String? = nil
    var fallbackDetails: Bool?
    var isRevision: Bool = false
    var backfill: Bool = false
    var retryAtMs: Int64? = nil
    var tries: Int = 0
}

/// Durable per-file record held per configured folder.
nonisolated struct FolderTrackedFile: Codable, Equatable, Sendable {
    var relPath: String
    var identity: FolderFileIdentity? = nil
    var sizeBytes: UInt64
    var mtimeMs: Int64
    var contentHash: String? = nil
    var kind: FolderFileKind
    var delivery: FolderDeliveryMode
    /// True once the journal acknowledged this file (so a later local deletion
    /// emits `removed` rather than silently dropping).
    var deliveredToJournal: Bool = false
    /// True when the file existed before `spanFromMs` and was excluded by the owner's range choice.
    var excludedBeforeSpan: Bool = false
    var lastSentHash: String? = nil
    /// Baseline note text last acknowledged for detecting reverted edits.
    var lastNoteText: String? = nil
    /// Timestamp when an already-delivered document/transcript was saved with a new hash.
    var pendingRevisionSaveMs: Int64? = nil
    var pendingRevisionHash: String? = nil
}

/// Durable record for one configured folder. Holds ZERO journal identity.
nonisolated struct FolderRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var displayLabel: String
    /// Security-scoped bookmark data obtained from the system Files picker.
    var bookmarkData: Data?
    /// Canonical filesystem path fallback for tests and overlap matching.
    var canonicalPath: String
    var isCloudProvider: Bool = false
    var mode: FolderMode = .settingUp
    var pausedBeforeSetup: Bool?
    var canDeliver: Bool { mode == .on || (mode == .settingUp && pausedBeforeSetup != true) }

    mutating func applyKindChoices() {
        let selected = kinds
        pending = pending.compactMap { event in
            if selected.isEnabled(for: event.kind) { return event }
            guard selected.other else { return nil }
            var details = event
            details.delivery = .metadataOnly
            details.contentHash = nil
            details.notePayload = nil
            return details
        }
        let remaining = pending.filter(\.backfill).count
        backfillTotal = remaining > 0 ? backfillDone + remaining : 0
        if remaining == 0 { backfillDone = 0 }
    }
    var returning: Bool = false
    var kinds: FolderKinds = .allOn
    var facet: FolderFacet? = nil
    var overlap: FolderOverlapTarget? = nil
    var spanFromMs: Int64? = nil
    var files: [String: FolderTrackedFile] = [:]
    var pending: [FolderPendingEvent] = []
    var backfillTotal: Int = 0
    var backfillDone: Int = 0
    var itemsTakenIn: Int = 0
    var lastTakenInMs: Int64? = nil
    var lastCheckedMs: Int64? = nil
    var fallbackToDetails: Int = 0
    var cantRead: Int = 0
    var attention: FolderAttention? = nil
}

/// On-disk ledger under Application Support/Folders/ledger.json. Zero journal identity.
nonisolated struct FolderLedger: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int = FolderLedger.currentVersion
    var folders: [FolderRecord] = []
}

/// One content file included in a staged five-minute segment delivery.
nonisolated struct FolderStagedContentFile: Equatable, Sendable {
    var eventID: String
    var relPath: String
    var kind: FolderFileKind
    var extensionLower: String?
    var contentHash: String?
    var notePayload: String?
    var isRevision: Bool
    var needsImageConvert: Bool
}

/// One staged five-minute segment ready to send to `POST /app/devices/ingest`.
nonisolated struct FolderSegmentDelivery: Equatable, Sendable {
    var folderID: String
    var folderName: String
    var facet: String?
    var kinds: FolderKinds
    var window: FolderWindow
    var events: [FolderPendingEvent]
    var contentFiles: [FolderStagedContentFile]
}

/// Outcome of delivering one five-minute folder segment to the journal.
nonisolated enum FolderDeliveryOutcome: Equatable, Sendable {
    /// Segment accepted (`ok`, `duplicate`, `collision`, or `segment_removed`).
    case delivered
    /// Segment accepted (`200 ok`), with specific relative paths whose content was refused.
    case deliveredWithRefusedContent([String])
    /// Every content file failed per-file validation (`400 folder_file_invalid`).
    case allFilesRefused([String])
    /// Permanent contract rejection (`400 folder_invalid`).
    case invalidPermanent
    /// Transient error, offline, capability absent, pairing changed, `503 journal_read_failed`, or `400 folder_ahead`.
    case hold
}

/// Deterministic SHA-256 hex digest helper.
nonisolated func folderSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

nonisolated func folderEventID(folderID: String, relPath: String, verb: FolderActivityVerb, eventMs: Int64) -> String {
    let raw = "\(folderID):\(relPath):\(verb.rawValue):\(eventMs)"
    return folderSHA256Hex(Data(raw.utf8))
}
