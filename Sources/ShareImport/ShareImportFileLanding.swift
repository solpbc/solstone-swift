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
        return ShareFileDelivery(
            byteCount: byteCount,
            itemTime: dates.created ?? dates.modified ?? self.now(),
            basis: "file",
            contentType: contentType,
            filename: filename
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
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ShareImportStoreError.undecodable
        }
    }

    nonisolated static func jpegFilename(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + ".jpg"
    }
}
