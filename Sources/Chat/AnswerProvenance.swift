import Foundation

nonisolated enum AnswerState: String, Sendable, Equatable, Codable {
    case answered
    case partial
    case failed
}

nonisolated struct AnswerProvenance: Sendable, Equatable {
    let state: AnswerState
    let sources: [ProvenanceSource]
    let coverage: [String]

    init(
        state: AnswerState = .answered,
        sources: [ProvenanceSource] = [],
        coverage: [String] = []
    ) {
        self.state = state
        self.sources = sources
        self.coverage = coverage
    }

    struct ProvenanceSource: Sendable, Equatable, Identifiable {
        // Stable by ref so SwiftUI diffing survives snapshot/SSE re-hydrate.
        let id: String
        let ref: String
        let label: String
        let url: URL?

        init(ref: String, label: String, url: URL? = nil) {
            self.id = ref
            self.ref = ref
            self.label = label
            self.url = url
        }
    }

    var showsPill: Bool {
        !self.sources.isEmpty
    }

    var coverageLines: [String] {
        self.coverage
    }
}
