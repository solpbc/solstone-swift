// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ImporterSourceDetailView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var refreshToken = UUID()
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteResult: DeleteShareSourceResult?

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

                SourceDetailBlock(title: SourceVocabulary.onThisPhone) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SourceVocabulary.onThisPhoneScope)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        NavigationLink(SourceVocabulary.journalDashboardTitle) {
                            OnThisPhoneView()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                SourceDetailBlock(title: SourceVocabulary.delete) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(SourceVocabulary.deleteConfirmButton, role: .destructive) {
                            self.showingDeleteConfirm = true
                        }
                            .buttonStyle(.bordered)
                            .disabled(self.isDeleting)

                        self.deleteResultBlock
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(self.source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert(SourceVocabulary.deleteConfirmButton, isPresented: self.$showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(SourceVocabulary.deleteConfirmButton, role: .destructive) {
                Task {
                    await self.runDelete()
                }
            }
        } message: {
            Text(SourceVocabulary.deleteConfirmBody)
        }
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

    @ViewBuilder
    var deleteResultBlock: some View {
        if let deleteResult {
            switch deleteResult {
            case .confirmed(let receipt, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text(SourceVocabulary.deleteReceiptHeadline(originals: receipt.removed.originals))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(SourceVocabulary.deleteSourceOffLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(deleteResult.notRemovedIssues, id: \.self) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.what)
                            Text(issue.plainReason)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(deleteResult.notConfirmedIssues, id: \.self) { issue in
                        Text(issue.plainReason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            case .notConfirmed, .unreachable:
                Text(SourceVocabulary.deleteJournalUnreachableLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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

    func runDelete() async {
        self.isDeleting = true
        defer {
            self.isDeleting = false
        }

        let result = await self.importQueue.deleteShareSource()
        if result.shouldFlipOff {
            self.appGroupMirror.setShareActivated(false)
            self.appGroupMirror.setSharePaused(false)
        }
        self.deleteResult = result
        self.refreshToken = UUID()
    }
}
