// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourcesView: View {
    @State private var selectedSourceRoute: SourceRoute?

    var body: some View {
        NavigationStack {
            AddMoreView { route in
                self.selectedSourceRoute = route
            }
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("sources")
                            .font(.custom("Comfortaa-Bold", size: 22, relativeTo: .title2))
                    }
                }
                .navigationDestination(item: self.$selectedSourceRoute) { route in
                    ShellDestinationView(destination: .source(route))
                }
        }
    }
}

nonisolated enum SourceRoute: Hashable, Identifiable, Sendable {
    case audio, location, screencast, omi, watch

    var id: String {
        switch self {
        case .audio: "audio"
        case .location: "location"
        case .screencast: "screencast"
        case .omi: "omi"
        case .watch: "watch"
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
        omi: Source,
        watch: Source?,
        hiddenIDs: Set<String>
    ) -> [SourcesViewRow] {
        var canonical = [
            SourcesViewRow(route: .audio, source: audio),
            SourcesViewRow(route: .location, source: location),
            SourcesViewRow(route: .screencast, source: screencast),
            SourcesViewRow(route: .omi, source: omi),
        ]
        if let watch {
            canonical.append(SourcesViewRow(route: .watch, source: watch))
        }
        let hidden = canonical.filter { !isHomeSourceVisible(id: $0.source.id, hiddenIDs: hiddenIDs) }
        let visible = canonical.filter { isHomeSourceVisible(id: $0.source.id, hiddenIDs: hiddenIDs) }
        return hidden + visible
    }
}
