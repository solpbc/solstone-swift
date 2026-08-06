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

    func recover() -> OmiLaunchCaptureScanResult {
        guard (try? self.io.fileExists(at: self.fileURL)) == true else {
            return OmiLaunchCaptureScanResult()
        }

        let result: OmiLaunchCaptureScanResult
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
            result = OmiLaunchCaptureScanResult(
                boundaryReason: .readFailed,
                boundaryOffset: 0
            )
        }

        if result.boundaryReason != nil {
            self.emittedBoundaryDiagnosticCount += 1
            self.log.error("launch capture recovery boundary")
        }
        return result
    }
}
