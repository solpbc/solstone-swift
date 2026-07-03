// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ProblemReportPayloadSource: String, Codable, Sendable {
    case diagnostic
    case metric
}

nonisolated struct ProblemReportPayloadInput: Sendable {
    let source: ProblemReportPayloadSource
    let jsonData: Data
    let receivedAt: Date

    init(source: ProblemReportPayloadSource, jsonData: Data, receivedAt: Date = Date()) {
        self.source = source
        self.jsonData = jsonData
        self.receivedAt = receivedAt
    }
}

nonisolated enum ProblemReportKind: Equatable, Hashable, Sendable {
    case crash
    case hang
    case cpuException
    case diskWriteException
    case appLaunch
    case appExit
    case unknown(String)

    var filenameSlug: String {
        switch self {
        case .crash:
            "crash"
        case .hang:
            "hang"
        case .cpuException:
            "cpu-exception"
        case .diskWriteException:
            "disk-write-exception"
        case .appLaunch:
            "app-launch"
        case .appExit:
            "app-exit"
        case .unknown:
            "unknown"
        }
    }

    var ownerLabel: String {
        switch self {
        case .crash:
            SourceVocabulary.problemReportKindCrash
        case .hang:
            SourceVocabulary.problemReportKindHang
        case .cpuException:
            SourceVocabulary.problemReportKindCPUException
        case .diskWriteException:
            SourceVocabulary.problemReportKindDiskWriteException
        case .appLaunch:
            SourceVocabulary.problemReportKindAppLaunch
        case .appExit:
            SourceVocabulary.problemReportKindAppExit
        case .unknown:
            SourceVocabulary.problemReportKindUnknown
        }
    }

    static func primary(from kinds: [ProblemReportKind], source: ProblemReportPayloadSource) -> ProblemReportKind {
        let priority: [ProblemReportKind] = [
            .crash,
            .hang,
            .cpuException,
            .diskWriteException,
            .appLaunch,
            .appExit,
        ]
        for candidate in priority where kinds.contains(candidate) {
            return candidate
        }
        return kinds.first ?? .unknown(source.rawValue)
    }
}

extension ProblemReportKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case slug
        case value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let slug = try container.decode(String.self, forKey: .slug)
        switch slug {
        case "crash":
            self = .crash
        case "hang":
            self = .hang
        case "cpu-exception":
            self = .cpuException
        case "disk-write-exception":
            self = .diskWriteException
        case "app-launch":
            self = .appLaunch
        case "app-exit":
            self = .appExit
        case "unknown":
            self = .unknown(try container.decodeIfPresent(String.self, forKey: .value) ?? "unknown")
        default:
            self = .unknown(slug)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.filenameSlug, forKey: .slug)
        if case .unknown(let value) = self {
            try container.encode(value, forKey: .value)
        }
    }
}

nonisolated struct ProblemReport: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let kind: ProblemReportKind
    let allKinds: [ProblemReportKind]
    let source: ProblemReportPayloadSource
    let filename: String
    let rawJSON: String
    let contentHash: String
}
