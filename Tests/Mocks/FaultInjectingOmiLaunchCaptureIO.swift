// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

nonisolated enum OmiLaunchCaptureInjectedOperation: Equatable, Sendable {
    case open
    case write
    case barrier
    case move
}

nonisolated final class FaultInjectingOmiLaunchCaptureIO: OmiLaunchCaptureIO, @unchecked Sendable {
    private let base = FoundationOmiLaunchCaptureIO()
    private let lock = NSLock()
    private var failingOperations: [OmiLaunchCaptureInjectedOperation] = []
    private var writeCallCount = 0
    private var failingWriteCall: Int?
    private var failingWriteAfterBytes: Int?
    private var barrierCallCount = 0
    private var failingBarrierCall: Int?
    private var tokenURLs: [Int32: URL] = [:]
    private var synchronizedPrefixes: [URL: Data] = [:]
    private var largestReadRequest = 0
    private var ioCallCount = 0

    var largestSingleReadCount: Int {
        self.lock.withLock { self.largestReadRequest }
    }

    var performedIOCallCount: Int {
        self.lock.withLock { self.ioCallCount }
    }

    func failNext(_ operation: OmiLaunchCaptureInjectedOperation) {
        self.lock.withLock { self.failingOperations.append(operation) }
    }

    func failWrite(onCall call: Int, afterBytes: Int) {
        self.lock.withLock {
            self.writeCallCount = 0
            self.failingWriteCall = call
            self.failingWriteAfterBytes = afterBytes
        }
    }

    func failBarrier(onCall call: Int) {
        self.lock.withLock {
            self.barrierCallCount = 0
            self.failingBarrierCall = call
        }
    }

    func clearFaults() {
        self.lock.withLock {
            self.failingOperations.removeAll()
            self.failingWriteCall = nil
            self.failingWriteAfterBytes = nil
            self.failingBarrierCall = nil
        }
    }

    func restoreLastSynchronizedPrefix(at url: URL) throws {
        let prefix = self.lock.withLock { self.synchronizedPrefixes[url] ?? Data() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prefix.write(to: url)
    }

    func ensureDirectory(at url: URL) throws {
        self.recordIOCall()
        try self.base.ensureDirectory(at: url)
    }

    func openOrCreateAppendFile(at url: URL) throws -> OmiLaunchCaptureFileToken {
        self.recordIOCall()
        try self.throwIfNeeded(.open)
        let token = try self.base.openOrCreateAppendFile(at: url)
        self.lock.withLock { self.tokenURLs[token.rawValue] = url }
        return token
    }

    func openForReading(at url: URL) throws -> OmiLaunchCaptureFileToken {
        self.recordIOCall()
        let token = try self.base.openForReading(at: url)
        self.lock.withLock { self.tokenURLs[token.rawValue] = url }
        return token
    }

    func append(_ bytes: Data, to file: OmiLaunchCaptureFileToken) throws {
        let budget = self.lock.withLock { () -> Int? in
            self.ioCallCount += 1
            self.writeCallCount += 1
            if self.consumeFailure(.write) { return 0 }
            guard self.failingWriteCall == self.writeCallCount else { return nil }
            self.failingWriteCall = nil
            defer { self.failingWriteAfterBytes = nil }
            return self.failingWriteAfterBytes
        }
        if let budget {
            let allowed = min(budget, bytes.count)
            if allowed > 0 {
                try self.base.append(Data(bytes.prefix(allowed)), to: file)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        try self.base.append(bytes, to: file)
    }

    func fullSynchronize(_ file: OmiLaunchCaptureFileToken) throws {
        self.recordIOCall()
        let shouldFail = self.lock.withLock { () -> Bool in
            self.barrierCallCount += 1
            if self.consumeFailure(.barrier) { return true }
            return self.failingBarrierCall == self.barrierCallCount
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        guard let url = self.lock.withLock({ self.tokenURLs[file.rawValue] }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bytes = try Data(contentsOf: url)
        self.lock.withLock { self.synchronizedPrefixes[url] = bytes }
    }

    func truncate(_ file: OmiLaunchCaptureFileToken, to offset: Int) throws {
        self.recordIOCall()
        try self.base.truncate(file, to: offset)
    }

    func close(_ file: OmiLaunchCaptureFileToken) throws {
        self.recordIOCall()
        _ = self.lock.withLock { self.tokenURLs.removeValue(forKey: file.rawValue) }
        try self.base.close(file)
    }

    func fileSize(at url: URL) throws -> Int {
        self.recordIOCall()
        return try self.base.fileSize(at: url)
    }

    func read(_ file: OmiLaunchCaptureFileToken, offset: Int, count: Int) throws -> Data {
        self.lock.withLock {
            self.ioCallCount += 1
            self.largestReadRequest = max(self.largestReadRequest, count)
        }
        return try self.base.read(file, offset: offset, count: count)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        self.recordIOCall()
        try self.throwIfNeeded(.move)
        try self.base.moveItem(at: source, to: destination)
    }

    private func throwIfNeeded(_ operation: OmiLaunchCaptureInjectedOperation) throws {
        let shouldFail = self.lock.withLock { self.consumeFailure(operation) }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }

    private func recordIOCall() {
        self.lock.withLock { self.ioCallCount += 1 }
    }

    private func consumeFailure(_ operation: OmiLaunchCaptureInjectedOperation) -> Bool {
        guard let index = self.failingOperations.firstIndex(where: { $0 == operation }) else { return false }
        self.failingOperations.remove(at: index)
        return true
    }
}
