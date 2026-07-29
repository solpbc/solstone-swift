// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-files")

struct IntegrationGateFileStore: Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func manifestURL() throws -> URL {
        try IntegrationGateConstants.gateDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(IntegrationGateConstants.manifestFileName, isDirectory: false)
    }

    func resultURL() throws -> URL {
        try IntegrationGateConstants.gateDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(IntegrationGateConstants.resultFileName, isDirectory: false)
    }

    func readManifestData() throws -> Data {
        try self.readFixedFile(at: self.manifestURL(), missingReason: .manifestMissing)
    }

    func readPriorResultData() throws -> Data? {
        let url = try self.resultURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try self.readFixedFile(at: url, missingReason: .manifestMissing)
    }

    func writeResult(_ result: IntegrationGateResult, encoder: JSONEncoder = JSONEncoder()) throws {
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        try self.writeResultData(data)
    }

    func writeResultData(_ data: Data) throws {
        let directory = try IntegrationGateConstants.gateDirectoryURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )

        let destination = try self.resultURL()
        try self.validateDestinationForReplace(destination)
        let temp = directory.appendingPathComponent(".result-\(UUID().uuidString).tmp", isDirectory: false)
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw IntegrationGateValidationError(.fileWriteFailed)
        }
        var shouldCloseFD = true

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else {
                    return
                }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                    guard count > 0 else {
                        throw IntegrationGateValidationError(.fileWriteFailed)
                    }
                    written += count
                }
            }
            guard Darwin.fsync(fd) == 0 else {
                throw IntegrationGateValidationError(.fileWriteFailed)
            }
            guard Darwin.close(fd) == 0 else {
                throw IntegrationGateValidationError(.fileWriteFailed)
            }
            shouldCloseFD = false
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: temp.path
            )

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            if shouldCloseFD {
                Darwin.close(fd)
            }
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private func readFixedFile(at url: URL, missingReason: IntegrationGateReasonCode) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT {
                throw IntegrationGateValidationError(missingReason)
            }
            if errno == ELOOP {
                throw IntegrationGateValidationError(.symlinkRejected)
            }
            throw IntegrationGateValidationError(.manifestUnreadable)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var statValue = stat()
        guard Darwin.fstat(fd, &statValue) == 0 else {
            throw IntegrationGateValidationError(.manifestUnreadable)
        }
        guard (statValue.st_mode & S_IFMT) == S_IFREG else {
            throw IntegrationGateValidationError(.nonRegularFile)
        }
        guard statValue.st_size <= IntegrationGateConstants.maxManifestBytes else {
            throw IntegrationGateValidationError(.manifestTooLarge)
        }
        return try handle.readToEnd() ?? Data()
    }

    private func validateDestinationForReplace(_ url: URL) throws {
        var statValue = stat()
        let result = Darwin.lstat(url.path, &statValue)
        guard result == 0 else {
            if errno == ENOENT {
                return
            }
            throw IntegrationGateValidationError(.fileWriteFailed)
        }
        guard (statValue.st_mode & S_IFMT) == S_IFREG else {
            throw IntegrationGateValidationError(.symlinkRejected)
        }
        // Simulator caveat: this sets and tests the protection attribute, but locked-device
        // data protection is not enforced on Simulator the way it is on physical hardware.
    }
}
#endif
