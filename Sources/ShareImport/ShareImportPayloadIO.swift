// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol ShareImportPayloadIO: Sendable {
    func byteCount(at url: URL) throws -> Int64
    func itemDates(at url: URL) throws -> (created: Date?, modified: Date?)
    func importantUsageCapacity(at url: URL) throws -> Int64?
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func readWholeFile(at url: URL) throws -> Data
}

nonisolated final class FoundationShareImportPayloadIO: ShareImportPayloadIO, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func byteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.int64Value
    }

    func itemDates(at url: URL) throws -> (created: Date?, modified: Date?) {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values.creationDate, values.contentModificationDate)
    }

    func importantUsageCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func readWholeFile(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
