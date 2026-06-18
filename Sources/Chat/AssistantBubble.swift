import SwiftUI

struct AssistantBubble: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        if let provenance = self.message.provenance {
            VStack(alignment: .leading, spacing: 8) {
                self.coverageTrace(provenance.coverageLines)
                self.answerText
                    .foregroundStyle(self.answerForeground(for: provenance.state))
                self.provenanceAffordance(provenance)
            }
            .accessibilityElement(children: .contain)
        } else {
            self.answerText
        }
    }

    private var answerText: Text {
        let sanitized = ChatMarkdown.stripSolCitations(from: self.message.text).text
        if let attributed = ChatMarkdown.attributedString(from: self.message.text) {
            return Text(attributed)
        }
        return Text(sanitized)
    }

    private func answerForeground(for state: AnswerState) -> Color {
        switch state {
        case .answered:
            .primary
        case .partial:
            .secondary
        case .failed:
            .red
        }
    }

    @ViewBuilder
    private func coverageTrace(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("chat.provenance.coverage")
        }
    }

    @ViewBuilder
    private func provenanceAffordance(_ provenance: AnswerProvenance) -> some View {
        switch provenance.state {
        case .answered:
            if provenance.showsPill {
                ProvenanceSourcesPill(
                    count: provenance.sources.count,
                    isExpanded: self.isExpanded,
                    action: {
                        self.isExpanded.toggle()
                    }
                )
                if self.isExpanded {
                    ProvenanceSourcesPanel(sources: provenance.sources)
                }
            }
        case .partial:
            self.honestLine(SourceVocabulary.chatPartialHonestLine)
        case .failed:
            self.honestLine(SourceVocabulary.chatAnswerFailedLine)
                .foregroundStyle(.red)
        }
    }

    private func honestLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.provenance.noSources")
    }
}

struct ProvenanceSourcesPill: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    private var label: String {
        SourceVocabulary.chatSourceCount(self.count)
    }

    var body: some View {
        Button(action: self.action) {
            NeutralSourceChip(label: self.label)
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
            SourceVocabulary.chatSourcesPillA11yExpanded(count: self.count)
        } else {
            SourceVocabulary.chatSourcesPillA11yCollapsed(count: self.count)
        }
    }
}

private struct NeutralSourceChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.secondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(self.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
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
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(source.label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.provenance.source.row")

                    Spacer(minLength: 8)

                    if let url = source.url {
                        Button(SourceVocabulary.chatSourceOpenTitle) {
                            self.openURL(url)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(SourceVocabulary.openInJournal)
                        .accessibilityIdentifier("chat.provenance.open")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.provenance.source.row")
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.provenance.panel")
    }
}
