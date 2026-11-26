// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Lightweight projection of `GET /app/sources/photos/api/state` read by the iPhone app.
nonisolated struct PhotosJournalDashboardSummary: Codable, Equatable, Sendable {
    struct Choice: Codable, Equatable, Sendable {
        let range: String?
        let canWiden: Bool

        enum CodingKeys: String, CodingKey {
            case range
            case canWiden = "can_widen"
        }
    }

    struct Progress: Codable, Equatable, Sendable {
        let chosenTotal: Int
        let arrived: Int
        let inJournal: Int
        let waitingOnPhone: Int

        enum CodingKeys: String, CodingKey {
            case chosenTotal = "chosen_total"
            case arrived
            case inJournal = "in_journal"
            case waitingOnPhone = "waiting_on_phone"
        }
    }

    struct Scan: Codable, Equatable, Sendable {
        let itemsChecked: Int
        let itemsTotal: Int
        let paused: Bool

        enum CodingKeys: String, CodingKey {
            case itemsChecked = "items_checked"
            case itemsTotal = "items_total"
            case paused
        }
    }

    let state: String
    let substate: String
    let attentionReason: String?
    let choice: Choice
    let progress: Progress
    let scan: Scan

    enum CodingKeys: String, CodingKey {
        case state
        case substate
        case attentionReason = "attention_reason"
        case choice
        case progress
        case scan
    }
}

/// Pure presentation model for the Photos Library tile and detail page.
nonisolated struct PhotosLibraryViewState: Equatable, Sendable {
    enum PrimaryAction: Equatable, Sendable {
        case none
        case turnOn
        case scanLibrary
        case chooseInJournal
        case openSettings
    }

    let sourceState: SourceState
    let tileSubtext: String?
    let showsTileSubtext: Bool
    let tileControl: HomeSourceTileControl
    let pageSubline: String?
    let pageReason: String?
    let primaryAction: PrimaryAction
    let showsAlreadyGrantedLine: Bool
    let showsPauseResume: Bool
    let isPaused: Bool
    let showsOpenJournalDoor: Bool
    let showsWaitingForJournalUpdate: Bool

    static func resolve(
        paired: Bool,
        access: ScreenshotsAccess,
        capability: PhotosLibraryEngine.CapabilityState,
        document: PhotosLibraryDocument,
        isScanning: Bool,
        scanChecked: Int,
        scanTotal: Int,
        journal: PhotosJournalDashboardSummary?,
        lastPromptResult: ScreenshotsAccess?,
        locale: Locale = .current
    ) -> Self {
        let everOn = document.everEnabled
        let turnedOffInJournal = journal?.state == "off"
        let journalTooOld = paired && capability == .notListed

        // 1. Access revoked or narrowed after having been turned on -> needs attention.
        if everOn && !turnedOffInJournal && document.enabled {
            if access == .limited {
                return Self(
                    sourceState: .needsAttention,
                    tileSubtext: PhotosVocabulary.limitedTile,
                    showsTileSubtext: true,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.limitedLater,
                    primaryAction: .openSettings,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: document.paused,
                    showsOpenJournalDoor: paired && capability == .listed,
                    showsWaitingForJournalUpdate: journalTooOld
                )
            }
            if access == .restricted {
                return Self(
                    sourceState: .needsAttention,
                    tileSubtext: PhotosVocabulary.restricted,
                    showsTileSubtext: true,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.restricted,
                    primaryAction: .none,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: document.paused,
                    showsOpenJournalDoor: paired && capability == .listed,
                    showsWaitingForJournalUpdate: journalTooOld
                )
            }
            if access == .denied {
                return Self(
                    sourceState: .needsAttention,
                    tileSubtext: PhotosVocabulary.accessOffTile,
                    showsTileSubtext: true,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.accessOffLater,
                    primaryAction: .openSettings,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: document.paused,
                    showsOpenJournalDoor: paired && capability == .listed,
                    showsWaitingForJournalUpdate: journalTooOld
                )
            }
        }

        // 2. Turned off in journal -> off state, with journal door and re-entry button.
        if turnedOffInJournal {
            let canScanDirectly = paired && !journalTooOld && access == .full
            let action: PrimaryAction = (!paired || journalTooOld) ? .none : (canScanDirectly ? .scanLibrary : .turnOn)
            return Self(
                sourceState: .off,
                tileSubtext: nil,
                showsTileSubtext: false,
                tileControl: .none,
                pageSubline: nil,
                pageReason: paired ? nil : PhotosVocabulary.unpairedReason,
                primaryAction: action,
                showsAlreadyGrantedLine: canScanDirectly,
                showsPauseResume: false,
                isPaused: false,
                showsOpenJournalDoor: paired && capability == .listed,
                showsWaitingForJournalUpdate: journalTooOld
            )
        }

        // 3. Never enabled / not yet started -> ready to set up.
        if !document.enabled {
            if !paired {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.unpairedReason,
                    primaryAction: .none,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: false
                )
            }
            if journalTooOld {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: nil,
                    primaryAction: .none,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: true
                )
            }
            if access == .restricted {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.restricted,
                    primaryAction: .none,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: false
                )
            }
            if access == .limited {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.limitedAtPrompt,
                    primaryAction: .openSettings,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: false
                )
            }
            if access == .denied || lastPromptResult == .denied {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: PhotosVocabulary.declinedAtPrompt,
                    primaryAction: .openSettings,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: false
                )
            }
            if access == .full {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: nil,
                    primaryAction: .scanLibrary,
                    showsAlreadyGrantedLine: true,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: false
                )
            }
            return Self(
                sourceState: .readyToSetUp,
                tileSubtext: nil,
                showsTileSubtext: false,
                tileControl: .none,
                pageSubline: nil,
                pageReason: nil,
                primaryAction: .turnOn,
                showsAlreadyGrantedLine: false,
                showsPauseResume: false,
                isPaused: false,
                showsOpenJournalDoor: false,
                showsWaitingForJournalUpdate: false
            )
        }

        // 4. Scanning metadata -> setting up.
        if isScanning || (!document.scanComplete && journal?.substate != "choose") {
            if journalTooOld {
                return Self(
                    sourceState: .readyToSetUp,
                    tileSubtext: nil,
                    showsTileSubtext: false,
                    tileControl: .none,
                    pageSubline: nil,
                    pageReason: nil,
                    primaryAction: .none,
                    showsAlreadyGrantedLine: false,
                    showsPauseResume: false,
                    isPaused: false,
                    showsOpenJournalDoor: false,
                    showsWaitingForJournalUpdate: true
                )
            }
            let checked = max(scanChecked, journal?.scan.itemsChecked ?? document.itemsChecked)
            let total = max(scanTotal, journal?.scan.itemsTotal ?? document.itemsTotal)
            return Self(
                sourceState: .enrolling,
                tileSubtext: PhotosVocabulary.tileScanning,
                showsTileSubtext: true,
                tileControl: .none,
                pageSubline: PhotosVocabulary.scanningProgress(checked: checked, total: total, locale: locale),
                pageReason: nil,
                primaryAction: .none,
                showsAlreadyGrantedLine: false,
                showsPauseResume: false,
                isPaused: false,
                showsOpenJournalDoor: false,
                showsWaitingForJournalUpdate: false
            )
        }

        // 5. Scan finished, awaiting range choice in journal -> setting up.
        let awaitingChoice: Bool = {
            if let journal {
                return journal.substate == "choose" || (journal.state == "setting_up" && journal.choice.range == nil)
            }
            return document.scanComplete && document.sentCount == 0 && !document.paused
        }()
        if awaitingChoice {
            return Self(
                sourceState: journalTooOld ? .readyToSetUp : .enrolling,
                tileSubtext: journalTooOld ? nil : PhotosVocabulary.tileChoose,
                showsTileSubtext: !journalTooOld,
                tileControl: .none,
                pageSubline: journalTooOld ? nil : PhotosVocabulary.scanFinished,
                pageReason: nil,
                primaryAction: journalTooOld ? .none : .chooseInJournal,
                showsAlreadyGrantedLine: false,
                showsPauseResume: false,
                isPaused: false,
                showsOpenJournalDoor: false,
                showsWaitingForJournalUpdate: journalTooOld
            )
        }

        // 6. Paused (either locally or in journal).
        let paused = document.paused || journal?.state == "paused"
        if paused {
            return Self(
                sourceState: .paused,
                tileSubtext: PhotosVocabulary.tilePaused,
                showsTileSubtext: true,
                tileControl: .toggle,
                pageSubline: PhotosVocabulary.tilePaused,
                pageReason: nil,
                primaryAction: .none,
                showsAlreadyGrantedLine: false,
                showsPauseResume: true,
                isPaused: true,
                showsOpenJournalDoor: paired && capability == .listed,
                showsWaitingForJournalUpdate: journalTooOld
            )
        }

        // 7. Bringing in chosen photos -> on with progress counts.
        if let journal, journal.substate == "bringing_in", journal.progress.chosenTotal > 0 {
            let done = min(journal.progress.arrived, journal.progress.chosenTotal)
            let total = journal.progress.chosenTotal
            return Self(
                sourceState: .active,
                tileSubtext: PhotosVocabulary.progress(done: done, total: total, onPage: false, locale: locale),
                showsTileSubtext: true,
                tileControl: .toggle,
                pageSubline: PhotosVocabulary.progress(done: done, total: total, onPage: true, locale: locale),
                pageReason: nil,
                primaryAction: .none,
                showsAlreadyGrantedLine: false,
                showsPauseResume: true,
                isPaused: false,
                showsOpenJournalDoor: paired && capability == .listed,
                showsWaitingForJournalUpdate: journalTooOld
            )
        }

        // 8. Steady on.
        let canWiden = journal?.choice.canWiden ?? true
        return Self(
            sourceState: .active,
            tileSubtext: PhotosVocabulary.tileSteady,
            showsTileSubtext: true,
            tileControl: .toggle,
            pageSubline: PhotosVocabulary.steadyLine(canWiden: canWiden),
            pageReason: nil,
            primaryAction: .none,
            showsAlreadyGrantedLine: false,
            showsPauseResume: true,
            isPaused: false,
            showsOpenJournalDoor: paired && capability == .listed,
            showsWaitingForJournalUpdate: journalTooOld
        )
    }
}

@MainActor
@Observable
final class PhotosLibrarySourceHandle {
    let source: PhotosLibraryEngine

    init(source: PhotosLibraryEngine) {
        self.source = source
    }
}

@MainActor
func makePhotosSource(_ source: PhotosLibraryEngine) -> Source {
    let view = source.viewState()
    return Source(
        id: PhotosLibraryWire.sourceKey,
        displayName: PhotosVocabulary.label,
        kind: .photos,
        state: view.sourceState,
        isJournalPaired: source.isPaired(),
        activeSubtext: PhotosVocabulary.tileSteady,
        subtextOverride: view.tileSubtext,
        attention: view.pageReason.map { SourceAttention(message: $0) },
        pendingStatus: .nonePending,
        showsSubtext: view.showsTileSubtext
    )
}

@MainActor
func photosTileControl(_ source: PhotosLibraryEngine) -> HomeSourceTileControl {
    source.viewState().tileControl
}

@MainActor
func setPhotosTile(_ source: PhotosLibraryEngine, on: Bool) async {
    if on {
        await source.resume()
    } else {
        await source.pauseWithJournalSync()
    }
}
