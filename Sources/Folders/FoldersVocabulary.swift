// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Typed accessors for every owner-visible string on the folders source.
/// Zero hardcoded English strings live in UI views.
nonisolated enum FoldersVocabulary {
    static var label: String { AppStrings.ios_folders_label() }
    static var addFolder: String { AppStrings.ios_folders_addfolder() }
    static var addFolderPlus: String { AppStrings.ios_folders_addfolderplus() }
    static var chooseFolder: String { AppStrings.ios_folders_choosefolder() }
    static var intro: String { AppStrings.ios_folders_intro() }
    static func oneIntro(folder: String) -> String { AppStrings.ios_folders_oneintro(folder) }
    static func twoFolders(_ first: String, _ second: String) -> String { AppStrings.ios_folders_two(first, second) }
    static func manyFolders(_ count: Int) -> String { AppStrings.ios_folders_many(Self.grouped(count)) }
    static func splitCounts(on: Int, paused: Int) -> String {
        AppStrings.ios_folders_split(Self.grouped(on), Self.grouped(paused))
    }
    static func tileProgress(folder: String, done: Int, total: Int) -> String {
        AppStrings.ios_folders_tileprogress(folder, Self.grouped(done), Self.grouped(total))
    }
    static func pageProgress(done: Int, total: Int) -> String {
        AppStrings.ios_folders_pageprogress(Self.grouped(done), Self.grouped(total))
    }
    static func waiting(_ count: Int) -> String { AppStrings.ios_folders_waiting(Self.grouped(count)) }
    static func waitingFolder(_ folder: String, count: Int) -> String {
        AppStrings.ios_folders_waitingfolder(folder, Self.grouped(count))
    }
    static var unpaired: String { AppStrings.ios_folders_unpaired() }
    static var journalUpdate: String { AppStrings.ios_folders_journalupdate() }
    static func finishSetup(folder: String) -> String { AppStrings.ios_folders_finishsetup(folder) }
    static var pausedFolder: String { AppStrings.ios_folders_pausedfolder() }
    static var offReason: String { AppStrings.ios_folders_off() }
    static var staysFact: String { AppStrings.ios_folders_stays() }
    static var otherOnFact: String { AppStrings.ios_folders_otheron() }
    static var otherOffFact: String { AppStrings.ios_folders_otheroff() }
    static func needAttentionMany(_ count: Int) -> String {
        AppStrings.ios_folders_needattentionmany(Self.grouped(count))
    }
    static func alreadyAdded(folder: String) -> String { AppStrings.ios_folders_alreadyadded(folder) }
    static func openFolder(folder: String) -> String { AppStrings.ios_folders_openfolder(folder) }
    static var remove: String { AppStrings.ios_folders_remove() }
    static func removeHeading(folder: String) -> String { AppStrings.ios_folders_removeheading(folder) }
    static func removeBody(folder: String) -> String { AppStrings.ios_folders_removebody(folder) }

    // Overlap
    static func overlapHeading(other: String) -> String { AppStrings.ios_folders_overlapheading(other) }
    static var overlapBody: String { AppStrings.ios_folders_overlapbody() }
    static var overlapChoose: String { AppStrings.ios_folders_overlapchoose() }
    static var overlapOverride: String { AppStrings.ios_folders_overlapoverride() }
    static func overlapFact(other: String) -> String { AppStrings.ios_folders_overlapfact(other) }
    static func overlapTargetLabel(_ target: FolderOverlapTarget) -> String {
        switch target {
        case .obsidian(let name):
            AppStrings.ios_folders_overlapobsidian(name)
        case .folder(_, let name):
            AppStrings.ios_folders_overlapfolder(name)
        }
    }

    // Kinds
    static var whatComesIn: String { AppStrings.ios_folders_whatcomesin() }
    static var kindNotes: String { AppStrings.ios_folders_kind_notes() }
    static var kindNotesDesc: String { AppStrings.ios_folders_kind_notes_desc() }
    static var kindDocuments: String { AppStrings.ios_folders_kind_documents() }
    static var kindDocumentsDesc: String { AppStrings.ios_folders_kind_documents_desc() }
    static var kindTranscripts: String { AppStrings.ios_folders_kind_transcripts() }
    static var kindTranscriptsDesc: String { AppStrings.ios_folders_kind_transcripts_desc() }
    static var kindScreenshots: String { AppStrings.ios_folders_kind_screenshots() }
    static var kindScreenshotsDesc: String { AppStrings.ios_folders_kind_screenshots_desc() }
    static var kindPhotos: String { AppStrings.ios_folders_kind_photos() }
    static var kindPhotosDesc: String { AppStrings.ios_folders_kind_photos_desc() }
    static var kindOther: String { AppStrings.ios_folders_kind_other() }
    static var kindOtherDesc: String { AppStrings.ios_folders_kind_other_desc() }
    static var chooseAtLeastOne: String { AppStrings.ios_folders_chooseatleastone() }
    static var kindsGoingForward: String { AppStrings.ios_folders_kindsgoingforward() }

    // Facets
    static var facetHeading: String { AppStrings.ios_folders_facetheading() }
    static var facetNone: String { AppStrings.ios_folders_facetnone() }
    static var facetHelpNone: String { AppStrings.ios_folders_facethelpnone() }
    static func facetHelpSetup(facet: String) -> String { AppStrings.ios_folders_facethelpsetup(facet) }
    static func facetHelpActive(facet: String) -> String { AppStrings.ios_folders_facethelpactive(facet) }
    static var facetUnpaired: String { AppStrings.ios_folders_facetunpaired() }
    static var facetOffline: String { AppStrings.ios_folders_facetoffline() }

    // Range & Preview
    static var rangeHeading: String { AppStrings.ios_calendar_spanheader() }
    static func rangeLabel(_ range: FolderBackfillRange) -> String {
        switch range {
        case .last30Days: AppStrings.ios_calendar_span_native()
        case .last6Months: AppStrings.ios_calendarvocabulary_thelast6months()
        case .lastYear: AppStrings.ios_calendarvocabulary_thelastyear()
        case .everything: AppStrings.ios_calendarvocabulary_allofit()
        case .fromToday: AppStrings.ios_calendarvocabulary_nothingfrombeforetoday()
        }
    }

    static var previewHeading: String { AppStrings.ios_folders_preview() }
    static var checkingFolder: String { AppStrings.ios_folders_checkingfolder() }
    static func itemCount(_ count: Int, locale: Locale = .current) -> String {
        AppStrings.ios_intake_count_items(count, SourceIntakeFormat.grouped(count, locale: locale))
    }
    static func previewHeader(count: Int, start: String?, end: String?, locale: Locale = .current) -> String {
        let items = Self.itemCount(count, locale: locale)
        if let start, let end, count > 0 {
            return AppStrings.ios_folders_previewspan(items, start, end)
        }
        return items
    }
    static func previewBreakdown(contentCount: Int, contentBytes: UInt64, metaCount: Int, locale: Locale = .current) -> String? {
        let contentText = contentCount > 0
            ? AppStrings.ios_folders_previewcontentpart(
                contentCount,
                SourceIntakeFormat.grouped(contentCount, locale: locale),
                Self.formattedByteSize(contentBytes)
              )
            : nil
        let metaText = metaCount > 0
            ? AppStrings.ios_folders_previewmetapart(
                metaCount,
                SourceIntakeFormat.grouped(metaCount, locale: locale)
              )
            : nil
        switch (contentText, metaText) {
        case (let c?, let m?):
            return AppStrings.ios_folders_previewboth(c, m)
        case (let c?, nil):
            return c
        case (nil, let m?):
            return m
        case (nil, nil):
            return nil
        }
    }
    static var estimateHeading: String { AppStrings.ios_folders_estheading() }
    static func estimateValues(segments: Int, days: Int, thoughts: Int, locale: Locale = .current) -> String {
        let s = AppStrings.ios_folders_estsegments(segments, SourceIntakeFormat.grouped(segments, locale: locale))
        let d = AppStrings.ios_folders_estdays(days, SourceIntakeFormat.grouped(days, locale: locale))
        let t = AppStrings.ios_folders_estthoughts(thoughts, SourceIntakeFormat.grouped(thoughts, locale: locale))
        return AppStrings.ios_folders_estvalues(s, d, t)
    }
    static var estimateGloss: String { AppStrings.ios_folders_estgloss() }
    static var estimateUnpaired: String { AppStrings.ios_folders_estunpaired() }
    static var estimateOffline: String { AppStrings.ios_folders_estoffline() }
    static var scopeNote: String { AppStrings.ios_folders_scopenote() }
    static var nothingUntilConfirm: String { AppStrings.ios_folders_nothinguntilconfirm() }
    static var noRepeat: String { AppStrings.ios_folders_norepeat() }
    static func confirmButton(range: FolderBackfillRange, totalItems: Int) -> String {
        if range == .fromToday || totalItems <= 0 {
            return AppStrings.ios_folders_startfromtoday()
        }
        if totalItems == 1 {
            return AppStrings.ios_folders_bringinone()
        }
        return AppStrings.ios_folders_bringinmany(Self.grouped(totalItems))
    }
    static var previewFailed: String { AppStrings.ios_folders_previewfailed() }
    static var bringInOlder: String { AppStrings.ios_folders_bringinolder() }
    static var backfillStatus: String { AppStrings.ios_folders_backfillstatus() }

    // Errors & Platform Copy
    static func cantRead(_ count: Int) -> String {
        count == 1 ? AppStrings.ios_folders_cantreadone() : AppStrings.ios_folders_cantreadmany(Self.grouped(count))
    }
    static func fallbackToDetails(_ count: Int) -> String {
        count == 1 ? AppStrings.ios_folders_fallbackone() : AppStrings.ios_folders_fallbackmany(Self.grouped(count))
    }
    static var refusedLocal: String { AppStrings.ios_folders_refusedlocal() }
    static var refusedProvider: String { AppStrings.ios_folders_refusedprovider() }
    static func pickerHelper(isPad: Bool) -> String {
        isPad ? AppStrings.ios_folders_pickerhelper_ipad() : AppStrings.ios_folders_pickerhelper_iphone()
    }
    static func honestyLine(isPad: Bool) -> String {
        isPad ? AppStrings.ios_folders_honesty_ipad() : AppStrings.ios_folders_honesty_iphone()
    }
    static func attentionTile(folder: String) -> String { AppStrings.ios_folders_attention_tile(folder) }
    static func attentionReason(folder: String) -> String { AppStrings.ios_folders_attention_reason(folder) }
    static var attentionAction: String { AppStrings.ios_folders_attention_action() }

    // Shared actions reused from catalog
    static var pause: String { AppStrings.ios_photolibrary_pause() }
    static var resume: String { AppStrings.ios_photolibrary_resume() }
    static var checkNow: String { AppStrings.ios_obsidian_checknow() }
    static var tryAgain: String { AppStrings.ios_lookup_migration_offline_action() }
    static var cancel: String { AppStrings.ios_app_importcancelaction() }
    static var lastCheckedLabel: String { AppStrings.ios_obsidian_lastchecked() }
    static func rowSubline(items: String, when: String) -> String {
        AppStrings.ios_folders_rowsubline(items, when)
    }

    static func formattedByteSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    static func shortDate(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1_000.0)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let stored = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        return SourceIntakeFormat.started(stored, now: now, calendar: calendar)
    }

    private static func grouped(_ value: Int) -> String {
        SourceIntakeFormat.grouped(value, locale: .current)
    }
}
