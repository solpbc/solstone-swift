// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation
import os

private let problemReportsUITestSeedLog = Logger(subsystem: "app.solstone.swift", category: "ui-test-seed")

@MainActor
enum ProblemReportsUITestSeeder {
    private static let resetFlag = "--ui-test-reset-problem-reports"
    private static let seedPrefix = "--ui-test-seed-problem-reports="

    static let detailReportID = UUID(uuidString: "a47f3cd6-0b25-4f3e-8bb5-86a571768601")!

    enum SeedMode: String {
        case optedOut = "opted-out"
        case optedInEmpty = "opted-in-empty"
        case populatedList = "populated-list"
        case detail
    }

    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        rootURL: URL = ProblemReportStore.defaultRootURL,
        fileManager: FileManager = .default
    ) {
        guard arguments.contains("--ui-test") else { return }
        let mode = self.seedMode(arguments: arguments)
        let shouldReset = arguments.contains(Self.resetFlag)
        guard shouldReset || mode != nil else { return }

        do {
            try self.reset(rootURL: rootURL, fileManager: fileManager)
            guard let mode else {
                UserSettings.problemReportsEnabled = false
                return
            }
            switch mode {
            case .optedOut:
                UserSettings.problemReportsEnabled = false
            case .optedInEmpty:
                UserSettings.problemReportsEnabled = true
            case .populatedList:
                UserSettings.problemReportsEnabled = true
                try self.seedPopulatedList(rootURL: rootURL, fileManager: fileManager)
            case .detail:
                UserSettings.problemReportsEnabled = true
                try self.writeReport(
                    rootURL: rootURL,
                    id: Self.detailReportID,
                    date: Date(timeIntervalSince1970: 1_780_480_800),
                    kind: .crash,
                    source: .diagnostic,
                    rawJSON: Self.crashJSON,
                    fileManager: fileManager
                )
            }
        } catch {
            problemReportsUITestSeedLog.error("problem reports ui-test seed failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension ProblemReportsUITestSeeder {
    static func seedMode(arguments: [String]) -> SeedMode? {
        guard let raw = arguments.first(where: { $0.hasPrefix(Self.seedPrefix) }) else { return nil }
        return SeedMode(rawValue: String(raw.dropFirst(Self.seedPrefix.count)))
    }

    static func reset(rootURL: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        UserSettings.problemReportsEnabled = false
    }

    static func seedPopulatedList(rootURL: URL, fileManager: FileManager) throws {
        try self.writeReport(
            rootURL: rootURL,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            date: Date(timeIntervalSince1970: 1_780_480_900),
            kind: .crash,
            source: .diagnostic,
            rawJSON: Self.crashJSON,
            fileManager: fileManager
        )
        try self.writeReport(
            rootURL: rootURL,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            date: Date(timeIntervalSince1970: 1_780_480_800),
            kind: .appExit,
            source: .metric,
            rawJSON: Self.appExitJSON,
            fileManager: fileManager
        )
        try self.writeReport(
            rootURL: rootURL,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            date: Date(timeIntervalSince1970: 1_780_480_700),
            kind: .unknown("futureThermalDiagnostics"),
            source: .diagnostic,
            rawJSON: Self.unknownJSON,
            fileManager: fileManager
        )
    }

    static func writeReport(
        rootURL: URL,
        id: UUID,
        date: Date,
        kind: ProblemReportKind,
        source: ProblemReportPayloadSource,
        rawJSON: String,
        fileManager: FileManager
    ) throws {
        let data = Data(rawJSON.utf8)
        let hash = ProblemReportStore.contentHash(for: data)
        let filename = ProblemReportStore.makeFilename(date: date, kind: kind, contentHash: hash, id: id)
        let report = ProblemReport(
            id: id,
            date: date,
            kind: kind,
            allKinds: [kind],
            source: source,
            filename: filename,
            rawJSON: rawJSON,
            contentHash: hash
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: rootURL.appendingPathComponent(filename, isDirectory: false), options: [.atomic])
    }

    static let crashJSON = """
    {"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","crashDiagnostics":[{"version":"0.1.0","diagnosticMetaData":{"appVersion":"0.1.0","appBuildVersion":"48","terminationReason":"namespace signal, code 0xb"}}]}
    """

    static let appExitJSON = """
    {"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","appVersion":"0.1.0","applicationExitMetrics":{"foregroundExitData":{"cumulativeNormalAppExitCount":1},"backgroundExitData":{"cumulativeNormalAppExitCount":2}}}
    """

    static let unknownJSON = """
    {"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","futureThermalDiagnostics":[{"version":"0.1.0","diagnosticMetaData":{"thermalState":"serious"}}]}
    """
}
#endif
