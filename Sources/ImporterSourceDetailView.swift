// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ImporterSourceDetailView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var refreshToken = UUID()

    let source: Source
    private let appGroupMirror = AppGroupMirror()

    init(source: Source) {
        self.source = source
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: "state") {
                    self.stateBlock
                }

                SourceDetailBlock(title: "what it adds") {
                    Text(SourceVocabulary.importerWhatItAdds)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                SourceDetailBlock(title: "recent") {
                    self.recentBlock
                }

                SourceDetailBlock(title: SourceVocabulary.validate) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(SourceVocabulary.validate) {}
                            .buttonStyle(.bordered)
                            .disabled(true)

                        Text(SourceVocabulary.validateSeam)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                SourceDetailBlock(title: SourceVocabulary.delete) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(SourceVocabulary.delete) {}
                            .buttonStyle(.bordered)
                            .disabled(true)

                        Text(SourceVocabulary.deleteSeam)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(self.source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            self.refreshToken = UUID()
        }
    }
}

private extension ImporterSourceDetailView {
    @ViewBuilder
    var stateBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: self.currentState.symbol)
                Text(self.currentState.label)
            }
            .font(.headline)

            LabeledContent("pending", value: "\(self.importQueue.pendingCount)")
            LabeledContent("failed", value: "\(self.importQueue.failedCount)")

            Button(self.stateActionLabel) {
                self.handleStateAction()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    var recentBlock: some View {
        if self.importQueue.pendingCount > 0 {
            Text(SourceVocabulary.shareSendingProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if self.importQueue.lastDeliveredAt != nil {
            Text(SourceVocabulary.shareDeliveredProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if self.importQueue.failedCount > 0 {
            Text(SourceVocabulary.needsAttentionSubtext)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text(SourceVocabulary.recentEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    var currentState: SourceState {
        importerSourceState(shareState: self.currentShareSourceState, failedCount: self.importQueue.failedCount)
    }

    var currentShareSourceState: AppGroupMirror.ShareSourceState {
        _ = self.refreshToken
        return self.appGroupMirror.shareSourceState()
    }

    var stateActionLabel: String {
        switch self.currentState {
        case .off:
            SourceVocabulary.turnOn
        case .paused:
            SourceVocabulary.resume
        case .active, .needsAttention, .enrolling:
            SourceVocabulary.pause
        }
    }

    func handleStateAction() {
        switch self.currentState {
        case .off:
            self.appGroupMirror.activateShareSource()
        case .paused:
            self.appGroupMirror.setSharePaused(false)
        case .active, .needsAttention, .enrolling:
            self.appGroupMirror.setSharePaused(true)
        }
        self.refreshToken = UUID()
    }
}
