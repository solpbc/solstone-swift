// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourcesView: View {
    @State private var path: [ShellDestination] = []

    var body: some View {
        NavigationStack(path: self.$path) {
            AddMoreView { route in
                self.path.append(.source(route))
            }
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // The surface is `add more`: the name of the tile that opens it,
                        // and the name the shell contract gives it. Titled `sources`, a
                        // tap on `add more` appeared to land somewhere else.
                        Text(SourceVocabulary.addMoreTitle)
                            .font(ShellFont.display(22, relativeTo: .title2))
                    }
                }
                .navigationDestination(for: ShellDestination.self) { destination in
                    ShellDestinationView(destination: destination)
                }
        }
        .environment(\.pushShellDestination, { destination in
            self.path.append(destination)
        })
    }
}

nonisolated enum SourceRoute: Hashable, Identifiable, Sendable {
    case audio, location, screencast, watch, calendar, safari, obsidian, screenshots, photos, folders

    var id: String {
        switch self {
        case .audio: "audio"
        case .location: "location"
        case .screencast: "screencast"
        case .watch: "watch"
        case .calendar: "calendar"
        case .safari: "safari"
        case .obsidian: "obsidian"
        case .screenshots: "screenshots"
        case .photos: "photos"
        case .folders: "folders"
        }
    }
}

nonisolated struct SourcesViewRow: Identifiable, Equatable, Sendable {
    let route: SourceRoute
    let source: Source

    var id: String { self.route.id }
}

nonisolated enum SourcesViewRowBuilder {
    static func addMoreRows(
        audio: Source,
        location: Source,
        screencast: Source,
        watch: Source?,
        calendar: Source?,
        safari: Source? = nil,
        obsidian: Source? = nil,
        screenshots: Source? = nil,
        photos: Source? = nil,
        folders: Source? = nil,
        hiddenIDs: Set<String>
    ) -> [SourcesViewRow] {
        var canonical = [
            SourcesViewRow(route: .audio, source: audio),
            SourcesViewRow(route: .location, source: location),
            SourcesViewRow(route: .screencast, source: screencast),
        ]
        if let calendar {
            canonical.append(SourcesViewRow(route: .calendar, source: calendar))
        }
        if let obsidian {
            canonical.append(SourcesViewRow(route: .obsidian, source: obsidian))
        }
        if let screenshots {
            canonical.append(SourcesViewRow(route: .screenshots, source: screenshots))
        }
        if let photos {
            canonical.append(SourcesViewRow(route: .photos, source: photos))
        }
        if let folders {
            canonical.append(SourcesViewRow(route: .folders, source: folders))
        }
        if let safari {
            canonical.append(SourcesViewRow(route: .safari, source: safari))
        }
        if let watch {
            canonical.append(SourcesViewRow(route: .watch, source: watch))
        }
        let hidden = canonical.filter { !isHomeSourceVisible(id: $0.source.id, hiddenIDs: hiddenIDs) }
        let visible = canonical.filter { isHomeSourceVisible(id: $0.source.id, hiddenIDs: hiddenIDs) }
        return hidden + visible
    }
}
