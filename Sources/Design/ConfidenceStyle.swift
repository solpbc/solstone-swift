import SwiftUI

struct ConfidenceStyle {
    let dot: Color
    let text: Color
    let chipBackground: Color
    let label: String
    let dotAssetName: String
    let textAssetName: String
    let chipBackgroundAssetName: String

    static func style(for confidence: AnswerProvenance.Confidence) -> ConfidenceStyle {
        switch confidence {
        case .high:
            ConfidenceStyle(
                dot: Color("Confidence/High/Dot"),
                text: Color("Confidence/High/Text"),
                chipBackground: Color("Confidence/High/ChipBackground"),
                label: SourceVocabulary.chatSourceConfidenceHigh,
                dotAssetName: Self.assetName(grade: "high", leafWords: "dot"),
                textAssetName: Self.assetName(grade: "high", leafWords: "text"),
                chipBackgroundAssetName: Self.assetName(grade: "high", leafWords: "chip", "background")
            )
        case .medium:
            ConfidenceStyle(
                dot: Color("Confidence/Medium/Dot"),
                text: Color("Confidence/Medium/Text"),
                chipBackground: Color("Confidence/Medium/ChipBackground"),
                label: SourceVocabulary.chatSourceConfidenceMedium,
                dotAssetName: Self.assetName(grade: "medium", leafWords: "dot"),
                textAssetName: Self.assetName(grade: "medium", leafWords: "text"),
                chipBackgroundAssetName: Self.assetName(grade: "medium", leafWords: "chip", "background")
            )
        case .low:
            ConfidenceStyle(
                dot: Color("Confidence/Low/Dot"),
                text: Color("Confidence/Low/Text"),
                chipBackground: Color("Confidence/Low/ChipBackground"),
                label: SourceVocabulary.chatSourceConfidenceLow,
                dotAssetName: Self.assetName(grade: "low", leafWords: "dot"),
                textAssetName: Self.assetName(grade: "low", leafWords: "text"),
                chipBackgroundAssetName: Self.assetName(grade: "low", leafWords: "chip", "background")
            )
        }
    }

    private static func assetName(grade: String, leafWords: String...) -> String {
        "\(Self.pascal("confidence"))/\(Self.pascal(grade))/\(leafWords.map(Self.pascal).joined())"
    }

    private static func pascal(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return String(first).uppercased() + String(raw.dropFirst())
    }
}

struct ConfidenceChip: View {
    let label: String
    let confidence: AnswerProvenance.Confidence?

    private var style: ConfidenceStyle {
        ConfidenceStyle.style(for: self.confidence ?? .low)
    }

    var body: some View {
        HStack(spacing: 6) {
            if self.confidence != nil {
                Circle()
                    .fill(self.style.dot)
                    .frame(width: 7, height: 7)
            }
            Text(self.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(self.style.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(self.style.chipBackground, in: Capsule())
    }
}
