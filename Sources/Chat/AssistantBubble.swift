import SwiftUI

struct AssistantBubble: View {
    let message: ChatMessage

    var body: some View {
        Text(self.message.text)
    }
}
