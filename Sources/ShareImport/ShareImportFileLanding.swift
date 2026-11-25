// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated protocol ShareFileSink: Sendable {
    func consume(sourceURL: URL, isInPlace: Bool) throws -> ShareFileDelivery
}

nonisolated struct ShareFileDelivery: Sendable {
    var byteCount: Int64
    var itemTime: Date
    var basis: String
    var contentType: String
    var filename: String?
    /// RFC 3339 (with offset when present in EXIF) or civil capture timestamp read from image EXIF.
    /// Always `nil` when the image carries no capture timestamp — never fabricated from share time.
    var capturedAt: String? = nil
}

nonisolated struct ShareImportEnqueueHandle: Sendable {
    var itemID: UUID
    var itemIDString: String
    var stagingDirectoryURL: URL
    var stagingRawURL: URL
}

nonisolated enum ShareImportLandingOperation: Sendable {
    case copy
    case transcodeHEICToJPEG
}

nonisolated enum ShareImportNoRoom {
    static func matches(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOSPC {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(POSIXError.ENOSPC.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return self.matches(underlying)
        }
        return false
    }
}

nonisolated struct ShareImportFileSink: ShareFileSink {
    /// Matches the journal's `MAX_SAVE_FILE_BYTES` (4 GiB).
    static let maxFileBytes: Int64 = 4 * 1024 * 1024 * 1024

    let stagingRawURL: URL
    let volumeURL: URL
    let payloadIO: any ShareImportPayloadIO
    let operation: ShareImportLandingOperation
    let inboundContentType: String
    let suggestedFilename: String?
    let now: @Sendable () -> Date

    func consume(sourceURL: URL, isInPlace: Bool) throws -> ShareFileDelivery {
        try self.checkReadable(sourceURL)
        let sourceSize = try self.payloadIO.byteCount(at: sourceURL)
        guard sourceSize <= Self.maxFileBytes else {
            throw ShareImportStoreError.tooLarge
        }
        try self.reserve(sourceSize: sourceSize, isInPlace: isInPlace)

        do {
            switch self.operation {
            case .copy:
                try self.payloadIO.copyItem(at: sourceURL, to: self.stagingRawURL)
                let stagedSize = try self.payloadIO.byteCount(at: self.stagingRawURL)
                guard stagedSize == sourceSize else {
                    throw ShareImportStoreError.writeFailed(path: self.stagingRawURL.path)
                }
                return try self.delivery(
                    byteCount: stagedSize,
                    contentType: self.inboundContentType,
                    filename: self.suggestedFilename ?? sourceURL.lastPathComponent,
                    sourceURL: sourceURL
                )
            case .transcodeHEICToJPEG:
                try self.transcodeHEICToJPEG(from: sourceURL)
                let stagedSize = try self.payloadIO.byteCount(at: self.stagingRawURL)
                guard stagedSize > 0 else {
                    throw ShareImportStoreError.undecodable
                }
                guard stagedSize <= Self.maxFileBytes else {
                    throw ShareImportStoreError.tooLarge
                }
                return try self.delivery(
                    byteCount: stagedSize,
                    contentType: UTType.jpeg.identifier,
                    filename: Self.jpegFilename(for: self.suggestedFilename ?? sourceURL.lastPathComponent),
                    sourceURL: sourceURL
                )
            }
        } catch {
            if ShareImportNoRoom.matches(error) {
                throw ShareImportStoreError.noRoom
            }
            throw error
        }
    }

    private func reserve(sourceSize: Int64, isInPlace: Bool) throws {
        // When the system already materialized a temp, both the temp and the durable copy are resident; ×2 is conservative for the owner.
        let required = sourceSize * (isInPlace ? 1 : 2)
        let capacity: Int64?
        do {
            capacity = try self.payloadIO.importantUsageCapacity(at: self.volumeURL)
        } catch {
            throw ShareImportStoreError.noRoom
        }
        guard let capacity, capacity >= required else {
            throw ShareImportStoreError.noRoom
        }
    }

    private func checkReadable(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ShareImportStoreError.unreadable
        }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
        } catch {
            throw ShareImportStoreError.protected
        }
    }

    private func delivery(
        byteCount: Int64,
        contentType: String,
        filename: String?,
        sourceURL: URL
    ) throws -> ShareFileDelivery {
        let dates = try self.payloadIO.itemDates(at: sourceURL)
        let isImage = UTType(contentType)?.conforms(to: .image) == true
            || self.operation == .transcodeHEICToJPEG
        let capture = isImage ? Self.extractPhotoCapture(from: sourceURL) : nil
        return ShareFileDelivery(
            byteCount: byteCount,
            itemTime: capture?.date ?? dates.created ?? dates.modified ?? self.now(),
            basis: "file",
            contentType: contentType,
            filename: filename,
            capturedAt: capture?.capturedAt
        )
    }

    private func transcodeHEICToJPEG(from sourceURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ShareImportStoreError.undecodable
        }
        guard let destination = CGImageDestinationCreateWithURL(
            self.stagingRawURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ShareImportStoreError.undecodable
        }
        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImageFromSource(destination, source, primaryIndex, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ShareImportStoreError.undecodable
        }
    }

    /// Reads EXIF capture date (`DateTimeOriginal` + `OffsetTimeOriginal`, falling back to
    /// `DateTimeDigitized` + `OffsetTimeDigitized`) from the image's primary frame.
    /// Returns `nil` when no valid capture date exists in EXIF.
    nonisolated static func extractPhotoCapture(from sourceURL: URL) -> (capturedAt: String, date: Date?)? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else {
            return nil
        }
        let dateOrig = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let offsetOrig = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateDigit = (exif[kCGImagePropertyExifDateTimeDigitized] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let offsetDigit = (exif[kCGImagePropertyExifOffsetTimeDigitized] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let dateOrig, let parsed = Self.formatExifCapture(
            dateString: dateOrig,
            offsetString: offsetOrig ?? (dateDigit == dateOrig ? offsetDigit : nil)
        ) {
            return parsed
        }
        if let dateDigit, let parsed = Self.formatExifCapture(dateString: dateDigit, offsetString: offsetDigit) {
            return parsed
        }
        return nil
    }

    nonisolated private static func formatExifCapture(
        dateString: String,
        offsetString: String?
    ) -> (capturedAt: String, date: Date?)? {
        guard dateString.count == 19 else { return nil }
        let chars = Array(dateString)
        guard chars[4] == ":", chars[7] == ":", chars[10] == " ", chars[13] == ":", chars[16] == ":" else {
            return nil
        }
        let yearStr = String(chars[0..<4])
        let monthStr = String(chars[5..<7])
        let dayStr = String(chars[8..<10])
        let hourStr = String(chars[11..<13])
        let minuteStr = String(chars[14..<16])
        let secondStr = String(chars[17..<19])
        guard let year = Int(yearStr), let month = Int(monthStr), let day = Int(dayStr),
              let hour = Int(hourStr), let minute = Int(minuteStr), let second = Int(secondStr),
              year > 0, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else {
            return nil
        }
        // Reject placeholder epochs.
        if (year == 1904 || year == 1970) && month == 1 && day == 1 && hour == 0 && minute == 0 && second == 0 {
            return nil
        }
        let civil = "\(yearStr)-\(monthStr)-\(dayStr)T\(hourStr):\(minuteStr):\(secondStr)"
        guard let rawOffset = offsetString, !rawOffset.isEmpty else {
            return (civil, nil)
        }
        guard let normalizedOffset = Self.normalizeExifOffset(rawOffset) else {
            return nil
        }
        let full = civil + normalizedOffset
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let instant = formatter.date(from: full) else {
            return nil
        }
        return (full, instant)
    }

    nonisolated private static func normalizeExifOffset(_ raw: String) -> String? {
        if raw == "Z" || raw == "z" { return "+00:00" }
        guard let sign = raw.first, sign == "+" || sign == "-" else { return nil }
        let rest = String(raw.dropFirst())
        let parts = rest.split(separator: ":")
        let h: Int
        let m: Int
        if parts.count == 2, parts[0].count == 2, parts[1].count == 2,
           let hh = Int(parts[0]), let mm = Int(parts[1]) {
            h = hh; m = mm
        } else if rest.count == 4, let hh = Int(rest.prefix(2)), let mm = Int(rest.suffix(2)) {
            h = hh; m = mm
        } else {
            return nil
        }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%c%02d:%02d", sign == "+" ? 43 : 45, h, m)
    }

    nonisolated static func jpegFilename(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + ".jpg"
    }
}
