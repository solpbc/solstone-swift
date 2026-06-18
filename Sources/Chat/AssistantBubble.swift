import SwiftUI

struct AssistantBubble: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        if let provenance = self.message.provenance {
            VStack(alignment: .leading, spacing: 8) {
                self.coverageTrace(provenance.coverageLines)
                Text(self.message.text)
                    .foregroundStyle(provenance.showsPill ? .primary : .secondary)
                self.provenanceAffordance(provenance)
            }
            .accessibilityElement(children: .contain)
        } else {
            Text(self.message.text)
        }
    }

    private func coverageTrace(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("chat.provenance.coverage")
    }

    @ViewBuilder
    private func provenanceAffordance(_ provenance: AnswerProvenance) -> some View {
        switch provenance {
        case .sourced(let sources, let confidence, _):
            if provenance.showsPill {
                ProvenanceSourcesPill(
                    count: sources.count,
                    confidence: confidence,
                    isExpanded: self.isExpanded,
                    action: {
                        self.isExpanded.toggle()
                    }
                )
                if self.isExpanded {
                    ProvenanceSourcesPanel(sources: sources)
                }
            } else {
                self.noSourceLine
            }
        case .unknown:
            self.noSourceLine
        }
    }

    private var noSourceLine: some View {
        Text(SourceVocabulary.chatNoSourceLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.provenance.noSources")
    }
}

struct ProvenanceSourcesPill: View {
    let count: Int
    let confidence: AnswerProvenance.Confidence?
    let isExpanded: Bool
    let action: () -> Void

    private var confidenceLabel: String? {
        self.confidence.map { ConfidenceStyle.style(for: $0).label }
    }

    private var label: String {
        let sourceCount = SourceVocabulary.chatSourceCount(self.count)
        guard let confidenceLabel else { return sourceCount }
        return "\(sourceCount)\(SourceVocabulary.chatSourceSeparator)\(confidenceLabel)"
    }

    var body: some View {
        Button(action: self.action) {
            ConfidenceChip(label: self.label, confidence: self.confidence)
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .accessibilityIdentifier("chat.provenance.pill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityIdentifier("chat.provenance.pill")
    }

    private var accessibilityLabel: String {
        if self.isExpanded {
            SourceVocabulary.chatSourcesPillA11yExpanded(
                count: self.count,
                confidence: self.confidenceLabel
            )
        } else {
            SourceVocabulary.chatSourcesPillA11yCollapsed(
                count: self.count,
                confidence: self.confidenceLabel
            )
        }
    }
}

struct ProvenanceSourcesPanel: View {
    let sources: [AnswerProvenance.ProvenanceSource]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(self.sources) { source in
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(Color("Confidence/Low/Dot"))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(self.rowTitle(for: source))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.provenance.source.row")

                    Spacer(minLength: 8)

                    Button(SourceVocabulary.chatSourceOpenTitle) {
                        if let openURL = source.openURL {
                            self.openURL(openURL)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(source.openURL == nil)
                    .accessibilityLabel(SourceVocabulary.openInJournal)
                    .accessibilityIdentifier("chat.provenance.open")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.provenance.source.row")
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.provenance.panel")
    }

    private func rowTitle(for source: AnswerProvenance.ProvenanceSource) -> String {
        if let detail = source.detail, !detail.isEmpty {
            return "\(source.label)\(SourceVocabulary.chatSourceSeparator)\(detail)"
        }
        return source.label
    }
}
