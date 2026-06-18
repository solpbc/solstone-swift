import Foundation

nonisolated enum AnswerProvenance: Sendable, Equatable {
    case sourced(sources: [ProvenanceSource], confidence: Confidence?, coverage: [String])
    case unknown(coverage: [String])

    enum Confidence: Sendable, Equatable {
        case high
        case medium
        case low
    }

    struct ProvenanceSource: Sendable, Equatable, Identifiable {
        let id: UUID
        let label: String
        let detail: String?
        let openURL: URL?
    }

    var showsPill: Bool {
        switch self {
        case .sourced(let sources, _, _):
            !sources.isEmpty
        case .unknown:
            false
        }
    }

    var coverageLines: [String] {
        switch self {
        case .sourced(_, _, let coverage):
            coverage
        case .unknown(let coverage):
            coverage
        }
    }
}
