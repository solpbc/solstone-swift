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

                if self.chatManager.messages.isEmpty
                    && !self.chatManager.isSending
                    && self.chatManager.activeTrace == nil
                    && self.chatManager.pendingOffer == nil
                    && self.chatManager.pendingDraft == nil
                {
                    ChatEmptyState()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(self.chatManager.messages) { message in
                                BubbleView(
                                    message: message,
                                    foldAnchor: self.foldAnchorPlacement(for: message),
                                    onFoldAnchorTap: { id in
                                        self.scrollToMessage(id: id, animated: !self.reduceMotion)
                                    }
                                )
                                    .id(message.id)
                            }

                            if let trace = self.chatManager.activeTrace {
                                WorkingTraceView(trace: trace)
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

                self.queueCapacityLine
                self.supportSurface

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

    @ViewBuilder
    var queueCapacityLine: some View {
        if let count = self.chatManager.queueDepth, count > 0 {
            Text(SourceVocabulary.chatQueueCapacityLine(count: count))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .accessibilityIdentifier("chat.queueDepth")
        }
    }

    @ViewBuilder
    var supportSurface: some View {
        if self.chatManager.pendingOffer != nil || self.chatManager.pendingDraft != nil {
            VStack(alignment: .leading, spacing: 10) {
                SupportCapacityLine()

                if let offer = self.chatManager.pendingOffer {
                    SupportOfferView(
                        offer: offer,
                        onAccept: self.handleOfferAccept,
                        onDecline: self.handleOfferDecline
                    )
                }

                if let draft = self.chatManager.pendingDraft {
                    DraftReviewCard(
                        draft: draft,
                        onConfirm: {
                            self.handleDraftConfirm(draft)
                        },
                        onCancel: {
                            self.handleDraftCancel(draft)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.blue.opacity(0.10))
            .accessibilityIdentifier("chat.supportSurface")
        }
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
        self.scrollToMessage(id: pinned, animated: animated)
    }

    func scrollToMessage(id: UUID, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.scrollPosition.scrollTo(id: id, anchor: .top)
            }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                self.scrollPosition.scrollTo(id: id, anchor: .top)
            }
        }
    }

    func foldAnchorPlacement(for message: ChatMessage) -> FoldAnchorPlacement? {
        guard let origin = message.origin else { return nil }
        return FoldAnchor.resolve(origin: origin, messages: self.chatManager.messages)
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

    func handleOfferAccept() {
        self.chatManager.acceptOffer()
    }

    func handleOfferDecline() {
        Task {
            await self.chatManager.declineOffer()
        }
    }

    func handleDraftConfirm(_ draft: ChatDraft) {
        Task {
            await self.chatManager.confirmDraft(id: draft.id)
        }
    }

    func handleDraftCancel(_ draft: ChatDraft) {
        Task {
            await self.chatManager.cancelDraft(id: draft.id)
        }
    }
}

private struct BubbleView: View {
    let message: ChatMessage
    let foldAnchor: FoldAnchorPlacement?
    let onFoldAnchorTap: (UUID) -> Void

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
                VStack(alignment: .leading, spacing: 8) {
                    if let foldAnchor {
                        FoldAnchorView(placement: foldAnchor, onTap: self.onFoldAnchorTap)
                    }
                    AssistantBubble(message: self.message)
                }
            } else {
                Text(self.message.text)
            }
        }
        .foregroundStyle(.primary)
        .padding(10)
        .background(self.bubbleBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: self.message.provenance == nil ? .combine : .contain)
    }
}

private struct FoldAnchorView: View {
    let placement: FoldAnchorPlacement
    let onTap: (UUID) -> Void

    var body: some View {
        switch self.placement {
        case .anchored(let id):
            Button {
                self.onTap(id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.caption2.weight(.semibold))
                    Text(SourceVocabulary.chatFoldAnchorTitle)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .inlineAsk(let ask):
            VStack(alignment: .leading, spacing: 2) {
                Text(SourceVocabulary.chatFoldInlineAskPrefix)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(ask)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkingTraceView: View {
    let trace: ChatWorkingTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(self.trace.activeLabels, id: \.self) { label in
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(self.trace.erroredLabels, id: \.self) { label in
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.workingTrace")
    }
}

private struct SupportCapacityLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(SourceVocabulary.chatSupportCapacityFrom)
                Spacer(minLength: 8)
                Text(SourceVocabulary.chatSupportCapacityTo)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)

            Text(SourceVocabulary.chatSupportCapacitySub)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("chat.supportCapacity")
    }
}

private struct SupportOfferView: View {
    let offer: ChatOffer
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !self.offer.text.isEmpty {
                Text(self.offer.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 8) {
                Button(SourceVocabulary.chatOfferYes, action: self.onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(SourceVocabulary.chatOfferNo, action: self.onDecline)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityIdentifier("chat.offer")
    }
}

private struct DraftReviewCard: View {
    let draft: ChatDraft
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SourceVocabulary.chatDraftReviewTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)

            Text(self.draft.body)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(self.draft.fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(field.value)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }

            if self.draft.diagnosticsIncluded {
                Text(SourceVocabulary.chatDraftDiagnosticsIncluded)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(SourceVocabulary.chatDraftConfirm, action: self.onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(SourceVocabulary.chatDraftCancel, action: self.onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("chat.draft")
    }
}
