// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourcesView: View {
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @Environment(ImportQueue.self) private var importQueue
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSourceRoute: SourceRoute?

    private let appGroupMirror = AppGroupMirror()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if self.showsZeroActiveSummary {
                        Text(SourceVocabulary.zeroActiveSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(SourceGroup.experiencingAlongsideYou.header)
                            .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))

                        SourceRowView(source: self.audioSource) {
                            self.selectedSourceRoute = .audio
                        }
                        SourceRowView(source: self.locationSource) {
                            self.selectedSourceRoute = .location
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(SourceGroup.bringingInYourself.header)
                            .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))

                        SourceRowView(source: self.shareSource) {
                            self.selectedSourceRoute = .share
                        }
                    }

                    Text(SourceVocabulary.trustLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("sources")
                        .font(.custom("Comfortaa-Bold", size: 22, relativeTo: .title2))
                }
            }
            .navigationDestination(item: self.$selectedSourceRoute) { route in
                switch route {
                case .audio:
                    SourceDetailView()
                case .location:
                    LocationSourceDetailView()
                case .share:
                    ImporterSourceDetailView(source: self.shareSource)
                }
            }
        }
    }
}

private enum SourceRoute: Hashable, Identifiable {
    case audio, location, share

    var id: String {
        switch self {
        case .audio: "audio"
        case .location: "location"
        case .share: "share"
        }
    }
}

private extension SourcesView {
    var audioSource: Source {
        let state = sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused)
        let attention: SourceAttention?
        if case .error(let error) = self.observerManager.state {
            attention = SourceAttention(message: error.message)
        } else {
            attention = nil
        }

        return Source(
            id: "audio",
            displayName: "audio",
            kind: .observer,
            group: .experiencingAlongsideYou,
            state: state,
            activeSubtext: SourceVocabulary.observerActiveSubtext,
            attention: attention,
            pendingStatus: .nonePending,
            isJournalConnected: self.observerRegistration.activeLocalPort != nil
        )
    }

    var showsZeroActiveSummary: Bool {
        [self.audioSource.state, self.shareSource.state, self.locationSource.state].allSatisfy(\.isZeroActive)
    }

    var shareSource: Source {
        let shareState = self.appGroupMirror.shareSourceState()
        let pairing = self.appGroupMirror.pairingSnapshot()
        return Source(
            id: "share-sheet",
            displayName: SourceVocabulary.shareSheetDisplayName,
            kind: .importer,
            group: .bringingInYourself,
            state: importerSourceState(shareState: shareState, failedCount: self.importQueue.failedCount),
            activeSubtext: importerActiveSubtext(
                pendingCount: self.importQueue.pendingCount,
                lastDeliveredAt: self.importQueue.lastDeliveredAt
            ),
            attention: self.importQueue.failedCount > 0 ? SourceAttention(message: SourceVocabulary.needsAttentionSubtext) : nil,
            pendingStatus: .nonePending,
            isJournalConnected: pairing.isPaired
        )
    }

    var locationSource: Source {
        Source(
            id: "location",
            displayName: LocationVocabulary.sourceDisplayName,
            kind: .location,
            group: .experiencingAlongsideYou,
            state: self.locationManager.sourceState,
            activeSubtext: LocationVocabulary.activeSubtext,
            attention: self.locationManager.sourceAttention,
            pendingStatus: .nonePending,
            isJournalConnected: self.observerRegistration.activeLocalPort != nil
        )
    }
}

private extension SourceState {
    var isZeroActive: Bool {
        switch self {
        case .off, .paused:
            true
        case .enrolling, .active, .needsAttention:
            false
        }
    }
}
