// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import ImageIO

/// How far back the owner chose. The instants match the calendar source.
nonisolated enum ScreenshotsSpan: String, Codable, CaseIterable, Equatable, Sendable {
    case last30Days
    case last6Months
    case lastYear
    case everything
    case fromToday

    var calendar: CalendarSpanChoice {
        switch self {
        case .last30Days: .last30Days
        case .last6Months: .last6Months
        case .lastYear: .lastYear
        case .everything: .everything
        case .fromToday: .fromToday
        }
    }

    func start(now: Date, timeZone: TimeZone) -> Date {
        self.calendar.start(now: now, timeZone: timeZone)
    }
}

/// What Photos said about access. Full is the only grant this source uses.
nonisolated enum ScreenshotsAccess: String, Codable, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case limited
    case full
}

nonisolated enum ScreenshotsPhase: String, Codable, Equatable, Sendable {
    case pending
    case queued
    case delivered
    case deleted
    case refusedType
    case tooBig
    case unreadable
    case journalRefused

    var isTerminal: Bool {
        switch self {
        case .delivered, .deleted, .refusedType, .tooBig, .unreadable, .journalRefused: true
        case .pending, .queued: false
        }
    }
}

nonisolated struct ScreenshotsPauseWindow: Codable, Equatable, Sendable {
    var start: Date
    var end: Date?
}

nonisolated struct ScreenshotsPlacement: Equatable, Sendable {
    var capturedAt: String
    var day: String
    var segment: String
    var offsetSeconds: Int
}

nonisolated enum ScreenshotsFileKind: Equatable, Sendable {
    case accepted(ext: String, contentType: String)
    case refused
}

/// Placement, type, identity and the rules that decide what comes in.
nonisolated enum ScreenshotsWire {
    static let sourceKey = "screenshots"
    static let capability = "screenshots"
    static let filenameStem = "screenshot_screen"
    static let maxBytes = 64 * 1024 * 1024
    static let maxPixels: Int64 = 100_000_000
    static let copyWindow = 3
    static let exportAttempts = 3

    static func placement(of date: Date, timeZone: TimeZone) -> ScreenshotsPlacement {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = parts.second ?? 0
        let offset = timeZone.secondsFromGMT(for: date)
        let capturedAt: String
        if offset == 0 {
            capturedAt = String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
        } else {
            let sign = offset < 0 ? "-" : "+"
            let absolute = abs(offset)
            capturedAt = String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                year, month, day, hour, minute, second, sign, absolute / 3600, (absolute % 3600) / 60
            )
        }
        return ScreenshotsPlacement(
            capturedAt: capturedAt,
            day: String(format: "%04d%02d%02d", year, month, day),
            segment: String(format: "%02d%02d%02d_1", hour, minute, second),
            offsetSeconds: offset
        )
    }

    static func kind(uniformTypeIdentifier: String) -> ScreenshotsFileKind {
        switch uniformTypeIdentifier.lowercased() {
        case "public.png":
            return .accepted(ext: "png", contentType: "image/png")
        case "public.jpeg", "public.jpg":
            return .accepted(ext: "jpg", contentType: "image/jpeg")
        case "public.webp", "org.webmproject.webp":
            return .accepted(ext: "webp", contentType: "image/webp")
        default:
            return .refused
        }
    }

    static func filename(ext: String) -> String {
        "\(self.filenameStem).\(ext)"
    }

    /// Bytes the journal receives. A png, jpg or webp goes unchanged. Any other image
    /// is written as PNG, and ImageIO carries the source metadata across with it.
    static func uploadBytes(data: Data, uniformTypeIdentifier: String) -> (data: Data, ext: String, contentType: String)? {
        if case .accepted(let ext, let contentType) = self.kind(uniformTypeIdentifier: uniformTypeIdentifier) {
            return (data, ext, contentType)
        }
        if let sniffed = self.containerType(of: data),
           case .accepted(let ext, let contentType) = self.kind(uniformTypeIdentifier: sniffed) {
            return (data, ext, contentType)
        }
        guard let png = self.pngKeepingMetadata(data) else { return nil }
        return (png, "png", "image/png")
    }

    static func containerType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source)
        else { return nil }
        return type as String
    }

    /// One PNG whose metadata is the source image's, not a rebuilt bare bitmap.
    static func pngKeepingMetadata(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let png = encoded as Data
        guard png.count >= 8, self.pixels(in: png) != nil else { return nil }
        return png
    }

    static func exceedsLimits(byteCount: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
        if byteCount > self.maxBytes { return true }
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        return Int64(pixelWidth) * Int64(pixelHeight) > self.maxPixels
    }

    static func pixels(in data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same bytes always name the same transfer item.
    static func itemID(forHash hex: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var index = hex.startIndex
        for slot in 0..<16 {
            guard hex.distance(from: index, to: hex.endIndex) >= 2 else { break }
            let next = hex.index(index, offsetBy: 2)
            bytes[slot] = UInt8(hex[index..<next], radix: 16) ?? 0
            index = next
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func isScreenshot(mediaSubtypeRaw: UInt, screenshotRaw: UInt) -> Bool {
        screenshotRaw != 0 && mediaSubtypeRaw & screenshotRaw != 0
    }

    /// A screenshot taken inside a pause window. An open window runs until it is closed.
    /// The instant the window closes is not inside it.
    static func takenWhilePaused(created: Date, windows: [ScreenshotsPauseWindow]) -> Bool {
        windows.contains { window in
            created >= window.start && (window.end.map { created < $0 } ?? true)
        }
    }
}

/// What the tile and the page say, from the source's facts. No state word is invented here.
nonisolated struct ScreenshotsViewInput: Equatable, Sendable {
    var everOn: Bool
    var enabled: Bool
    var paused: Bool
    var needsSpan: Bool
    var access: ScreenshotsAccess
    var fullAccessWasHeld: Bool
    var paired: Bool
    var capabilityNotListed: Bool
    var backfillOpen: Bool
    var progressDone: Int
    var progressTotal: Int
}

nonisolated struct ScreenshotsViewState: Equatable, Sendable {
    var sourceState: SourceState
    var activeSubtext: String
    var subtextOverride: String?
    var showsSubtext: Bool
    var pageReason: String?
    var opensSettings: Bool
    var showChooser: Bool
    var showTurnOn: Bool
    var showOnControls: Bool
    var showS17: Bool
    var showS21: Bool
    var showProgress: Bool
    /// The page's switch is the owner's wish, so it can always turn the source off, including
    /// while it asks how far back again or needs access.
    var switchOn: Bool = false
    /// The source's own line under the page's verdict, as on its tile: S11 while it asks how
    /// far back, S16 while paused.
    var pageSubline: String? = nil
}

nonisolated enum ScreenshotsPresentation {
    static func viewState(_ input: ScreenshotsViewInput) -> ScreenshotsViewState {
        var state = self.baseViewState(input)
        state.switchOn = input.enabled
        switch state.sourceState {
        case .readyToSetUp where state.showChooser, .paused:
            state.pageSubline = state.subtextOverride
        case .active, .off, .enrolling, .readyToSetUp, .checking, .needsAttention:
            state.pageSubline = nil
        }
        return state
    }

    private static func baseViewState(_ input: ScreenshotsViewInput) -> ScreenshotsViewState {
        let pairedLine = ScreenshotsVocabulary.activeSubtext(isJournalPaired: input.paired)
        // A fault needs a wish: a source the owner turned off says off, whatever Photos allows.
        if input.everOn && input.enabled && input.access != .full && input.fullAccessWasHeld {
            switch input.access {
            case .limited:
                return self.make(
                    .needsAttention, pairedLine,
                    override: ScreenshotsVocabulary.limitedTile,
                    pageReason: ScreenshotsVocabulary.limitedPage,
                    opensSettings: true
                )
            case .restricted:
                return self.make(
                    .needsAttention, pairedLine,
                    override: ScreenshotsVocabulary.restricted,
                    pageReason: ScreenshotsVocabulary.restricted
                )
            case .denied, .notDetermined, .full:
                return self.make(
                    .needsAttention, pairedLine,
                    override: ScreenshotsVocabulary.accessOffTile,
                    pageReason: ScreenshotsVocabulary.accessOffPage,
                    opensSettings: true
                )
            }
        }
        if input.everOn && !input.enabled && !input.needsSpan {
            return self.make(
                .off, pairedLine,
                override: SourceVocabulary.offSubtext(isJournalPaired: input.paired),
                showsSubtext: true
            )
        }
        if input.needsSpan || (input.access == .full && (!input.everOn || input.needsSpan)) {
            return self.make(
                .readyToSetUp, pairedLine,
                override: ScreenshotsVocabulary.readyToSetUpSubline,
                showsSubtext: true,
                showChooser: true,
                showS17: input.everOn
            )
        }
        if !input.everOn {
            let reason: String?
            let settings: Bool
            let turnOn: Bool
            switch input.access {
            case .notDetermined, .full:
                reason = nil
                settings = false
                turnOn = true
            case .limited:
                reason = ScreenshotsVocabulary.limitedAtPrompt
                settings = true
                turnOn = false
            case .denied:
                reason = ScreenshotsVocabulary.declined
                settings = true
                turnOn = false
            case .restricted:
                reason = ScreenshotsVocabulary.restricted
                settings = false
                turnOn = false
            }
            return self.make(
                .readyToSetUp, pairedLine,
                showsSubtext: false,
                pageReason: reason,
                opensSettings: settings,
                showTurnOn: turnOn
            )
        }
        if input.paused {
            return self.make(
                .paused, pairedLine,
                override: ScreenshotsVocabulary.pausedSubtext,
                showsSubtext: true,
                showOnControls: true
            )
        }
        let bringingIn = input.backfillOpen && input.progressTotal > 0 && input.progressDone < input.progressTotal
        return self.make(
            .active, pairedLine,
            override: bringingIn ? ScreenshotsVocabulary.progress(done: input.progressDone, total: input.progressTotal, onPage: false) : nil,
            showsSubtext: true,
            showOnControls: true,
            showS21: input.capabilityNotListed,
            showProgress: bringingIn
        )
    }

    private static func make(
        _ state: SourceState,
        _ active: String,
        override: String? = nil,
        showsSubtext: Bool = true,
        pageReason: String? = nil,
        opensSettings: Bool = false,
        showChooser: Bool = false,
        showTurnOn: Bool = false,
        showOnControls: Bool = false,
        showS17: Bool = false,
        showS21: Bool = false,
        showProgress: Bool = false
    ) -> ScreenshotsViewState {
        ScreenshotsViewState(
            sourceState: state,
            activeSubtext: active,
            subtextOverride: override,
            showsSubtext: showsSubtext,
            pageReason: pageReason,
            opensSettings: opensSettings,
            showChooser: showChooser,
            showTurnOn: showTurnOn,
            showOnControls: showOnControls,
            showS17: showS17,
            showS21: showS21,
            showProgress: showProgress
        )
    }
}
