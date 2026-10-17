// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ImportView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ConnectionStallMonitor.self) private var connectionStallMonitor
    @Environment(ShareImportStore.self) private var shareImportStore
    @Environment(ForegroundDrainGate.self) private var foregroundDrainGate
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var isDropTargeted = false
    @State private var intake: Intake = .idle

    private enum Intake: Equatable {
        case idle
        case working
        case finished(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: SourceVocabulary.whatItAddsTitle) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SourceVocabulary.importerWhatItAdds)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        // The pickers are the way in; a drop onto this pane is the shortcut, never the only path.
                        self.pickRow(
                            title: SourceVocabulary.importPhotosRow,
                            systemImage: "photo.on.rectangle",
                            hint: SourceVocabulary.importPhotosHint,
                            identifier: "import.pickPhotos"
                        ) {
                            self.isPickingPhotos = true
                        }
                        self.pickRow(
                            title: SourceVocabulary.importFilesRow,
                            systemImage: "folder",
                            hint: SourceVocabulary.importFilesHint,
                            identifier: "import.pickFiles"
                        ) {
                            self.isPickingFiles = true
                        }
                        self.intakeLine
                    }
                }

                SourceDetailBlock(title: "recent") {
                    Text(ImportRecentPresentation.recentText(
                        pendingCount: self.shareTransferHolder.pendingCount,
                        lastDeliveredAt: self.shareTransferHolder.lastUploadAt,
                        failedCount: self.shareTransferHolder.failedCount,
                        awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation,
                        connectionStatus: self.connectionSyncModel.status,
                        isStalled: self.connectionStallMonitor.isStalled
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                SourceDetailBlock(title: SourceVocabulary.onThisPhone) {
                    VStack(alignment: .leading, spacing: 8) {
                        let showsAwaiting = MarkConfirmationDisplay.showsAwaitingWords(
                            awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation,
                            status: self.connectionSyncModel.status,
                            isStalled: self.connectionStallMonitor.isStalled
                        )
                        if !showsAwaiting {
                            Text(SourceVocabulary.onThisPhoneScope(
                                isJournalPaired: self.appConfig.isPaired,
                                isConnected: self.tunnelManager.state.isConnected
                            ))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // The action names what it opens rather than restating the
                        // heading it sits under: a button reading `on this device`
                        // inside a block titled `on this device` says nothing twice.
                        NavigationLink {
                            OnThisPhoneView()
                        } label: {
                            HStack {
                                Text(SourceVocabulary.onThisPhoneOpenAction)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel(SourceVocabulary.onThisPhoneOpenAction)
                        .accessibilityIdentifier("import.onThisDeviceEntry")
                        .accessibilityHint("Shows what you've sent to your journal.")
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding(ShellMetrics.screenMargin)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if self.isDropTargeted {
                ShellMetrics.cardShape
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: InAppImport.acceptedContentTypes, isTargeted: self.$isDropTargeted) { providers in
            guard self.intake != .working else { return false }
            self.take { queue in
                await InAppImport.accept(itemProviders: providers, queue: queue)
            }
            return true
        }
        .sheet(isPresented: self.$isPickingPhotos) {
            SystemPhotoPicker { providers in
                self.isPickingPhotos = false
                guard !providers.isEmpty else { return }
                self.take { queue in
                    await InAppImport.accept(itemProviders: providers, queue: queue)
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: self.$isPickingFiles,
            allowedContentTypes: InAppImport.acceptedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                self.take { queue in
                    await InAppImport.accept(fileURLs: urls, queue: queue)
                }
            case .failure:
                self.finish(ShareImportFailure.unreadable.message)
            }
        }
        .background(Color.deckGround.ignoresSafeArea())
        .navigationTitle(SourceVocabulary.importTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shell.pane.import")
    }

    private func pickRow(
        title: String,
        systemImage: String,
        hint: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .disabled(self.intake == .working)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var intakeLine: some View {
        switch self.intake {
        case .idle:
            EmptyView()
        case .working:
            ProgressView()
                .accessibilityLabel(String(localized: SourceVocabulary.shareSendingProgress))
                .accessibilityIdentifier("import.intake.working")
        case .finished(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("import.intake.outcome")
        }
    }

    /// Lands the items through the share route, says how it went, then wakes the same drain a
    /// share does when the app comes forward, so the items move on toward the journal.
    private func take(_ accept: @escaping (ShareImportStore) async -> [ShareImportResult]) {
        self.intake = .working
        let queue = self.shareImportStore
        let drainGate = self.foregroundDrainGate
        Task {
            let results = await accept(queue)
            if let text = InAppImport.outcomeText(for: results) {
                self.finish(text)
            } else {
                self.intake = .idle
            }
            await drainGate.requestDrain()
        }
    }

    private func finish(_ text: String) {
        self.intake = .finished(text)
        AccessibilityNotification.Announcement(text).post()
    }
}
