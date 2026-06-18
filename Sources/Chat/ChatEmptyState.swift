import SwiftUI

struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor.opacity(0.6))

            Text(SourceVocabulary.chatEmptyHeading)
                .font(.title3)
                .fontWeight(.semibold)

            Text(SourceVocabulary.chatEmptyBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 8) {
                Text(SourceVocabulary.chatEmptySeed1)
                Text(SourceVocabulary.chatEmptySeed2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
