// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Configured folders list view (reached from the Home `folders` tile, `add more`, or `status`).
/// On iPhone, sits inside the single navigation stack; on iPad, sits inside the split detail column
/// beside the pinned 412pt Home deck and pushes `FolderDetailView` on top.
struct FoldersListView: View {
    @Environment(FoldersSourceHandle.self) private var handle
    @Environment(ShellNavModel.self) private var nav: ShellNavModel?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.pushShellDestination) private var pushShellDestination

    @State private var showingPicker = false
    @State private var now = Date()

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        let engine = self.handle.source
        let folders = engine.folders

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notice = engine.pickerNotice {
                    self.pickerNoticeCard(notice, engine: engine)
                }

                if folders.isEmpty {
                    self.emptyCard
                } else {
                    self.populatedList(folders: folders)
                }

                if !folders.isEmpty {
                    SourceIntakeFacts(source: .folders)
                }
                SourceHomeTileControl(sourceID: "folders")
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("folders.page")
        .navigationTitle(FoldersVocabulary.label)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: self.$showingPicker,
            allowedContentTypes: [UTType.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    if let folderID = await engine.handlePickedFolder(url: url) {
                        self.openFolder(id: folderID)
                    }
                }
            case .failure:
                break
            }
        }
        .task {
            await engine.refreshJournalMetadata()
        }
        .task {
            await refreshNowPeriodically { self.now = Date() }
        }
    }

    private func openFolder(id: String) {
        if let push = self.pushShellDestination {
            push(.folderDetail(id))
        } else {
            self.nav?.paneStack.append(.folderDetail(id))
        }
    }

    private var emptyCard: some View {
        SourceDetailBlock(title: FoldersVocabulary.label) {
            VStack(alignment: .leading, spacing: 12) {
                Text(FoldersVocabulary.intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(FoldersVocabulary.addFolder) {
                    self.handle.source.clearPickerNotice()
                    self.showingPicker = true
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("folders.addFolder")

                Text(FoldersVocabulary.pickerHelper(isPad: self.isPad))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("folders.pickerHelper")
            }
        }
    }

    private func populatedList(folders: [FolderRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 0)
                Button(FoldersVocabulary.addFolderPlus) {
                    self.handle.source.clearPickerNotice()
                    self.showingPicker = true
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("folders.addFolder")
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(folders) { folder in
                    Button {
                        self.openFolder(id: folder.id)
                    } label: {
                        self.folderRow(folder)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("folders.row.\(folder.id)")
                }
            }

            Text(FoldersVocabulary.pickerHelper(isPad: self.isPad))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("folders.pickerHelper")
        }
    }

    private func folderRow(_ folder: FolderRecord) -> some View {
        let state = FoldersEngine.stateForFolder(folder)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(state == .needsAttention ? Color.red : (state == .active || state == .enrolling ? Color.solOrangeAdaptive : .secondary))
                .frame(width: 26, height: 24, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(folder.name)
                        .font(ShellFont.tileName)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let facet = folder.facet {
                        FolderFacetChip(facet: facet)
                    }
                }

                HStack(spacing: 6) {
                    HomeSourceStateDot(state: state)
                    Text(state.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(state == .needsAttention ? Color.red : (state == .active || state == .enrolling ? .primary : .secondary))
                }

                if let subline = self.rowSubline(for: folder) {
                    Text(subline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(height: 24)
                .accessibilityHidden(true)
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(ShellMetrics.cardShape)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay {
            ShellMetrics.cardShape.stroke(
                state == .needsAttention ? Color.red.opacity(0.45) : Color.deckHairline,
                lineWidth: state == .needsAttention ? 1 : 0.5
            )
        }
    }

    private func rowSubline(for folder: FolderRecord) -> String? {
        if folder.mode != .off && folder.attention != nil {
            return FoldersVocabulary.attentionTile(folder: folder.name)
        }
        if folder.mode == .settingUp {
            return FoldersVocabulary.finishSetup(folder: folder.name)
        }
        if folder.mode == .on && folder.backfillTotal > 0 && folder.backfillDone < folder.backfillTotal {
            return FoldersVocabulary.pageProgress(done: folder.backfillDone, total: folder.backfillTotal)
        }
        if folder.mode == .on && !folder.pending.isEmpty {
            return FoldersVocabulary.waiting(folder.pending.count)
        }
        let itemsText = folder.itemsTakenIn > 0
            ? FoldersVocabulary.itemCount(folder.itemsTakenIn)
            : SourceIntakePhrases.nothingYet
        let stampMs = folder.lastTakenInMs ?? folder.lastCheckedMs
        if let stampMs {
            let date = Date(timeIntervalSince1970: Double(stampMs) / 1_000.0)
            let rel = SourceIntakeFormat.relative(date, now: self.now, calendar: .current)
            return FoldersVocabulary.rowSubline(items: itemsText, when: rel)
        }
        return itemsText
    }

    @ViewBuilder
    private func pickerNoticeCard(_ notice: FoldersPickerNotice, engine: FoldersEngine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch notice {
            case .alreadyAdded(let folderID, let name):
                Text(FoldersVocabulary.alreadyAdded(folder: name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Button(FoldersVocabulary.openFolder(folder: name)) {
                    engine.clearPickerNotice()
                    self.openFolder(id: folderID)
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("folders.notice.openExisting")

            case .overlap(let probe, let target):
                let otherLabel = FoldersVocabulary.overlapTargetLabel(target)
                Text(FoldersVocabulary.overlapHeading(other: otherLabel))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(FoldersVocabulary.overlapBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(FoldersVocabulary.overlapChoose) {
                        engine.clearPickerNotice()
                        self.showingPicker = true
                    }
                    .buttonStyle(BrandProminentButtonStyle())
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("folders.notice.chooseAnother")

                    Button(FoldersVocabulary.overlapOverride) {
                        let id = engine.confirmOverlappingFolder(probe: probe, target: target)
                        self.openFolder(id: id)
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("folders.notice.useAnyway")
                }

            case .refusedLocal:
                Text(FoldersVocabulary.refusedLocal)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FoldersVocabulary.overlapChoose) {
                    engine.clearPickerNotice()
                    self.showingPicker = true
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("folders.notice.chooseAnother")

            case .refusedProvider:
                Text(FoldersVocabulary.refusedProvider)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FoldersVocabulary.overlapChoose) {
                    engine.clearPickerNotice()
                    self.showingPicker = true
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("folders.notice.chooseAnother")
            }
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay {
            ShellMetrics.cardShape.stroke(Color.solOrange.opacity(0.6), lineWidth: 1)
        }
        .accessibilityIdentifier("folders.pickerNotice")
    }
}

/// Compact facet badge displayed beside a folder name when a facet is assigned.
struct FolderFacetChip: View {
    let facet: FolderFacet

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.tint(for: self.facet.color))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(self.facet.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.deckGround, in: Capsule())
        .overlay {
            Capsule().stroke(Color.deckHairline, lineWidth: 0.5)
        }
    }

    private static func tint(for hex: String?) -> Color {
        guard let hex else { return .solOrangeAdaptive }
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return .solOrangeAdaptive
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
