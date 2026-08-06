// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

@MainActor
final class OmiLaunchCaptureRecovery {
    private let rootURL: URL
    private let generationID: UUID
    private let io: any OmiLaunchCaptureIO
    private let log = Logger(subsystem: "app.solstone.swift", category: "omi-launch-capture")
    private(set) var emittedBoundaryDiagnosticCount = 0

    init(rootURL: URL, generationID: UUID, io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()) {
        self.rootURL = rootURL
        self.generationID = generationID
        self.io = io
    }

    var fileURL: URL {
        OmiLaunchCaptureFormat.fileURL(rootURL: self.rootURL, generationID: self.generationID)
    }

    func recover() -> OmiLaunchCaptureRecoveryResult {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            return OmiLaunchCaptureRecoveryResult(verifiedRecords: [])
        }

        let result: OmiLaunchCaptureRecoveryResult
        do {
            let token = try self.io.openForReading(at: self.fileURL)
            defer { try? self.io.close(token) }
            let size = try self.io.fileSize(at: self.fileURL)
            result = OmiLaunchCaptureLogic.scan(
                generationID: self.generationID,
                fileSize: size,
                read: { offset, count in
                    try self.io.read(token, offset: offset, count: count)
                }
            )
        } catch {
            result = OmiLaunchCaptureRecoveryResult(
                verifiedRecords: [],
                boundaryReason: .readFailed,
                boundaryOffset: 0
            )
        }

        guard let reason = result.boundaryReason, let offset = result.boundaryOffset else {
            return result
        }

        let quarantineURL = self.rootURL
            .appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName, isDirectory: true)
            .appendingPathComponent(
                "\(self.fileURL.deletingPathExtension().lastPathComponent)-boundary-\(offset).\(OmiLaunchCaptureFormat.fileExtension)",
                isDirectory: false
            )
        let disposition: OmiLaunchCaptureQuarantineDisposition
        do {
            try self.io.moveItem(at: self.fileURL, to: quarantineURL)
            disposition = .moved
        } catch {
            disposition = .retainedInPlace
        }

        let sequence = result.boundarySequence.map(String.init) ?? "none"
        self.emittedBoundaryDiagnosticCount += 1
        self.log.error(
            "launch capture recovery boundary sequence=\(sequence, privacy: .public) offset=\(offset, privacy: .public) reason=\(reason.rawValue, privacy: .public) disposition=\(disposition.rawValue, privacy: .public)"
        )
        return result.withQuarantineDisposition(disposition)
    }
}
