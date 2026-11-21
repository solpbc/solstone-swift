// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import os

private nonisolated let problemReportStoreLog = Logger(subsystem: "app.solstone.swift", category: "diagnostics")

@MainActor
final class ProblemReportStore {
    nonisolated static let maxReportCount = 50
    nonisolated static let maxReportAge: TimeInterval = 90 * 24 * 60 * 60

    static var defaultRootURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent("problem-reports", isDirectory: true)
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let diagnosticLog: DiagnosticLog?
    private let now: @Sendable () -> Date

    init(
        rootURL: URL = ProblemReportStore.defaultRootURL,
        fileManager: FileManager = .default,
        diagnosticLog: DiagnosticLog? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.diagnosticLog = diagnosticLog
        self.now = now
    }

    func ingest(_ inputs: [ProblemReportPayloadInput]) {
        guard !inputs.isEmpty else { return }

        for input in inputs {
            let hash = Self.contentHash(for: input.jsonData)
            if self.hasPersistedReport(withHash: hash) {
                continue
            }

            guard let rawJSON = String(data: input.jsonData, encoding: .utf8) else {
                self.appendFailure(stage: "decode", severity: .warning, kind: .unknown(input.source.rawValue), count: 1, message: AppStrings.ios_problemreports_problemreportcouldnotberead())
                continue
            }

            let kinds: [ProblemReportKind]
            do {
                kinds = try Self.kinds(in: input.jsonData, source: input.source)
            } catch {
                self.appendFailure(stage: "decode", severity: .warning, kind: .unknown(input.source.rawValue), count: 1, message: AppStrings.ios_problemreports_problemreportcouldnotberead())
                continue
            }

            let kind = ProblemReportKind.primary(from: kinds, source: input.source)
            let id = UUID()
            let filename = Self.makeFilename(date: input.receivedAt, kind: kind, contentHash: hash, id: id)
            let report = ProblemReport(
                id: id,
                date: input.receivedAt,
                kind: kind,
                allKinds: kinds,
                source: input.source,
                filename: filename,
                rawJSON: rawJSON,
                contentHash: hash
            )

            do {
                try self.persist(report)
            } catch {
                problemReportStoreLog.error("problem report persist failed: \(String(describing: error), privacy: .public)")
                self.appendFailure(stage: "persist", severity: .error, kind: kind, count: 1, message: AppStrings.ios_problemreports_ingest())
            }
        }

        self.rotate()
    }

    var testDecodeObserver: (@Sendable (String) -> Void)?

    func all() -> [ProblemReport] {
        let reports = self.loadReports()
        return self.rotate(reports: reports)
    }

    func reportDecodeFailures(count: Int) {
        guard count > 0 else { return }
        self.appendFailure(
            stage: "decode",
            severity: .warning,
            kind: .unknown("stored"),
            count: count,
            message: AppStrings.ios_problemreports_problemreportcouldnotberead()
        )
    }

    nonisolated static func loadAndRotate(
        rootURL: URL,
        now: Date,
        onDecode: (@Sendable (String) -> Void)? = nil
    ) -> (reports: [ProblemReport], failedDecodeCount: Int) {
        let fileManager = FileManager()
        let loaded = Self.readReports(
            rootURL: rootURL,
            fileManager: fileManager,
            onDecode: onDecode
        )
        let surviving = Self.rotateReports(
            loaded.reports,
            rootURL: rootURL,
            now: now,
            fileManager: fileManager
        )
        return (surviving, loaded.failedDecodeCount)
    }

    func loadSnapshotOffMain() async -> (reports: [ProblemReport], failedDecodeCount: Int) {
        let rootURL = self.rootURL
        let now = self.now()
        let onDecode = self.testDecodeObserver
        return await Task.detached(priority: .utility) {
            Self.loadAndRotate(rootURL: rootURL, now: now, onDecode: onDecode)
        }.value
    }

    func report(id: UUID) -> ProblemReport? {
        self.all().first { $0.id == id }
    }

    func delete(id: UUID) {
        guard let report = self.loadReports().first(where: { $0.id == id }) else { return }
        self.deleteFile(named: report.filename)
    }

    func deleteAll() {
        for report in self.loadReports() {
            self.deleteFile(named: report.filename)
        }
    }

    func exportFileURL(for report: ProblemReport) -> URL? {
        do {
            let data = try self.persistedData(for: report)
            let redacted = Self.redactedData(from: data)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.singleShareFilename(date: self.now()), isDirectory: false)
            try redacted.write(to: url, options: [.atomic])
            return url
        } catch {
            problemReportStoreLog.error("problem report share failed: \(String(describing: error), privacy: .public)")
            self.appendFailure(stage: "share", severity: .warning, kind: report.kind, count: 1, message: AppStrings.ios_problemreports_problemreportcouldnotbeshared())
            return nil
        }
    }

    func exportAllFileURL(reports: [ProblemReport]) -> URL? {
        do {
            let redactedReports = reports.map { report in
                ProblemReport(
                    id: report.id,
                    date: report.date,
                    kind: report.kind,
                    allKinds: report.allKinds,
                    source: report.source,
                    filename: report.filename,
                    rawJSON: DiagnosticLog.redact(report.rawJSON),
                    contentHash: report.contentHash
                )
            }
            let encoder = Self.encoder()
            let data = try encoder.encode(redactedReports)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.allShareFilename(date: self.now()), isDirectory: false)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            problemReportStoreLog.error("problem report share-all failed: \(String(describing: error), privacy: .public)")
            self.appendFailure(stage: "share", severity: .warning, kind: .unknown("all"), count: reports.count, message: AppStrings.ios_problemreports_problemreportcouldnotbeshared())
            return nil
        }
    }
}

extension ProblemReportStore {
    static func contentHash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func makeFilename(date: Date, kind: ProblemReportKind, contentHash: String, id: UUID) -> String {
        "\(Self.sortableTimestamp(for: date))-\(kind.filenameSlug)-\(contentHash)-\(id.uuidString).json"
    }

    static func sortableTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }

    static func kinds(in data: Data, source: ProblemReportPayloadSource) throws -> [ProblemReportKind] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            return [.unknown(source.rawValue)]
        }

        switch source {
        case .diagnostic:
            return self.diagnosticKinds(in: object)
        case .metric:
            if let appExit = object["applicationExitMetrics"] as? [String: Any], !appExit.isEmpty {
                return [.appExit]
            }
            return [.metrics]
        }
    }
}

private extension ProblemReportStore {
    static let knownDiagnosticKeys: [(key: String, kind: ProblemReportKind)] = [
        ("crashDiagnostics", .crash),
        ("hangDiagnostics", .hang),
        ("cpuExceptionDiagnostics", .cpuException),
        ("diskWriteExceptionDiagnostics", .diskWriteException),
        ("appLaunchDiagnostics", .appLaunch),
    ]

    static let knownDiagnosticKeySet = Set(ProblemReportStore.knownDiagnosticKeys.map(\.key))

    static func diagnosticKinds(in object: [String: Any]) -> [ProblemReportKind] {
        var kinds: [ProblemReportKind] = []
        for (key, kind) in self.knownDiagnosticKeys where self.hasNonEmptyArray(object[key]) {
            kinds.append(kind)
        }
        for key in object.keys.sorted()
            where key.hasSuffix("diagnostics".capitalized)
                && !self.knownDiagnosticKeySet.contains(key)
                && self.hasNonEmptyArray(object[key])
        {
            kinds.append(.unknown(key))
        }
        return kinds.isEmpty ? [.unknown("diagnostic")] : kinds
    }

    static func hasNonEmptyArray(_ value: Any?) -> Bool {
        guard let array = value as? [Any] else { return false }
        return !array.isEmpty
    }

    func persist(_ report: ProblemReport) throws {
        try self.fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(report)
        try data.write(to: self.rootURL.appendingPathComponent(report.filename, isDirectory: false), options: [.atomic])
    }

    func persistedData(for report: ProblemReport) throws -> Data {
        try Data(contentsOf: self.rootURL.appendingPathComponent(report.filename, isDirectory: false))
    }

    func loadReports(reportFailures: Bool = true) -> [ProblemReport] {
        let loaded = Self.readReports(
            rootURL: self.rootURL,
            fileManager: self.fileManager,
            onDecode: self.testDecodeObserver
        )
        if reportFailures && loaded.failedDecodeCount > 0 {
            self.reportDecodeFailures(count: loaded.failedDecodeCount)
        }
        return loaded.reports
    }

    @discardableResult
    func rotate(reports providedReports: [ProblemReport]? = nil) -> [ProblemReport] {
        let reports = providedReports ?? self.loadReports()
        return Self.rotateReports(
            reports,
            rootURL: self.rootURL,
            now: self.now(),
            fileManager: self.fileManager
        )
    }

    nonisolated static func readReports(
        rootURL: URL,
        fileManager: FileManager,
        onDecode: (@Sendable (String) -> Void)?
    ) -> (reports: [ProblemReport], failedDecodeCount: Int) {
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else {
            return ([], 0)
        }

        var reports: [ProblemReport] = []
        var failedDecodeCount = 0
        let decoder = Self.decoder()
        for filename in filenames where filename.hasSuffix(".json") {
            let url = rootURL.appendingPathComponent(filename, isDirectory: false)
            // Fires once per file enumerated before read+decode (supports single-pass & concurrent-ENOENT tests).
            onDecode?(filename)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                if Self.isMissingFileError(error) {
                    continue
                }
                failedDecodeCount += 1
                continue
            }
            do {
                reports.append(try decoder.decode(ProblemReport.self, from: data))
            } catch {
                failedDecodeCount += 1
            }
        }
        return (Self.sorted(reports), failedDecodeCount)
    }

    @discardableResult
    nonisolated static func rotateReports(
        _ reports: [ProblemReport],
        rootURL: URL,
        now: Date,
        fileManager: FileManager
    ) -> [ProblemReport] {
        guard !reports.isEmpty else { return [] }

        let cutoff = now.addingTimeInterval(-Self.maxReportAge)
        let sortedOldestFirst = reports.sorted {
            if $0.date == $1.date {
                return $0.filename < $1.filename
            }
            return $0.date < $1.date
        }
        let newest = Self.sorted(reports)
        let overflowIDs = Set(newest.dropFirst(Self.maxReportCount).map(\.id))
        let expiredIDs = Set(reports.filter { $0.date < cutoff }.map(\.id))
        let deleteIDs = overflowIDs.union(expiredIDs)

        var deletedIDs = Set<UUID>()
        for report in sortedOldestFirst where deleteIDs.contains(report.id) {
            if Self.deleteFile(named: report.filename, in: rootURL, fileManager: fileManager) {
                deletedIDs.insert(report.id)
            }
        }
        guard !deletedIDs.isEmpty else { return newest }
        return newest.filter { !deletedIDs.contains($0.id) }
    }

    nonisolated static func sorted(_ reports: [ProblemReport]) -> [ProblemReport] {
        reports.sorted {
            if $0.filename == $1.filename {
                return $0.date > $1.date
            }
            return $0.filename > $1.filename
        }
    }

    func hasPersistedReport(withHash hash: String) -> Bool {
        guard let filenames = try? self.fileManager.contentsOfDirectory(atPath: self.rootURL.path) else {
            return false
        }
        return filenames.contains { $0.contains("-\(hash)-") }
    }

    @discardableResult
    func deleteFile(named filename: String) -> Bool {
        Self.deleteFile(named: filename, in: self.rootURL, fileManager: self.fileManager)
    }

    @discardableResult
    nonisolated static func deleteFile(named filename: String, in rootURL: URL, fileManager: FileManager) -> Bool {
        let url = rootURL.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            if Self.isMissingFileError(error) {
                return true
            }
            problemReportStoreLog.error("problem report delete failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    nonisolated static func isMissingFileError(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError,
           cocoa.code == .fileNoSuchFile || cocoa.code == .fileReadNoSuchFile {
            return true
        }
        if let posix = error as? POSIXError, posix.code == .ENOENT {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileNoSuchFile.rawValue
            || nsError.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return Self.isMissingFileError(underlying)
        }
        return false
    }

    func appendFailure(stage: String, severity: DiagnosticSeverity, kind: ProblemReportKind, count: Int, message: String) {
        self.diagnosticLog?.append(
            category: .diagnostics,
            severity: severity,
            message: message,
            detail: AppStrings.ios_problemreports_appendfailure_native("\(kind.filenameSlug)", "\(count)", "\(stage)")
        )
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func redactedData(from data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        return Data(DiagnosticLog.redact(text).utf8)
    }

    static func singleShareFilename(date: Date) -> String {
        "solstone-problem-report-\(Self.sanitized(AppVersion.shortVersion))-\(Self.sanitized(AppVersion.build))-\(Self.shareDateString(for: date)).json"
    }

    static func allShareFilename(date: Date) -> String {
        "solstone-problem-reports-\(Self.sanitized(AppVersion.shortVersion))-\(Self.sanitized(AppVersion.build))-\(Self.shareDateString(for: date)).json"
    }

    static func shareDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars)
    }
}
