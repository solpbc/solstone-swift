// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Darwin
import Foundation
import os

nonisolated private let resumableUploadLog = Logger(subsystem: "app.solstone.swift", category: "resumable-import")

nonisolated enum ResumableImportDefaults {
    static let capabilityName = "resumable_import_uploads"
    static let statusPath = "/api/system/status"
    static let uploadsPath = ImporterServerURL.uploadsPath
    static let sourcesPath = ImporterServerURL.sourcesPath

    static let thresholdBytes: Int64 = 16 * 1024 * 1024
    static let chunkBytes: Int = 4 * 1024 * 1024
    static let minChunkBytes: Int = 64 * 1024
    static let maxChunkBytes: Int = 4 * 1024 * 1024
    static let maxFileBytes: Int64 = 4 * 1024 * 1024 * 1024

    static func clampedChunkBytes(_ raw: Int?) -> Int {
        guard let raw, raw > 0 else { return Self.chunkBytes }
        return min(max(raw, Self.minChunkBytes), Self.maxChunkBytes)
    }
}

nonisolated struct ImportChunkGrowth {
    var advertised: Int
    var fastReceipts = 0

    mutating func afterReceipt(current: Int, sent: Int, confirmed: Int, elapsed: Duration) -> Int {
        // Two full receipts must each project the advertised size inside eight seconds.
        guard current > 0, current < advertised, sent == current, confirmed == sent,
              elapsed <= .milliseconds(8_000 * current / advertised) else {
            fastReceipts = 0
            return current
        }
        fastReceipts += 1
        guard fastReceipts >= 2 else { return current }
        fastReceipts = 0
        return min(advertised, 2 * current)
    }
}

nonisolated struct ResumableImportConfig: Equatable, Sendable {
    var thresholdBytes: Int64
    var chunkBytes: Int
    var maxFileBytes: Int64

    static let `default` = ResumableImportConfig(
        thresholdBytes: ResumableImportDefaults.thresholdBytes,
        chunkBytes: ResumableImportDefaults.chunkBytes,
        maxFileBytes: ResumableImportDefaults.maxFileBytes
    )
}

nonisolated enum ResumableImportCapabilityResult: Equatable, Sendable {
    case supported(ResumableImportConfig)
    case unsupported
    case authRefused(statusCode: Int)
    case unavailable(TransferTransientReason)
}

nonisolated protocol ResumableImportCapabilityProbing: Sendable {
    func capability(
        for endpoint: TransferResolvedEndpoint,
        journalVersion: String?
    ) async -> ResumableImportCapabilityResult

    func markUnsupported(
        for endpoint: TransferResolvedEndpoint,
        journalVersion: String?
    ) async

    func invalidate() async
}

/// Probes `GET /api/system/status` for `"resumable_import_uploads"` and reads
/// `resumable.{threshold_bytes, chunk_bytes, max_file_bytes}` from `GET /app/import/api/sources`.
/// Caches per endpoint, pairing identity, and journal version. Transient probe failures are never
/// cached as `.unsupported`.
actor JournalResumableImportCapabilityProbe: ResumableImportCapabilityProbing {
    private struct CacheKey: Equatable {
        let baseURL: URL
        let pairingGeneration: UInt64?
        let credentialCID: String?
        let journalInstanceID: String?
        let journalVersion: String?
    }

    private enum CachedDecision {
        case supported(ResumableImportConfig)
        case unsupported
    }

    private let transport: TransferTransport
    private var cachedKey: CacheKey?
    private var cachedDecision: CachedDecision?

    init(transport: TransferTransport) {
        self.transport = transport
    }

    func invalidate() {
        self.cachedKey = nil
        self.cachedDecision = nil
    }

    func markUnsupported(
        for endpoint: TransferResolvedEndpoint,
        journalVersion: String?
    ) {
        self.cachedKey = Self.cacheKey(for: endpoint, journalVersion: journalVersion)
        self.cachedDecision = .unsupported
    }

    func capability(
        for endpoint: TransferResolvedEndpoint,
        journalVersion: String?
    ) async -> ResumableImportCapabilityResult {
        let key = Self.cacheKey(for: endpoint, journalVersion: journalVersion)
        if self.cachedKey == key, let cached = self.cachedDecision {
            switch cached {
            case .supported(let config):
                return .supported(config)
            case .unsupported:
                return .unsupported
            }
        }

        let statusResult = await self.transport.sendRawRequest(
            method: "GET",
            path: ResumableImportDefaults.statusPath,
            headers: ["Cache-Control": "no-cache"],
            endpoint: endpoint
        )
        if let early = Self.classifyProbeInterruption(statusResult) {
            return early
        }

        let statusCode = statusResult.statusCode ?? 0
        var advertisedByStatus = false
        if statusCode == 200 {
            guard let object = (try? JSONSerialization.jsonObject(with: statusResult.data)) as? [String: Any] else {
                return .unavailable(.transport("invalid status response"))
            }
            if let capabilities = object["capabilities"] as? [Any] {
                let names = capabilities.compactMap { $0 as? String }
                advertisedByStatus = names.contains(ResumableImportDefaults.capabilityName)
            }
            if !advertisedByStatus {
                self.cachedKey = key
                self.cachedDecision = .unsupported
                return .unsupported
            }
        } else if statusCode == 404 || statusCode == 405 {
            // Fall through to `/app/import/api/sources` check per contract.
            advertisedByStatus = false
        } else if 400..<500 ~= statusCode {
            self.cachedKey = key
            self.cachedDecision = .unsupported
            return .unsupported
        } else {
            return .unavailable(.httpServerError(statusCode: statusCode))
        }

        let sourcesResult = await self.transport.sendRawRequest(
            method: "GET",
            path: ResumableImportDefaults.sourcesPath,
            headers: ["Cache-Control": "no-cache"],
            endpoint: endpoint
        )
        if let early = Self.classifyProbeInterruption(sourcesResult) {
            return early
        }

        let sourcesCode = sourcesResult.statusCode ?? 0
        if sourcesCode == 200 {
            if let parsed = Self.parseSourcesResumableConfig(from: sourcesResult.data) {
                self.cachedKey = key
                self.cachedDecision = .supported(parsed)
                return .supported(parsed)
            }
            if advertisedByStatus {
                self.cachedKey = key
                self.cachedDecision = .supported(.default)
                return .supported(.default)
            }
            self.cachedKey = key
            self.cachedDecision = .unsupported
            return .unsupported
        }

        if sourcesCode == 404 || sourcesCode == 405 {
            if advertisedByStatus {
                self.cachedKey = key
                self.cachedDecision = .supported(.default)
                return .supported(.default)
            }
            self.cachedKey = key
            self.cachedDecision = .unsupported
            return .unsupported
        }

        if 500..<600 ~= sourcesCode {
            return .unavailable(.httpServerError(statusCode: sourcesCode))
        }

        if advertisedByStatus {
            self.cachedKey = key
            self.cachedDecision = .supported(.default)
            return .supported(.default)
        }
        self.cachedKey = key
        self.cachedDecision = .unsupported
        return .unsupported
    }

    private static func cacheKey(
        for endpoint: TransferResolvedEndpoint,
        journalVersion: String?
    ) -> CacheKey {
        CacheKey(
            baseURL: endpoint.baseURL,
            pairingGeneration: endpoint.dispatchOwner?.pairingGeneration,
            credentialCID: endpoint.dispatchOwner?.credentialCID,
            journalInstanceID: endpoint.dispatchOwner?.journalInstanceID,
            journalVersion: TransferRefusalConditions.normalizedJournalVersion(journalVersion)
        )
    }

    private static func classifyProbeInterruption(
        _ result: TransferHTTPResult
    ) -> ResumableImportCapabilityResult? {
        if let issue = result.issue {
            switch issue {
            case .timeout:
                return .unavailable(.timeout)
            case .cancelled:
                return .unavailable(.cancelled)
            case .connectionLost(let detail), .transport(let detail):
                return .unavailable(.transport(detail))
            }
        }
        guard let code = result.statusCode else {
            return .unavailable(.transport("missing status code"))
        }
        if code == 403, result.loopbackRefused {
            return .unavailable(.transport("loopback refused"))
        }
        if code == 401 || code == 403 {
            return .authRefused(statusCode: code)
        }
        return nil
    }

    static func parseSourcesResumableConfig(from data: Data) -> ResumableImportConfig? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let resumable = root["resumable"] as? [String: Any]
        else {
            return nil
        }
        let threshold = (resumable["threshold_bytes"] as? NSNumber)?.int64Value
        let chunk = (resumable["chunk_bytes"] as? NSNumber)?.intValue
        let maxFile = (resumable["max_file_bytes"] as? NSNumber)?.int64Value
        guard let threshold, threshold > 0 else { return nil }
        let clampedChunk = ResumableImportDefaults.clampedChunkBytes(chunk)
        let resolvedMaxFile = (maxFile != nil && maxFile! >= threshold)
            ? maxFile!
            : max(ResumableImportDefaults.maxFileBytes, threshold)
        return ResumableImportConfig(
            thresholdBytes: threshold,
            chunkBytes: clampedChunk,
            maxFileBytes: resolvedMaxFile
        )
    }
}

/// Fast retry ladder for resumable chunk uploads: `1s -> 2s -> 5s -> 10s -> 30s -> 60s`
/// with `±20%` jitter, resetting on every confirmed chunk or reconnect.
nonisolated struct ResumableRetryLadder: Equatable, Sendable {
    static let defaultStepsSeconds: [TimeInterval] = [1, 2, 5, 10, 30, 60]
    static let jitterRange: ClosedRange<Double> = 0.8...1.2

    var stepsSeconds: [TimeInterval]
    var jitterSalt: UInt64

    init(
        stepsSeconds: [TimeInterval] = Self.defaultStepsSeconds,
        jitterSalt: UInt64 = 0x52E5_2026
    ) {
        self.stepsSeconds = stepsSeconds.isEmpty ? Self.defaultStepsSeconds : stepsSeconds
        self.jitterSalt = jitterSalt
    }

    func delay(itemID: UUID, attempt: Int) -> TimeInterval {
        let clampedAttempt = max(1, attempt)
        let index = min(clampedAttempt - 1, self.stepsSeconds.count - 1)
        let base = self.stepsSeconds[index]
        return base * self.jitterFactor(itemID: itemID, attempt: clampedAttempt)
    }

    func jitterFactor(itemID: UUID, attempt: Int) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037 ^ self.jitterSalt
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for byte in itemID.uuidString.utf8 {
            mix(byte)
        }
        var value = UInt64(max(0, attempt))
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
        let unit = Double(hash % 10_000) / 9_999.0
        return Self.jitterRange.lowerBound + unit * (Self.jitterRange.upperBound - Self.jitterRange.lowerBound)
    }
}

nonisolated enum ResumableUploadIDValidator {
    static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 128 else { return false }
        return raw.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }

    static func isValidSHA256Hex(_ raw: String?) -> Bool {
        guard let raw, raw.utf8.count == 64 else { return false }
        return raw.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
        }
    }
}

nonisolated enum ResumableFileReaderError: Error, Equatable, Sendable {
    case unreadable(String)
    case unexpectedEOF(expected: Int, actual: Int)
    case cancelled
}

/// Off-MainActor streaming file hashing and bounded chunk reads directly from custody storage.
/// Uses POSIX `open`/`read`/`pread` into reusable/exact buffers so multi-gigabyte files stay
/// O(1) in RAM without accumulating autoreleased `NSData` pages on cooperative Swift threads.
nonisolated enum ResumableFileReader {
    static let hashBufferBytes = 64 * 1024

    static func sha256Hex(at url: URL) async throws -> String {
        if Task.isCancelled {
            throw ResumableFileReaderError.cancelled
        }
        let worker = Task.detached(priority: .utility) { () throws -> String in
            let fd: Int32 = url.withUnsafeFileSystemRepresentation { rep in
                guard let rep else { return -1 }
                return Darwin.open(rep, O_RDONLY)
            }
            guard fd >= 0 else {
                throw ResumableFileReaderError.unreadable(url.lastPathComponent)
            }
            defer { _ = Darwin.close(fd) }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: Self.hashBufferBytes)
            var iterations = 0
            while true {
                if iterations & 0x0F == 0, Task.isCancelled {
                    throw ResumableFileReaderError.cancelled
                }
                iterations += 1
                let bytesRead: Int = buffer.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return -1 }
                    while true {
                        let got = Darwin.read(fd, base, raw.count)
                        if got < 0 && errno == EINTR { continue }
                        return got
                    }
                }
                if bytesRead < 0 {
                    throw ResumableFileReaderError.unreadable(url.lastPathComponent)
                }
                if bytesRead == 0 {
                    break
                }
                buffer.withUnsafeBytes { raw in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw.prefix(bytesRead)))
                }
            }
            return Self.hexString(hasher.finalize())
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func readChunk(at url: URL, offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw ResumableFileReaderError.unreadable(url.lastPathComponent)
        }
        if Task.isCancelled {
            throw ResumableFileReaderError.cancelled
        }
        let worker = Task.detached(priority: .utility) { () throws -> Data in
            if Task.isCancelled {
                throw ResumableFileReaderError.cancelled
            }
            let fd: Int32 = url.withUnsafeFileSystemRepresentation { rep in
                guard let rep else { return -1 }
                return Darwin.open(rep, O_RDONLY)
            }
            guard fd >= 0 else {
                throw ResumableFileReaderError.unreadable(url.lastPathComponent)
            }
            defer { _ = Darwin.close(fd) }
            var result = Data(count: length)
            var filled = 0
            while filled < length {
                if Task.isCancelled {
                    throw ResumableFileReaderError.cancelled
                }
                let currentOffset = offset + Int64(filled)
                let want = length - filled
                let bytesRead: Int = result.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return -1 }
                    let dst = base.advanced(by: filled)
                    while true {
                        let got = Darwin.pread(fd, dst, want, off_t(currentOffset))
                        if got < 0 && errno == EINTR { continue }
                        return got
                    }
                }
                if bytesRead < 0 {
                    throw ResumableFileReaderError.unreadable(url.lastPathComponent)
                }
                if bytesRead == 0 {
                    throw ResumableFileReaderError.unexpectedEOF(expected: length, actual: filled)
                }
                filled += bytesRead
            }
            return result
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func sha256Hex(of data: Data) -> String {
        Self.hexString(SHA256.hash(data: data))
    }

    private static func hexString(_ digest: SHA256.Digest) -> String {
        var output = String()
        output.reserveCapacity(64)
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
        for byte in digest {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return output
    }
}

// MARK: - Wire DTOs (contracts/mobile-import/v1.schema.json)

nonisolated struct ResumableUploadCreatePayload: Sendable {
    var clientItemID: String
    var filename: String
    var totalBytes: Int64
    var sha256: String
    var mimeType: String?
    var importedVia: String
    var deviceNoun: String
    var capturedAt: String?
    var area: String?
    var context: String?

    func jsonData() throws -> Data {
        var object: [String: Any] = [
            "client_item_id": self.clientItemID,
            "filename": self.filename,
            "total_bytes": self.totalBytes,
            "sha256": self.sha256,
            "imported_via": self.importedVia,
            "device_noun": self.deviceNoun,
        ]
        if let mimeType = self.mimeType, !mimeType.isEmpty {
            object["mime_type"] = mimeType
        }
        if let capturedAt = self.capturedAt, !capturedAt.isEmpty {
            object["captured_at"] = capturedAt
        }
        if let area = self.area, !area.isEmpty {
            object["area"] = area
        }
        if let context = self.context, !context.isEmpty {
            if let parsed = (try? JSONSerialization.jsonObject(with: Data(context.utf8))) as? [String: Any] {
                object["context"] = parsed
            } else {
                object["context"] = context
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

nonisolated struct ResumableUploadOpenResponse: Equatable, Sendable {
    var uploadID: String
    var clientItemID: String
    var nextOffset: Int64
    var totalBytes: Int64
    var chunkBytes: Int?
    var expiresAt: String?
}

nonisolated enum ResumableUploadCreateResponse: Equatable, Sendable {
    case open(ResumableUploadOpenResponse)
    case alreadyStaged(saveResponseData: Data)
    case alreadyImported(importID: String?)
}

nonisolated struct ResumableUploadChunkResponse: Equatable, Sendable {
    var uploadID: String
    var nextOffset: Int64
    var totalBytes: Int64
    var complete: Bool
    var expiresAt: String?
}

nonisolated struct ResumableUploadStatusResponse: Equatable, Sendable {
    var uploadID: String
    var nextOffset: Int64
    var totalBytes: Int64
    var chunkBytes: Int?
    var expiresAt: String?
}

nonisolated struct ResumableUploadErrorBody: Equatable, Sendable {
    var error: String?
    var reasonCode: String?
    var nextOffset: Int64?
    var totalBytes: Int64?
    var requiredBytes: Int64?
    var availableBytes: Int64?

    static func parse(from data: Data) -> ResumableUploadErrorBody? {
        autoreleasepool {
            guard !data.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return nil
            }
            return ResumableUploadErrorBody(
                error: object["error"] as? String,
                reasonCode: object["reason_code"] as? String,
                nextOffset: (object["next_offset"] as? NSNumber)?.int64Value,
                totalBytes: (object["total_bytes"] as? NSNumber)?.int64Value,
                requiredBytes: (object["required_bytes"] as? NSNumber)?.int64Value,
                availableBytes: (object["available_bytes"] as? NSNumber)?.int64Value
            )
        }
    }
}

nonisolated enum ResumableUploadWireDecoder {
    static func decodeCreateResponse(from data: Data) -> ResumableUploadCreateResponse? {
        autoreleasepool {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let status = object["status"] as? String
            else {
                return nil
            }
            switch status {
            case "open":
                guard let uploadID = object["upload_id"] as? String,
                      ResumableUploadIDValidator.isValid(uploadID),
                      let clientItemID = object["client_item_id"] as? String,
                      let nextOffset = (object["next_offset"] as? NSNumber)?.int64Value,
                      let totalBytes = (object["total_bytes"] as? NSNumber)?.int64Value,
                      nextOffset >= 0,
                      totalBytes > 0,
                      nextOffset <= totalBytes
                else {
                    return nil
                }
                return .open(ResumableUploadOpenResponse(
                    uploadID: uploadID,
                    clientItemID: clientItemID,
                    nextOffset: nextOffset,
                    totalBytes: totalBytes,
                    chunkBytes: (object["chunk_bytes"] as? NSNumber)?.intValue,
                    expiresAt: object["expires_at"] as? String
                ))
            case "already_staged":
                guard let saveObject = object["save_response"] as? [String: Any],
                      let saveData = try? JSONSerialization.data(withJSONObject: saveObject)
                else {
                    return nil
                }
                return .alreadyStaged(saveResponseData: saveData)
            case "already_imported":
                let importID = ShareImportID.validated(object["import_id"] as? String)
                return .alreadyImported(importID: importID)
            default:
                return nil
            }
        }
    }

    static func decodeChunkResponse(from data: Data) -> ResumableUploadChunkResponse? {
        autoreleasepool {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let uploadID = object["upload_id"] as? String,
                  ResumableUploadIDValidator.isValid(uploadID),
                  let nextOffset = (object["next_offset"] as? NSNumber)?.int64Value,
                  let totalBytes = (object["total_bytes"] as? NSNumber)?.int64Value,
                  nextOffset >= 0,
                  totalBytes > 0,
                  nextOffset <= totalBytes
            else {
                return nil
            }
            let complete = (object["complete"] as? Bool) ?? (nextOffset == totalBytes)
            return ResumableUploadChunkResponse(
                uploadID: uploadID,
                nextOffset: nextOffset,
                totalBytes: totalBytes,
                complete: complete,
                expiresAt: object["expires_at"] as? String
            )
        }
    }

    static func decodeStatusResponse(from data: Data) -> ResumableUploadStatusResponse? {
        autoreleasepool {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let uploadID = object["upload_id"] as? String,
                  ResumableUploadIDValidator.isValid(uploadID),
                  let nextOffset = (object["next_offset"] as? NSNumber)?.int64Value,
                  let totalBytes = (object["total_bytes"] as? NSNumber)?.int64Value,
                  nextOffset >= 0,
                  totalBytes > 0,
                  nextOffset <= totalBytes
            else {
                return nil
            }
            return ResumableUploadStatusResponse(
                uploadID: uploadID,
                nextOffset: nextOffset,
                totalBytes: totalBytes,
                chunkBytes: (object["chunk_bytes"] as? NSNumber)?.intValue,
                expiresAt: object["expires_at"] as? String
            )
        }
    }

    static func commitBodyData(sha256: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["sha256": sha256], options: [.sortedKeys])
    }
}

nonisolated enum ResumableUploadLog {
    static func info(_ message: String) {
        resumableUploadLog.info("\(message, privacy: .public)")
    }

    static func notice(_ message: String) {
        resumableUploadLog.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        resumableUploadLog.error("\(message, privacy: .public)")
    }
}
