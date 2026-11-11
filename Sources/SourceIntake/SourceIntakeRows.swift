// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct SourceIntakeStatusRow: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var soFar: String
    var last: String
    var destination: ShellDestination
}

nonisolated enum SourceIntakeRows {
    static func statusRows(
        snapshot: SourceIntakeSnapshot,
        includeSafari: Bool,
        includeWatch: Bool,
        now: Date,
        locale: Locale,
        calendar: Calendar
    ) -> [SourceIntakeStatusRow] {
        var sources: [(SourceIntakeSource, String, ShellDestination)] = [
            (.audio, "audio", .source(.audio)),
            (.location, LocationVocabulary.sourceDisplayName, .source(.location)),
            (.screen, SourceVocabulary.screencastDisplayName, .source(.screencast)),
            (.calendar, SourceVocabulary.calendarTitle, .source(.calendar)),
        ]
        if includeSafari {
            sources.append((.safari, SafariVocabulary.label, .source(.safari)))
        }
        if includeWatch {
            sources.append((.watch, SourceVocabulary.watchSourceDisplayName, .source(.watch)))
        }
        sources.append((.screenshots, ScreenshotsVocabulary.label, .source(.screenshots)))
        sources.append((.obsidian, ObsidianVocabulary.TITLE, .source(.obsidian)))
        sources.append((.imports, SourceVocabulary.importTitle, ShellDestination.import))
        return sources.map { source, name, destination in
            let values = SourceIntakeFormat.status(
                lane: snapshot.lane(source),
                kind: source.kind,
                now: now,
                locale: locale,
                calendar: calendar
            )
            return SourceIntakeStatusRow(
                id: source.rawValue,
                name: name,
                soFar: values.soFar,
                last: values.last,
                destination: destination
            )
        }
    }
}
