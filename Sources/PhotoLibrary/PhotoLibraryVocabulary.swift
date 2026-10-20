// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Owner-facing words for the photo library import. Reviewed as one set; change them together.
nonisolated enum PhotoLibraryVocabulary {
    static let importRow = "photo library"
    static let importRowHint = "Opens a screen for bringing in an album and a range of dates."
    static let title = "photo library"

    static let whatItAdds = "choose an album and a range of dates, and those photos go into your journal. nothing comes in until you start the import."
    static let photosOnly = "photos only. videos stay in your library."
    static let processingDisclosure = "in your journal, a model describes each photo so you can search for it. each photo goes to the model you chose for your journal: one on your own computer, confidential processing, or an AI provider you connected."

    static let accessTitle = "photo access"
    static let accessNotAsked = "the solstone app doesn't have access to your photo library yet. you can allow all of it, or only the photos you pick."
    static let accessAsk = "allow photo access"
    static let accessAskHint = "Asks ios for photo library access."
    static let accessAll = "all photos"
    static let accessSelected = "only the photos you picked"
    static let accessSelectedLine = "only those can come in. you can pick more any time."
    static let accessPickMore = "pick more photos"
    static let accessPickMoreHint = "Changes which photos the solstone app can use."
    static let accessOff = "photo access is off"
    static let accessOffLine = "turn it on in ios settings to bring in photos from your library."
    static let accessOpenSettingsHint = "Opens ios settings for photo access."
    static let accessUnavailable = "photo access isn't available on this device."

    static let chooseTitle = "choose what comes in"
    static let albumLabel = "album"
    static let albumAll = "all photos"
    static let albumFavorites = "favorites"
    static let albumScreenshots = "screenshots"
    static let fromLabel = "from"
    static let toLabel = "to"
    static let countNone = "no photos in that album between those dates."
    static let countNoneNew = "every photo in that album between those dates came in before."
    static let startHint = "Starts bringing these photos into your journal."

    static let pause = "pause"
    static let pauseHint = "Pauses this import."
    static let pausedLine = "you paused this import. photos already brought in still go to your journal."
    static let pausedForAccessLine = "photo access is off, so this import is paused. it carries on when you turn access back on."
    static let pausedForSpaceLine = "this device is out of room, so this import is paused. resume once there's space."
    static let resume = "resume"
    static let resumeHint = "Brings in the rest of this import."
    static let stop = "stop import"
    static let stopHint = "Ends this import. The rest stay in your library."
    static let stopConfirmTitle = "stop this import?"
    static let stopConfirmKeepGoing = "keep going"
    private static let waitingForJournalPaired = "the rest come in when your journal reconnects."
    private static let waitingForJournalUnpaired = "the rest come in once you connect a journal."

    static func waitingForJournal(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.waitingForJournalPaired : Self.waitingForJournalUnpaired
    }

    static let thisImportTitle = "this import"
    static let lastImportTitle = "last import"
    static let recentTitle = "recent"
    static let recentEmpty = "photos you import show up here."
    static let removalLine = "to take a photo back out of your journal, delete its segment there."

    static let processing = "in your journal · being described"
    static let described = "in your journal · described"
    static let notDescribed = "in your journal · saved without a description"
    static let failed = "in your journal · couldn't be processed"

    static func albumName(_ album: PhotoLibraryAlbum) -> String {
        switch album.kind {
        case .all:
            Self.albumAll
        case .favorites:
            Self.albumFavorites
        case .screenshots:
            Self.albumScreenshots
        case .album:
            album.title ?? Self.albumAll
        }
    }

    static func photos(_ n: Int) -> String {
        n == 1 ? "1 photo" : "\(n) photos"
    }

    static func alreadyIn(_ m: Int) -> String {
        m == 1
            ? "1 more came in from this device before, so it's left out."
            : "\(m) more came in from this device before, so they're left out."
    }

    static func start(_ n: Int) -> String {
        n == 1 ? "import 1 photo" : "import \(n) photos"
    }

    static func running(album: String, range: String) -> String {
        "bringing in \(album), \(range)."
    }

    static func stillToCome(_ n: Int) -> String {
        n == 1 ? "1 still to come from your library." : "\(n) still to come from your library."
    }

    static func stopConfirmMessage(remaining n: Int) -> String {
        n == 1
            ? "photos already brought in still go to your journal. the other one stays in your library."
            : "photos already brought in still go to your journal. the other \(n) stay in your library."
    }

    static func lastImportFinished(count: Int, album: String, range: String, when: String) -> String {
        "\(Self.photos(count)) from \(album), \(range) · \(when)"
    }

    static func lastImportStopped(count: Int, album: String, range: String, when: String) -> String {
        "stopped after \(Self.photos(count)) from \(album), \(range) · \(when)"
    }

    static func unreadable(_ n: Int) -> String {
        "\(n) couldn't be read from your library."
    }

    static func access(_ access: PhotoLibraryAccess) -> String {
        switch access {
        case .notAsked:
            Self.accessNotAsked
        case .all:
            Self.accessAll
        case .selected:
            Self.accessSelected
        case .off:
            Self.accessOff
        case .unavailable:
            Self.accessUnavailable
        }
    }

    static func status(for contribution: PhotoContribution) -> String {
        switch contribution.sendState {
        case .inYourJournal:
            switch contribution.processing {
            case .processing:
                Self.processing
            case .described:
                Self.described
            case .notDescribed:
                Self.notDescribed
            case .failed:
                Self.failed
            case nil:
                contribution.sendState.label
            }
        case .savedOnThisPhone, .sending, .needsAttention:
            contribution.sendState.label
        }
    }

    /// `jun 1 – jun 30`, or one day when the range is one day.
    static func range(_ scope: PhotoLibraryScope, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: scope.from, to: scope.to).lowercased()
    }
}
