import SwiftUI

struct ChatView: View {
    @Environment(ChatManager.self) private var chatManager
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var scrollPosition = ScrollPosition(idType: UUID.self, edge: .bottom)
    @State private var pinnedMessageID: UUID?
    @State private var userIsDragging = false
    @State private var userIsBrowsing = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !self.tunnelManager.state.isConnected {
                    self.offlineBanner
                }

                if self.chatManager.messages.isEmpty && !self.chatManager.isSending {
                    ChatEmptyState()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(self.chatManager.messages) { message in
                                BubbleView(message: message)
                                    .id(message.id)
                            }

                            if self.chatManager.isSending {
                                TypingIndicator()
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollPosition(self.$scrollPosition)
                    .onScrollPhaseChange { _, newPhase in
                        switch newPhase {
                        case .tracking, .interacting, .decelerating:
                            self.userIsDragging = true
                            self.pinnedMessageID = nil
                        case .idle:
                            self.userIsDragging = false
                        case .animating:
                            break
                        @unknown default:
                            break
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        max(
                            0,
                            (geometry.contentSize.height + geometry.contentInsets.bottom)
                                - (geometry.contentOffset.y + geometry.containerSize.height)
                        )
                    } action: { _, distance in
                        self.userIsBrowsing = distance > 80
                    }
                    .onChange(of: self.chatManager.messages) { oldValue, newValue in
                        self.handleMessagesChange(old: oldValue, new: newValue)
                    }
                    .onChange(of: self.chatManager.isSending) { _, _ in
                        self.reapplyPinIfNeeded()
                    }
                }

                ChatComposerView(
                    draft: self.$draft,
                    focus: self.$isComposerFocused,
                    onSend: self.handleSend
                )
            }
            .navigationTitle(SourceVocabulary.chatNavTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("chat.surface")
        .task {
            self.isComposerFocused = true
        }
        .onChange(of: self.chatManager.lastError) { _, newValue in
            if newValue != nil {
                ChatHaptics.error()
            }
        }
    }
}

private extension ChatView {
    var offlineBanner: some View {
        Text(SourceVocabulary.chatOfflineBanner)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
    }

    func handleMessagesChange(old: [ChatMessage], new: [ChatMessage]) {
        if let pinned = self.pinnedMessageID {
            if new.contains(where: { $0.id == pinned }) {
                self.reapplyPinIfNeeded()
            } else {
                self.pinnedMessageID = nil
            }
        }
        guard !self.userIsDragging, !self.userIsBrowsing else { return }
        guard let last = new.last, last.role == .user else { return }
        let oldIDs = Set(old.map(\.id))
        guard !oldIDs.contains(last.id) else { return }
        self.pinnedMessageID = last.id
        self.scrollToPin(animated: !self.reduceMotion)
    }

    func reapplyPinIfNeeded() {
        guard let pinned = self.pinnedMessageID, !self.userIsDragging, !self.userIsBrowsing else { return }
        guard self.chatManager.messages.contains(where: { $0.id == pinned }) else {
            self.pinnedMessageID = nil
            return
        }
        self.scrollToPin(animated: false)
    }

    func scrollToPin(animated: Bool) {
        guard let pinned = self.pinnedMessageID else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.scrollPosition.scrollTo(id: pinned, anchor: .top)
            }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                self.scrollPosition.scrollTo(id: pinned, anchor: .top)
            }
        }
    }

    func handleSend() {
        let text = self.draft
        self.draft = ""
        self.userIsBrowsing = false
        self.isComposerFocused = true
        Task {
            await self.chatManager.send(text)
        }
    }
}

private struct BubbleView: View {
    let message: ChatMessage

    private var alignment: HorizontalAlignment {
        switch self.message.role {
        case .user:
            .trailing
        case .assistant:
            .leading
        }
    }

    private var rowAlignment: Alignment {
        switch self.message.role {
        case .user:
            .trailing
        case .assistant:
            .leading
        }
    }

    private var bubbleBackground: Color {
        switch self.message.role {
        case .user:
            Color.solOrange.opacity(0.18)
        case .assistant:
            Color(.secondarySystemBackground)
        }
    }

    var body: some View {
        VStack(alignment: self.alignment, spacing: 0) {
            self.bubbleContent
        }
        .frame(maxWidth: .infinity, alignment: self.rowAlignment)
    }

    private var bubbleContent: some View {
        HStack(spacing: 6) {
            if self.message.status == .pending {
                Image(systemName: "clock")
                    .font(.caption)
                    .accessibilityLabel(SourceVocabulary.chatPendingStatusA11y)
            } else if self.message.status == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(SourceVocabulary.chatFailedStatusA11y)
            }
            if self.message.role == .assistant {
                AssistantBubble(message: self.message)
            } else {
                Text(self.message.text)
            }
        }
        .foregroundStyle(.primary)
        .padding(10)
        .background(self.bubbleBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
