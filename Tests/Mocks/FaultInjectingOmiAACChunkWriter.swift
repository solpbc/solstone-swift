// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

nonisolated enum OmiAACChunkWriterFault: Equatable, Sendable {
    case open
    case write
    case close
    case synchronize
}

@MainActor
final class FaultInjectingOmiAACChunkWriter: OmiAACChunkWriting {
    private let base: any OmiAACChunkWriting
    private var faults: [OmiAACChunkWriterFault] = []

    init(io: any OmiLaunchCaptureIO) {
        self.base = AVFoundationOmiAACChunkWriter(io: io)
    }

    func failNext(_ fault: OmiAACChunkWriterFault) {
        self.faults.append(fault)
    }

    func open(at url: URL) throws {
        try self.throwIfNeeded(.open)
        try self.base.open(at: url)
    }

    func write(samples: ArraySlice<Int16>) throws {
        try self.throwIfNeeded(.write)
        try self.base.write(samples: samples)
    }

    func close() throws {
        let shouldFail = self.consume(.close)
        try self.base.close()
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }

    func synchronize(at url: URL) throws {
        try self.throwIfNeeded(.synchronize)
        try self.base.synchronize(at: url)
    }

    private func throwIfNeeded(_ fault: OmiAACChunkWriterFault) throws {
        if self.consume(fault) { throw CocoaError(.fileWriteUnknown) }
    }

    private func consume(_ fault: OmiAACChunkWriterFault) -> Bool {
        guard let index = self.faults.firstIndex(of: fault) else { return false }
        self.faults.remove(at: index)
        return true
    }
}
