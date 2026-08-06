// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

nonisolated struct OmiLaunchCaptureFileToken: Equatable, Sendable {
    let rawValue: Int32
}

nonisolated protocol OmiLaunchCaptureIO: Sendable {
    func ensureDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileExists(at url: URL) throws -> Bool
    func openOrCreateAppendFile(at url: URL) throws -> OmiLaunchCaptureFileToken
    func openNewFileForWriting(at url: URL) throws -> OmiLaunchCaptureFileToken
    func openForReading(at url: URL) throws -> OmiLaunchCaptureFileToken
    func append(_ bytes: Data, to file: OmiLaunchCaptureFileToken) throws
    func fullSynchronize(_ file: OmiLaunchCaptureFileToken) throws
    func truncate(_ file: OmiLaunchCaptureFileToken, to offset: Int) throws
    func close(_ file: OmiLaunchCaptureFileToken) throws
    func fileSize(at url: URL) throws -> Int
    func read(_ file: OmiLaunchCaptureFileToken, offset: Int, count: Int) throws -> Data
    func moveItem(at source: URL, to destination: URL) throws
    func atomicReplaceItem(at source: URL, with destination: URL) throws
    func removeItem(at url: URL) throws
}

nonisolated struct FoundationOmiLaunchCaptureIO: OmiLaunchCaptureIO {
    func ensureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func fileExists(at url: URL) throws -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func openOrCreateAppendFile(at url: URL) throws -> OmiLaunchCaptureFileToken {
        try self.ensureDirectory(at: url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return OmiLaunchCaptureFileToken(rawValue: fd)
    }

    func openNewFileForWriting(at url: URL) throws -> OmiLaunchCaptureFileToken {
        try self.ensureDirectory(at: url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return OmiLaunchCaptureFileToken(rawValue: fd)
    }

    func openForReading(at url: URL) throws -> OmiLaunchCaptureFileToken {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return OmiLaunchCaptureFileToken(rawValue: fd)
    }

    func append(_ bytes: Data, to file: OmiLaunchCaptureFileToken) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(file.rawValue, baseAddress.advanced(by: written), rawBuffer.count - written)
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += count
            }
        }
    }

    func fullSynchronize(_ file: OmiLaunchCaptureFileToken) throws {
        // F_FULLFSYNC asks APFS to flush this file's completed writes through the storage stack.
        // It is a commit barrier, not independent proof that every physical medium honors persistence.
        guard Darwin.fcntl(file.rawValue, F_FULLFSYNC) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func truncate(_ file: OmiLaunchCaptureFileToken, to offset: Int) throws {
        guard offset >= 0, Darwin.ftruncate(file.rawValue, off_t(offset)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func close(_ file: OmiLaunchCaptureFileToken) throws {
        guard Darwin.close(file.rawValue) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return size.intValue
    }

    func read(_ file: OmiLaunchCaptureFileToken, offset: Int, count: Int) throws -> Data {
        guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
        var data = Data(repeating: 0, count: count)
        let readCount = data.withUnsafeMutableBytes { rawBuffer in
            Darwin.pread(file.rawValue, rawBuffer.baseAddress, count, off_t(offset))
        }
        guard readCount >= 0 else { throw CocoaError(.fileReadUnknown) }
        data.removeSubrange(Int(readCount)..<data.count)
        return data
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try self.ensureDirectory(at: destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func atomicReplaceItem(at source: URL, with destination: URL) throws {
        guard source.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              Darwin.rename(source.path, destination.path) == 0
        else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
