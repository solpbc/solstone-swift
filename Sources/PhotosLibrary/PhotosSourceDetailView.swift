// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

#if SOLSTONE_PHOTOS_LIBRARY
struct PhotosSourceDetailView: View {
    @Environment(PhotosLibrarySourceHandle.self) private var handle

    var body: some View {
        PhotosLibraryPage(source: self.handle.source)
    }
}

private struct PhotosLibraryPage: View {
    private static let journalPhotosPath = "/app/sources/photos"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(PendingJournalOpenState.self) private var pendingJournalOpen: PendingJournalOpenState?

    let source: PhotosLibraryEngine

    var body: some View {
        let view = self.source.viewState(locale: self.locale)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.stateBlock(view)

                Text(PhotosVocabulary.whatItTakesIn)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.deckSurface, in: ShellMetrics.cardShape)
                    .accessibilityIdentifier("photos.page.valueLine")

                self.primarySection(view)

                if view.showsOpenJournalDoor {
                    Button(PhotosVocabulary.openInJournal) {
                        self.pendingJournalOpen?.open(path: Self.journalPhotosPath)
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("photos.openJournal")
                }

                Text(PhotosVocabulary.honestyLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photos.page.honesty")

                self.factsBlock
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("photos.page")
        .navigationTitle(PhotosVocabulary.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { await self.source.foreground() }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await self.source.foreground() }
        }
    }

    @ViewBuilder
    private func stateBlock(_ view: PhotosLibraryViewState) -> some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            VStack(alignment: .leading, spacing: 12) {
                SourceDetailVerdictLine(state: view.sourceState)
                if let subline = view.pageSubline {
                    Text(subline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("photos.page.subline")
                }
                if let reason = view.pageReason {
                    SourceDetailReasonLine(message: reason)
                        .accessibilityIdentifier("photos.page.reason")
                    if view.primaryAction == .openSettings {
                        Button(SourceVocabulary.openSettings) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(BrandProminentButtonStyle())
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("photos.openSettings")
                    }
                }
                if view.showsWaitingForJournalUpdate {
                    SourceDetailReasonLine(message: PhotosVocabulary.waitingForJournalUpdate)
                        .accessibilityIdentifier("photos.page.journalUpdate")
                }
                if view.showsPauseResume {
                    Button(view.isPaused ? SourceVocabulary.resume : SourceVocabulary.pause) {
                        Task {
                            if view.isPaused {
                                await self.source.resume()
                            } else {
                                await self.source.pauseWithJournalSync()
                            }
                        }
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("photos.pause")
                }
            }
        }
    }

    @ViewBuilder
    private func primarySection(_ view: PhotosLibraryViewState) -> some View {
        if view.showsAlreadyGrantedLine {
            Text(PhotosVocabulary.alreadyGranted)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("photos.page.alreadyGranted")
        }
        switch view.primaryAction {
        case .none:
            EmptyView()
        case .turnOn:
            Button(PhotosVocabulary.turnOn) {
                Task { _ = await self.source.enableAndScan() }
            }
            .buttonStyle(BrandProminentButtonStyle())
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityHint(PhotosVocabulary.turnOnHint)
            .accessibilityIdentifier("photos.turnOn")
        case .scanLibrary:
            Button(PhotosVocabulary.scanYourLibrary) {
                Task { _ = await self.source.enableAndScan() }
            }
            .buttonStyle(BrandProminentButtonStyle())
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityHint(PhotosVocabulary.scanYourLibraryHint)
            .accessibilityIdentifier("photos.scanLibrary")
        case .chooseInJournal:
            Button(PhotosVocabulary.chooseWhatComesIn) {
                self.pendingJournalOpen?.open(path: Self.journalPhotosPath)
            }
            .buttonStyle(BrandProminentButtonStyle())
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("photos.chooseInJournal")
        case .openSettings:
            EmptyView()
        }
    }

    @ViewBuilder
    private var factsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PhotosVocabulary.staysIfDeletedFromPhotos)
            Text(PhotosVocabulary.keepsWhatsIn)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("photos.page.facts")
        SourceIntakeFacts(source: .photos)
        SourceHomeTileControl(sourceID: PhotosLibraryWire.sourceKey)
    }
}
#endif
