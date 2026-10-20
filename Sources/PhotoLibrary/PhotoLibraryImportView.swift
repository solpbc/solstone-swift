// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Photos
import SwiftUI
import UIKit

/// The photo library screen, pushed from import: photo access, the scope the owner chooses,
/// the import while it runs, and what recently came in from Photos with what the journal has
/// done with it.
struct PhotoLibraryImportView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(PhotoLibraryImporter.self) private var importer
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(ShareImportStore.self) private var shareImportStore
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var album: PhotoLibraryAlbum = .all
    @State private var from: Date = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var albums: [PhotoLibraryAlbum] = [.all, .favorites, .screenshots]
    @State private var preview: PhotoLibraryPreview?
    @State private var contributions: [PhotoContribution] = []
    @State private var isConfirmingStop = false

    private let statusReader = PhotoProcessingStatusReader()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: SourceVocabulary.whatItAddsTitle) {
                    VStack(alignment: .leading, spacing: 8) {
                        self.secondary(PhotoLibraryVocabulary.whatItAdds)
                        self.secondary(PhotoLibraryVocabulary.photosOnly)
                        self.secondary(PhotoLibraryVocabulary.processingDisclosure)
                            .accessibilityIdentifier("photoLibrary.disclosure")
                    }
                }

                SourceDetailBlock(title: PhotoLibraryVocabulary.accessTitle) {
                    self.accessBlock
                }

                if let batch = self.importer.latest, !batch.state.isEnded {
                    SourceDetailBlock(title: PhotoLibraryVocabulary.thisImportTitle) {
                        self.progressBlock(batch)
                    }
                } else {
                    if self.importer.access.canRead {
                        SourceDetailBlock(title: PhotoLibraryVocabulary.chooseTitle) {
                            self.chooseBlock
                        }
                    }
                    if let batch = self.importer.latest {
                        SourceDetailBlock(title: PhotoLibraryVocabulary.lastImportTitle) {
                            self.endedBlock(batch)
                        }
                    }
                }

                SourceDetailBlock(title: PhotoLibraryVocabulary.recentTitle) {
                    self.recentBlock
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding(ShellMetrics.screenMargin)
            .frame(maxWidth: .infinity)
        }
        .background(Color.deckGround.ignoresSafeArea())
        .navigationTitle(PhotoLibraryVocabulary.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shell.pane.photoLibrary")
        .onAppear {
            self.importer.refreshAccess()
            self.albums = self.importer.albums()
        }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active else { return }
            self.importer.refreshAccess()
            self.albums = self.importer.albums()
        }
        .onChange(of: self.importer.access) { _, _ in
            self.albums = self.importer.albums()
        }
        .onChange(of: self.importer.libraryRevision) { _, _ in
            self.albums = self.importer.albums()
        }
        .task(id: self.previewKey) {
            self.preview = self.importer.access.canRead ? self.importer.preview(self.scope) : nil
        }
        .task(id: self.recentKey) {
            await self.pollRecent()
        }
        .alert(PhotoLibraryVocabulary.stopConfirmTitle, isPresented: self.$isConfirmingStop) {
            Button(PhotoLibraryVocabulary.stop, role: .destructive) {
                self.importer.stop()
            }
            Button(PhotoLibraryVocabulary.stopConfirmKeepGoing, role: .cancel) {}
        } message: {
            Text(PhotoLibraryVocabulary.stopConfirmMessage(remaining: self.importer.latest?.remaining ?? 0))
        }
    }

    private var scope: PhotoLibraryScope {
        PhotoLibraryScope.days(album: self.album, from: self.from, to: self.to)
    }

    private var previewKey: String {
        let scope = self.scope
        return "\(scope.album.id)|\(scope.from.timeIntervalSince1970)|\(scope.to.timeIntervalSince1970)|\(self.importer.access)|\(self.importer.latest?.id.uuidString ?? "")|\(self.importer.latest?.state.rawValue ?? "")|\(self.importer.libraryRevision)"
    }

    private var recentKey: String {
        "\(self.importer.latest?.broughtIn ?? 0)|\(self.tunnelManager.activeConnection?.port ?? 0)"
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: access

    @ViewBuilder
    private var accessBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch self.importer.access {
            case .notAsked:
                self.secondary(PhotoLibraryVocabulary.accessNotAsked)
                self.actionButton(PhotoLibraryVocabulary.accessAsk, hint: PhotoLibraryVocabulary.accessAskHint, id: "photoLibrary.allowAccess", prominent: true) {
                    Task { await self.importer.requestAccess() }
                }
            case .all:
                Text(PhotoLibraryVocabulary.accessAll)
                    .font(.headline)
                    .accessibilityIdentifier("photoLibrary.access")
            case .selected:
                Text(PhotoLibraryVocabulary.accessSelected)
                    .font(.headline)
                    .accessibilityIdentifier("photoLibrary.access")
                self.secondary(PhotoLibraryVocabulary.accessSelectedLine)
                self.actionButton(PhotoLibraryVocabulary.accessPickMore, hint: PhotoLibraryVocabulary.accessPickMoreHint, id: "photoLibrary.pickMore", prominent: false) {
                    LimitedLibraryPicker.present()
                }
            case .off:
                Text(PhotoLibraryVocabulary.accessOff)
                    .font(.headline)
                    .accessibilityIdentifier("photoLibrary.access")
                self.secondary(PhotoLibraryVocabulary.accessOffLine)
                self.actionButton(SourceVocabulary.openSettings, hint: PhotoLibraryVocabulary.accessOpenSettingsHint, id: "photoLibrary.openSettings", prominent: true) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            case .unavailable:
                Text(PhotoLibraryVocabulary.accessUnavailable)
                    .font(.headline)
                    .accessibilityIdentifier("photoLibrary.access")
            }
        }
    }

    // MARK: choosing

    @ViewBuilder
    private var chooseBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(PhotoLibraryVocabulary.albumLabel, selection: self.$album) {
                ForEach(self.albums) { album in
                    Text(PhotoLibraryVocabulary.albumName(album)).tag(album)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("photoLibrary.album")

            DatePicker(PhotoLibraryVocabulary.fromLabel, selection: self.$from, in: ...Date(), displayedComponents: .date)
                .frame(minHeight: 44)
                .accessibilityIdentifier("photoLibrary.from")
            DatePicker(PhotoLibraryVocabulary.toLabel, selection: self.$to, in: ...Date(), displayedComponents: .date)
                .frame(minHeight: 44)
                .accessibilityIdentifier("photoLibrary.to")

            if let preview = self.preview {
                self.previewLines(preview)
            }
        }
    }

    @ViewBuilder
    private func previewLines(_ preview: PhotoLibraryPreview) -> some View {
        let count = preview.assetIDs.count
        if count == 0 {
            self.secondary(preview.alreadyIn > 0 ? PhotoLibraryVocabulary.countNoneNew : PhotoLibraryVocabulary.countNone)
                .accessibilityIdentifier("photoLibrary.count")
        } else {
            Text(PhotoLibraryVocabulary.photos(count))
                .font(.headline)
                .accessibilityIdentifier("photoLibrary.count")
            if preview.alreadyIn > 0 {
                self.secondary(PhotoLibraryVocabulary.alreadyIn(preview.alreadyIn))
            }
            self.actionButton(PhotoLibraryVocabulary.start(count), hint: PhotoLibraryVocabulary.startHint, id: "photoLibrary.start", prominent: true) {
                self.importer.start(self.scope, assetIDs: preview.assetIDs)
            }
        }
    }

    // MARK: the import

    @ViewBuilder
    private func progressBlock(_ batch: PhotoLibraryBatch) -> some View {
        let album = PhotoLibraryVocabulary.albumName(batch.scope.album)
        let range = PhotoLibraryVocabulary.range(batch.scope)
        VStack(alignment: .leading, spacing: 10) {
            switch batch.state {
            case .running:
                Text(PhotoLibraryVocabulary.running(album: album, range: range))
                    .font(.headline)
                    .accessibilityIdentifier("photoLibrary.state")
                self.secondary(PhotoLibraryVocabulary.stillToCome(batch.remaining))
                    .accessibilityIdentifier("photoLibrary.remaining")
                // Photos still going out on a live connection is ordinary progress; the line is
                // only for a journal this device cannot reach right now.
                if self.importer.isWaitingForJournal,
                   !self.appConfig.isPaired || self.tunnelManager.activeConnection == nil {
                    self.secondary(PhotoLibraryVocabulary.waitingForJournal(isJournalPaired: self.appConfig.isPaired))
                }
                self.actionButton(PhotoLibraryVocabulary.pause, hint: PhotoLibraryVocabulary.pauseHint, id: "photoLibrary.pause", prominent: false) {
                    self.importer.pause()
                }
            case .paused, .pausedForAccess, .pausedForSpace:
                Text(SourceState.paused.label)
                    .font(.headline)
                    .accessibilityIdentifier("photoLibrary.state")
                self.secondary(self.pausedLine(batch.state))
                self.secondary(PhotoLibraryVocabulary.stillToCome(batch.remaining))
                    .accessibilityIdentifier("photoLibrary.remaining")
                if batch.state != .pausedForAccess {
                    self.actionButton(PhotoLibraryVocabulary.resume, hint: PhotoLibraryVocabulary.resumeHint, id: "photoLibrary.resume", prominent: true) {
                        self.importer.resume()
                    }
                }
                self.actionButton(PhotoLibraryVocabulary.stop, hint: PhotoLibraryVocabulary.stopHint, id: "photoLibrary.stop", prominent: false, role: .destructive) {
                    self.isConfirmingStop = true
                }
            case .stopped, .finished:
                EmptyView()
            }
        }
    }

    private func pausedLine(_ state: PhotoLibraryBatchState) -> String {
        switch state {
        case .pausedForAccess:
            PhotoLibraryVocabulary.pausedForAccessLine
        case .pausedForSpace:
            PhotoLibraryVocabulary.pausedForSpaceLine
        default:
            PhotoLibraryVocabulary.pausedLine
        }
    }

    @ViewBuilder
    private func endedBlock(_ batch: PhotoLibraryBatch) -> some View {
        let album = PhotoLibraryVocabulary.albumName(batch.scope.album)
        let range = PhotoLibraryVocabulary.range(batch.scope)
        let when = (batch.endedAt ?? batch.startedAt).formatted(date: .abbreviated, time: .shortened).lowercased()
        VStack(alignment: .leading, spacing: 8) {
            self.secondary(batch.state == .stopped
                ? PhotoLibraryVocabulary.lastImportStopped(count: batch.broughtIn, album: album, range: range, when: when)
                : PhotoLibraryVocabulary.lastImportFinished(count: batch.broughtIn, album: album, range: range, when: when))
                .accessibilityIdentifier("photoLibrary.lastImport")
            if !batch.unreadable.isEmpty {
                self.secondary(PhotoLibraryVocabulary.unreadable(batch.unreadable.count))
            }
        }
    }

    // MARK: recent

    @ViewBuilder
    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.contributions.isEmpty {
                self.secondary(PhotoLibraryVocabulary.recentEmpty)
            } else {
                ForEach(self.contributions) { contribution in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contribution.filename ?? PhotoLibraryVocabulary.photos(1))
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(PhotoLibraryVocabulary.status(for: contribution))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("photoLibrary.recent.status")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("photoLibrary.recent.\(contribution.id)")
                }
            }
            self.secondary(PhotoLibraryVocabulary.removalLine)
        }
    }

    private func pollRecent() async {
        var statuses: [String: PhotoProcessingStatus] = [:]
        while !Task.isCancelled {
            let snapshot = await self.shareTransferHolder.onThisPhoneSourceSnapshot()
            let items: [OnThisPhoneItem]
            if case .loaded(let loaded) = snapshot {
                items = loaded
            } else {
                items = []
            }
            let ledger = (try? self.shareImportStore.loadLedger()) ?? [:]
            var recent = PhotoContribution.recent(items: items, ledger: ledger)
            if let port = self.tunnelManager.activeConnection?.port {
                for index in recent.indices {
                    guard let importID = recent[index].importID else { continue }
                    if let known = statuses[importID], known.isSettled {
                        recent[index].processing = known
                        continue
                    }
                    if let status = await self.statusReader.fetch(localPort: port, importID: importID) {
                        statuses[importID] = status
                    }
                    recent[index].processing = statuses[importID]
                }
            } else {
                for index in recent.indices {
                    recent[index].processing = recent[index].importID.flatMap { statuses[$0] }
                }
            }
            self.contributions = recent
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: controls

    private func actionButton(
        _ title: String,
        hint: String,
        id: String,
        prominent: Bool,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(title, role: role, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, role: role, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }
}

/// iOS's own sheet for changing which photos the app can see, under selected-photos access.
@MainActor
enum LimitedLibraryPicker {
    static func present() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}
