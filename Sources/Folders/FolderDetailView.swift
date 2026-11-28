// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Single configured folder setup and steady-state detail view (`‹ folders`).
struct FolderDetailView: View {
    let folderID: String

    @Environment(FoldersSourceHandle.self) private var handle
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRange: FolderBackfillRange = .last30Days
    @State private var showingOlderChooser = false
    @State private var showingRechoosePicker = false
    @State private var showingRemoveDialog = false
    @State private var isConfirming = false
    @State private var now = Date()

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        let engine = self.handle.source
        Group {
            if let folder = engine.folder(id: self.folderID) {
                self.content(folder: folder, engine: engine)
            } else {
                EmptyView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: self.folderID) {
            await engine.refreshJournalMetadata()
            if let folder = engine.folder(id: self.folderID), folder.mode == .settingUp {
                await engine.computePreview(folderID: self.folderID, range: self.selectedRange)
            }
        }
        .task {
            await refreshNowPeriodically { self.now = Date() }
        }
    }

    private func content(folder: FolderRecord, engine: FoldersEngine) -> some View {
        let state = FoldersEngine.stateForFolder(folder)
        let showsChooser = folder.mode == .settingUp || self.showingOlderChooser

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.stateBlock(folder: folder, state: state, engine: engine)

                if showsChooser {
                    self.kindsBlock(folder: folder, engine: engine, isSetup: folder.mode == .settingUp)
                    self.facetBlock(folder: folder, engine: engine, isSetup: folder.mode == .settingUp)
                    self.rangeAndPreviewBlock(folder: folder, engine: engine)
                } else {
                    self.kindsBlock(folder: folder, engine: engine, isSetup: false)
                    self.facetBlock(folder: folder, engine: engine, isSetup: false)
                }

                self.factsBlock(folder: folder)

                self.removeFooter(folder: folder)
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(folder.name)
        .accessibilityIdentifier("folders.detail.\(folder.id)")
        .fileImporter(
            isPresented: self.$showingRechoosePicker,
            allowedContentTypes: [UTType.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    _ = await engine.rechooseFolder(folderID: folder.id, url: url)
                }
            }
        }
        .confirmationDialog(
            FoldersVocabulary.removeHeading(folder: folder.name),
            isPresented: self.$showingRemoveDialog,
            titleVisibility: .visible
        ) {
            Button(FoldersVocabulary.remove, role: .destructive) {
                engine.removeFolder(folderID: folder.id)
                self.dismiss()
            }
            Button(FoldersVocabulary.cancel, role: .cancel) {}
        } message: {
            Text(FoldersVocabulary.removeBody(folder: folder.name))
        }
    }

    // MARK: - State Block

    private func stateBlock(folder: FolderRecord, state: SourceState, engine: FoldersEngine) -> some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            VStack(alignment: .leading, spacing: 12) {
                SourceDetailVerdictLine(state: state)
                    .accessibilityIdentifier("folders.detail.verdict")

                if folder.mode != .settingUp {
                    Toggle(folder.name, isOn: Binding(
                        get: { folder.mode != .off },
                        set: { enabled in
                            if enabled {
                                engine.turnOn(folderID: folder.id)
                                self.showingOlderChooser = false
                                Task {
                                    await engine.computePreview(folderID: folder.id, range: self.selectedRange)
                                }
                            } else {
                                self.showingOlderChooser = false
                                engine.turnOff(folderID: folder.id)
                            }
                        }
                    ))
                    .tint(.solOrange)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("folders.detail.toggle")
                }

                if folder.mode != .off && folder.attention != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(FoldersVocabulary.attentionReason(folder: folder.name))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("folders.detail.attention")

                        Button(FoldersVocabulary.attentionAction) {
                            self.showingRechoosePicker = true
                        }
                        .buttonStyle(BrandProminentButtonStyle())
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("folders.detail.rechoose")
                    }
                } else {
                    switch folder.mode {
                    case .settingUp:
                        Text(FoldersVocabulary.honestyLine(isPad: self.isPad))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("folders.detail.honesty")

                    case .on:
                        if !engine.isPaired {
                            SourceDetailReasonLine(message: FoldersVocabulary.unpaired)
                                .accessibilityIdentifier("folders.detail.unpaired")
                        } else if engine.capabilityListed == false {
                            SourceDetailReasonLine(message: FoldersVocabulary.journalUpdate)
                                .accessibilityIdentifier("folders.detail.capabilityHold")
                        }

                        if folder.backfillTotal > 0 && folder.backfillDone < folder.backfillTotal {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(FoldersVocabulary.pageProgress(done: folder.backfillDone, total: folder.backfillTotal))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(FoldersVocabulary.backfillStatus)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityIdentifier("folders.detail.progress")
                        } else if !folder.pending.isEmpty {
                            Text(FoldersVocabulary.waiting(folder.pending.count))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("folders.detail.waiting")
                        }

                        // Honesty line shown while setting up or on; omitted while paused or off.
                        Text(FoldersVocabulary.honestyLine(isPad: self.isPad))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("folders.detail.honesty")

                        HStack(spacing: 10) {
                            Button(FoldersVocabulary.pause) {
                                engine.pause(folderID: folder.id)
                            }
                            .buttonStyle(BrandQuietButtonStyle())
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("folders.detail.pause")

                            Button(FoldersVocabulary.checkNow) {
                                Task {
                                    await engine.checkNow(folderID: folder.id)
                                }
                            }
                            .buttonStyle(BrandQuietButtonStyle())
                            .disabled(engine.isChecking)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("folders.detail.checkNow")
                        }

                        if !self.showingOlderChooser {
                            Button(FoldersVocabulary.bringInOlder) {
                                self.showingOlderChooser = true
                                Task {
                                    await engine.computePreview(folderID: folder.id, range: self.selectedRange)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.solOrangeAdaptive)
                            .frame(minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("folders.detail.bringInOlder")
                        }

                    case .paused:
                        SourceDetailReasonLine(message: FoldersVocabulary.pausedFolder)
                            .accessibilityIdentifier("folders.detail.pausedReason")

                        Button(FoldersVocabulary.resume) {
                            Task {
                                await engine.resume(folderID: folder.id)
                            }
                        }
                        .buttonStyle(BrandProminentButtonStyle())
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("folders.detail.resume")

                    case .off:
                        SourceDetailReasonLine(message: FoldersVocabulary.offReason)
                            .accessibilityIdentifier("folders.detail.offReason")
                    }
                }

                // Non-fatal file-level honesty notices (E3 / E4).
                if folder.mode == .on && folder.cantRead > 0 {
                    HStack(spacing: 10) {
                        Text(FoldersVocabulary.cantRead(folder.cantRead))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(FoldersVocabulary.tryAgain) {
                            Task { await engine.checkNow(folderID: folder.id) }
                        }
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("folders.detail.cantRead")
                }

                if folder.fallbackToDetails > 0 {
                    Text(FoldersVocabulary.fallbackToDetails(folder.fallbackToDetails))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("folders.detail.fallback")
                }
            }
        }
    }

    // MARK: - Kinds Block

    private func kindsBlock(folder: FolderRecord, engine: FoldersEngine, isSetup: Bool) -> some View {
        SourceDetailBlock(title: FoldersVocabulary.whatComesIn) {
            VStack(alignment: .leading, spacing: 12) {
                self.kindToggle(
                    title: FoldersVocabulary.kindNotes,
                    description: FoldersVocabulary.kindNotesDesc,
                    id: "notes",
                    isOn: self.kindBinding(folder: folder, engine: engine, keyPath: \.notes)
                )
                self.kindToggle(
                    title: FoldersVocabulary.kindDocuments,
                    description: FoldersVocabulary.kindDocumentsDesc,
                    id: "documents",
                    isOn: self.kindBinding(folder: folder, engine: engine, keyPath: \.documents)
                )
                self.kindToggle(
                    title: FoldersVocabulary.kindTranscripts,
                    description: FoldersVocabulary.kindTranscriptsDesc,
                    id: "transcripts",
                    isOn: self.kindBinding(folder: folder, engine: engine, keyPath: \.transcripts)
                )
                self.kindToggle(
                    title: FoldersVocabulary.kindScreenshots,
                    description: FoldersVocabulary.kindScreenshotsDesc,
                    id: "screenshots",
                    isOn: self.kindBinding(folder: folder, engine: engine, keyPath: \.screenshots)
                )
                self.kindToggle(
                    title: FoldersVocabulary.kindPhotos,
                    description: FoldersVocabulary.kindPhotosDesc,
                    id: "photos",
                    isOn: self.kindBinding(folder: folder, engine: engine, keyPath: \.photos)
                )
                self.kindToggle(
                    title: FoldersVocabulary.kindOther,
                    description: FoldersVocabulary.kindOtherDesc,
                    id: "other",
                    isOn: self.kindBinding(folder: folder, engine: engine, keyPath: \.other)
                )

                if !folder.kinds.anySelected {
                    Text(FoldersVocabulary.chooseAtLeastOne)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("folders.detail.kindsValidation")
                } else if !isSetup {
                    Text(FoldersVocabulary.kindsGoingForward)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func kindToggle(title: String, description: String, id: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ShellFont.tileName)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.solOrange)
        .frame(minHeight: 44)
        .accessibilityIdentifier("folders.detail.kind.\(id)")
    }

    private func kindBinding(
        folder: FolderRecord,
        engine: FoldersEngine,
        keyPath: WritableKeyPath<FolderKinds, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { folder.kinds[keyPath: keyPath] },
            set: { newValue in
                var updated = folder.kinds
                updated[keyPath: keyPath] = newValue
                engine.setKinds(folderID: folder.id, kinds: updated)
                if folder.mode == .settingUp || self.showingOlderChooser {
                    Task {
                        await engine.computePreview(folderID: folder.id, range: self.selectedRange)
                    }
                }
            }
        )
    }

    // MARK: - Facet Block

    private func facetBlock(folder: FolderRecord, engine: FoldersEngine, isSetup: Bool) -> some View {
        SourceDetailBlock(title: FoldersVocabulary.facetHeading) {
            VStack(alignment: .leading, spacing: 8) {
                let selectionBinding = Binding<String>(
                    get: { folder.facet?.name ?? "" },
                    set: { slug in
                        if slug.isEmpty {
                            engine.setFacet(folderID: folder.id, facet: nil)
                        } else if let chosen = engine.facets.first(where: { $0.name == slug }) {
                            engine.setFacet(folderID: folder.id, facet: chosen)
                        }
                    }
                )

                let availableFacets = self.facetOptions(folder: folder, engine: engine)
                Picker(FoldersVocabulary.facetHeading, selection: selectionBinding) {
                    Text(FoldersVocabulary.facetNone).tag("")
                    ForEach(availableFacets) { facet in
                        Text(facet.title).tag(facet.name)
                    }
                }
                .pickerStyle(.menu)
                .tint(.solOrangeAdaptive)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("folders.detail.facet")

                if let facet = folder.facet {
                    Text(isSetup
                         ? FoldersVocabulary.facetHelpSetup(facet: facet.title)
                         : FoldersVocabulary.facetHelpActive(facet: facet.title))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(FoldersVocabulary.facetHelpNone)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if engine.facetsAvailability == .unpaired {
                    Text(FoldersVocabulary.facetUnpaired)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if engine.facetsAvailability == .offline {
                    Text(FoldersVocabulary.facetOffline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func facetOptions(folder: FolderRecord, engine: FoldersEngine) -> [FolderFacet] {
        var list = engine.facets
        if let assigned = folder.facet, !list.contains(where: { $0.name == assigned.name }) {
            list.append(assigned)
        }
        return list
    }

    // MARK: - Range & Preview Block

    private func rangeAndPreviewBlock(folder: FolderRecord, engine: FoldersEngine) -> some View {
        let preview = engine.previewsByFolderID[folder.id]
        let isScanning = engine.previewLoadingFolderID == folder.id

        return SourceDetailBlock(title: FoldersVocabulary.rangeHeading) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(FolderBackfillRange.allCases) { option in
                        Button {
                            self.selectedRange = option
                            Task {
                                await engine.computePreview(folderID: folder.id, range: option)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: self.selectedRange == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(self.selectedRange == option ? Color.solOrangeAdaptive : .secondary)
                                    .accessibilityHidden(true)
                                Text(FoldersVocabulary.rangeLabel(option))
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(self.selectedRange == option ? [.isSelected] : [])
                        .accessibilityIdentifier("folders.detail.range.\(option.rawValue)")
                    }
                }

                if folder.returning || self.showingOlderChooser {
                    Text(FoldersVocabulary.noRepeat)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Preview summary card (Solstone units only — never money)
                VStack(alignment: .leading, spacing: 8) {
                    Text(FoldersVocabulary.previewHeading)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(FoldersVocabulary.checkingFolder)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if let preview {
                        if preview.failed {
                            Text(FoldersVocabulary.previewFailed)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Button(FoldersVocabulary.tryAgain) {
                                Task {
                                    await engine.computePreview(folderID: folder.id, range: self.selectedRange)
                                }
                            }
                            .buttonStyle(BrandQuietButtonStyle())
                            .frame(minHeight: 44)
                        } else {
                            let startText = preview.oldestMs.map { FoldersVocabulary.shortDate($0, now: self.now) }
                            let endText = preview.newestMs.map { FoldersVocabulary.shortDate($0, now: self.now) }
                            Text(FoldersVocabulary.previewHeader(count: preview.totalItems, start: startText, end: endText))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if let breakdown = FoldersVocabulary.previewBreakdown(
                                contentCount: preview.contentItems,
                                contentBytes: preview.contentBytes,
                                metaCount: preview.metadataOnlyItems
                            ) {
                                Text(breakdown)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let est = preview.estimate, est.fromJournal {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(FoldersVocabulary.estimateHeading)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(FoldersVocabulary.estimateValues(
                                        segments: est.segments,
                                        days: est.days,
                                        thoughts: est.thoughts
                                    ))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    Text(FoldersVocabulary.estimateGloss)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 4)
                            } else if !engine.isPaired {
                                Text(FoldersVocabulary.estimateUnpaired)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(FoldersVocabulary.estimateOffline)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Text(FoldersVocabulary.scopeNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.deckGround, in: ShellMetrics.cardShape)
                .overlay {
                    ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5)
                }
                .accessibilityIdentifier("folders.detail.preview")

                if folder.mode == .settingUp && !folder.returning {
                    Text(FoldersVocabulary.nothingUntilConfirm)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let totalItems = preview?.totalItems ?? 0
                let confirmDisabled = !folder.kinds.anySelected || isScanning || self.isConfirming || (preview?.failed == true)
                Button(FoldersVocabulary.confirmButton(range: self.selectedRange, totalItems: totalItems)) {
                    self.isConfirming = true
                    Task {
                        let ok = await engine.confirmFolder(folderID: folder.id, range: self.selectedRange)
                        self.isConfirming = false
                        if ok {
                            self.showingOlderChooser = false
                        }
                    }
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .disabled(confirmDisabled)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("folders.detail.confirm")
            }
        }
    }

    // MARK: - Facts Block

    private func factsBlock(folder: FolderRecord) -> some View {
        SourceDetailBlock(title: FoldersVocabulary.label) {
            VStack(alignment: .leading, spacing: 10) {
                Text(FoldersVocabulary.oneIntro(folder: folder.name))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(FoldersVocabulary.staysFact)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(folder.kinds.other ? FoldersVocabulary.otherOnFact : FoldersVocabulary.otherOffFact)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let overlap = folder.overlap {
                    Text(FoldersVocabulary.overlapFact(other: FoldersVocabulary.overlapTargetLabel(overlap)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("folders.detail.overlapFact")
                }

                Divider()

                LabeledContent(
                    SourceIntakePhrases.soFar,
                    value: folder.itemsTakenIn > 0
                        ? FoldersVocabulary.itemCount(folder.itemsTakenIn)
                        : SourceIntakePhrases.nothingYet
                )
                .font(.footnote)

                if let lastTakenMs = folder.lastTakenInMs {
                    let date = Date(timeIntervalSince1970: Double(lastTakenMs) / 1_000.0)
                    LabeledContent(
                        SourceIntakePhrases.lastTakenIn,
                        value: SourceIntakeFormat.relative(date, now: self.now, calendar: .current)
                    )
                    .font(.footnote)
                }

                if let checkedMs = folder.lastCheckedMs {
                    let date = Date(timeIntervalSince1970: Double(checkedMs) / 1_000.0)
                    LabeledContent(
                        FoldersVocabulary.lastCheckedLabel,
                        value: SourceIntakeFormat.relative(date, now: self.now, calendar: .current)
                    )
                    .font(.footnote)
                }
            }
        }
    }

    // MARK: - Quiet Remove Footer

    private func removeFooter(folder: FolderRecord) -> some View {
        Button(role: .destructive) {
            self.showingRemoveDialog = true
        } label: {
            Text(FoldersVocabulary.remove)
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .accessibilityIdentifier("folders.detail.remove")
    }
}
