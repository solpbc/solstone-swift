// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ObsidianSourceDetailView: View {
    @Environment(ObsidianSourceHandle.self) private var handle
    @Environment(ObsidianTransferHolder.self) private var transferHolder: ObsidianTransferHolder?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingPicker = false
    @State private var refusalSentence: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let status = self.handle.source.status

                if status.selectedVaultID == nil {
                    self.setupBlock
                } else {
                    self.activeBlock(status: status)
                }

                SourceIntakeFacts(source: .obsidian)
                SourceHomeTileControl(sourceID: "obsidian")
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("obsidian.page")
        .navigationTitle(ObsidianVocabulary.TITLE)
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
                    let outcome = await self.handle.source.chooseVault(url: url)
                    switch outcome {
                    case .success:
                        self.refusalSentence = nil
                    case .failure(let refusal):
                        self.refusalSentence = refusal.sentence
                    }
                }
            case .failure:
                break
            }
        }
        .task {
            await self.transferHolder?.refreshNoteCounts()
        }
    }

    private var setupBlock: some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ObsidianVocabulary.EXPLAINER)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                let isPad = UIDevice.current.userInterfaceIdiom == .pad
                Text(ObsidianVocabulary.pickerGuidanceSentence(isPad: isPad))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(ObsidianVocabulary.TIMING_SETUP)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let attention = self.handle.source.status.attention {
                    SourceDetailReasonLine(message: attention.sentence)
                        .accessibilityIdentifier("obsidian.attention")
                }

                if let refusal = self.refusalSentence {
                    SourceDetailReasonLine(message: refusal)
                        .accessibilityIdentifier("obsidian.refusal")
                }

                Button(ObsidianVocabulary.CHOOSE_BUTTON) {
                    self.showingPicker = true
                }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("obsidian.choose")
            }
        }
    }

    @ViewBuilder
    private func activeBlock(status: ObsidianSourceStatus) -> some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            VStack(alignment: .leading, spacing: 12) {
                SourceDetailVerdictLine(state: status.tileState)

                Toggle(ObsidianVocabulary.SWITCH_LABEL, isOn: Binding(
                    get: { status.isEnabled },
                    set: { enabled in
                        Task {
                            if enabled {
                                await self.handle.source.turnOn()
                            } else {
                                self.handle.source.turnOff()
                            }
                        }
                    }
                ))
                .tint(.solOrange)
                .frame(minHeight: 44)
                .accessibilityIdentifier("obsidian.toggle")

                if let attention = status.attention {
                    SourceDetailReasonLine(message: attention.sentence)
                        .accessibilityIdentifier("obsidian.attention")
                }

                // Capability holds
                if status.isEnabled {
                    let cap = self.transferHolder?.capability ?? .unknown
                    if cap == .notListed {
                        SourceDetailReasonLine(message: ObsidianVocabulary.CAPABILITY_NOT_LISTED)
                            .accessibilityIdentifier("obsidian.capability.notListed")
                    } else if cap == .unknown {
                        SourceDetailReasonLine(message: ObsidianVocabulary.CAPABILITY_UNKNOWN)
                            .accessibilityIdentifier("obsidian.capability.unknown")
                    }
                }

                // Same name advisory
                if let adv = self.transferHolder?.sameNameAdvisory {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ObsidianVocabulary.SAME_NAME_TITLE)
                            .font(.subheadline.weight(.semibold))
                        Text(ObsidianVocabulary.sameNameBody(vault: adv.vault, device: adv.device, date: adv.lastSyncedAt ?? ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button(ObsidianVocabulary.CONTINUE) {
                                Task {
                                    await self.transferHolder?.continueSameNameAction?()
                                }
                            }
                            .buttonStyle(BrandProminentButtonStyle())

                            Button(ObsidianVocabulary.CANCEL) {
                                Task {
                                    await self.transferHolder?.cancelSameNameAction?()
                                }
                            }
                            .buttonStyle(BrandQuietButtonStyle())
                        }
                    }
                }

                if status.hasHeldEarlierVault {
                    SourceDetailReasonLine(message: ObsidianVocabulary.HELD_EARLIER_VAULT)
                        .accessibilityIdentifier("obsidian.heldEarlier")
                }

                if let refusal = self.refusalSentence {
                    SourceDetailReasonLine(message: refusal)
                        .accessibilityIdentifier("obsidian.refusal")
                }

                // Facts
                VStack(alignment: .leading, spacing: 8) {
                    if let vaultName = status.vaultName {
                        LabeledContent(ObsidianVocabulary.VAULT_FACT, value: vaultName)
                    }

                    let checkedStr: String = {
                        if let lastChecked = status.lastChecked {
                            let fmt = DateFormatter()
                            fmt.timeStyle = .short
                            fmt.dateStyle = .none
                            return fmt.string(from: lastChecked)
                        }
                        return ObsidianVocabulary.NOT_CHECKED_YET
                    }()
                    LabeledContent(ObsidianVocabulary.CHECKED_FACT, value: checkedStr)
                        .accessibilityIdentifier("obsidian.lastChecked")

                    LabeledContent(ObsidianVocabulary.WAITING_FACT, value: "\(status.pendingAndQueuedNotes)")
                        .accessibilityIdentifier("obsidian.waiting")

                    let delivered = status.deliveredNotesCount
                    Text(ObsidianVocabulary.progress(delivered: delivered, found: status.totalFoundNotes))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("obsidian.progress")

                    if status.unavailableCount > 0 {
                        LabeledContent(ObsidianVocabulary.UNAVAILABLE_FACT, value: "\(status.unavailableCount)")
                            .accessibilityIdentifier("obsidian.unavailable")
                    }
                    if status.tooLargeCount > 0 {
                        LabeledContent(ObsidianVocabulary.SIZE_FACT, value: "\(status.tooLargeCount)")
                            .accessibilityIdentifier("obsidian.tooLarge")
                    }
                }

                // Actions
                if status.isEnabled {
                    Button(status.isPaused ? ObsidianVocabulary.RESUME : ObsidianVocabulary.PAUSE) {
                        if status.isPaused {
                            self.handle.source.resume()
                        } else {
                            self.handle.source.pause()
                        }
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("obsidian.pauseResume")

                    Button(ObsidianVocabulary.MANUAL_CHECK) {
                        Task { await self.handle.source.checkNow() }
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("obsidian.checkNow")
                }

                // Changing vault requires source off
                if !status.isEnabled {
                    Button(ObsidianVocabulary.CHOOSE_BUTTON) {
                        self.showingPicker = true
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("obsidian.chooseAgain")
                }
            }
        }
    }
}
