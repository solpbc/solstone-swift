// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

final class CrashAfterFinalAudioReplaceIO: OmiLaunchCaptureIO, @unchecked Sendable {
    private let base = FoundationOmiLaunchCaptureIO()
    private var didCrash = false

    func ensureDirectory(at url: URL) throws { try base.ensureDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func fileExists(at url: URL) throws -> Bool { try base.fileExists(at: url) }
    func openOrCreateAppendFile(at url: URL) throws -> OmiLaunchCaptureFileToken { try base.openOrCreateAppendFile(at: url) }
    func openNewFileForWriting(at url: URL) throws -> OmiLaunchCaptureFileToken { try base.openNewFileForWriting(at: url) }
    func openForReading(at url: URL) throws -> OmiLaunchCaptureFileToken { try base.openForReading(at: url) }
    func append(_ bytes: Data, to file: OmiLaunchCaptureFileToken) throws { try base.append(bytes, to: file) }
    func fullSynchronize(_ file: OmiLaunchCaptureFileToken) throws { try base.fullSynchronize(file) }
    func truncate(_ file: OmiLaunchCaptureFileToken, to offset: Int) throws { try base.truncate(file, to: offset) }
    func close(_ file: OmiLaunchCaptureFileToken) throws { try base.close(file) }
    func fileSize(at url: URL) throws -> Int { try base.fileSize(at: url) }
    func read(_ file: OmiLaunchCaptureFileToken, offset: Int, count: Int) throws -> Data { try base.read(file, offset: offset, count: count) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }

    func atomicReplaceItem(at source: URL, with destination: URL) throws {
        try base.atomicReplaceItem(at: source, with: destination)
        if destination.pathExtension == "m4a", !self.didCrash {
            self.didCrash = true
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
}
