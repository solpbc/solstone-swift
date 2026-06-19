import SwiftUI

struct ChatComposerView: View {
    @Binding var draft: String
    let focus: FocusState<Bool>.Binding
    let onSend: () -> Void

    @Environment(ChatManager.self) private var chatManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bannerFlash = false
    @State private var lastBannerError: String?
    @State private var shiftReturnJustInserted = false
    @State private var showingTalentDetail = false
    @State private var elapsedModel = ComposerTalentElapsedModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = self.chatManager.lastError {
                HStack(spacing: 10) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if self.chatManager.answerRetryText != nil {
                        Button(SourceVocabulary.chatRetryAnswer) {
                            Task {
                                await self.chatManager.retryAnswer()
                            }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .onTapGesture {
                    if self.chatManager.answerRetryText == nil {
                        self.chatManager.lastError = nil
                    }
                }
                .scaleEffect(self.bannerFlash ? 1.02 : 1)
                .opacity(self.bannerFlash ? 1 : 0.9)
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField(SourceVocabulary.chatComposerPlaceholder, text: self.$draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused(self.focus)
                    .submitLabel(.send)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            self.shiftReturnJustInserted = true
                            return .ignored  // hardware keyboard: let \n be inserted for newline
                        }
                        guard self.canSend else { return .handled }
                        ChatHaptics.send()
                        self.onSend()
                        return .handled
                    }
                    .onChange(of: self.draft) { oldValue, newValue in
                        guard ChatSendDecision.isReturnSend(
                            old: oldValue,
                            new: newValue,
                            shiftJustInserted: &self.shiftReturnJustInserted
                        ) else { return }
                        self.draft = oldValue
                        guard self.canSend else { return }
                        ChatHaptics.send()
                        self.onSend()
                    }

                ComposerSolMark(
                    isBusy: self.chatManager.hasTalentWork,
                    reduceMotion: self.reduceMotion,
                    action: {
                        self.showingTalentDetail = true
                    }
                )

                Button {
                    ChatHaptics.send()
                    self.onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .opacity(self.canSend ? 1 : 0.35)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!self.canSend)
                .accessibilityLabel(SourceVocabulary.chatSendA11y)
            }
        }
        .padding(16)
        .background(.bar)
        .onChange(of: self.chatManager.lastError) { _, newValue in
            self.handleBannerChange(newValue)
        }
        .onChange(of: self.chatManager.hasTalentWork) { _, _ in
            self.syncElapsedTick()
        }
        .onChange(of: self.reduceMotion) { _, _ in
            self.syncElapsedTick()
        }
        .task {
            self.syncElapsedTick()
        }
        .onDisappear {
            self.elapsedModel.stop()
        }
        .sheet(isPresented: self.$showingTalentDetail) {
            TalentWorkDetailSheet(
                running: self.chatManager.runningTalents,
                queued: self.chatManager.queuedTalents,
                now: self.elapsedModel.now
            )
        }
    }
}

private extension ChatComposerView {
    var canSend: Bool {
        ChatSendDecision.canSend(self.draft)
    }

    func handleBannerChange(_ newValue: String?) {
        guard newValue != self.lastBannerError, newValue != nil, !self.reduceMotion else {
            self.lastBannerError = newValue
            return
        }

        self.bannerFlash = true
        self.lastBannerError = newValue
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            self.bannerFlash = false
        }
    }

    func syncElapsedTick() {
        self.elapsedModel.update(isBusy: self.chatManager.hasTalentWork, reduceMotion: self.reduceMotion)
    }
}
