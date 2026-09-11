// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents

enum ObserverWidgetSource: String, AppEnum {
    case observer
    case location
    case screencast
    case watch

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "source" }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .observer: "audio",
            .location: "location",
            .screencast: "screencast",
            .watch: "watch",
        ]
    }

    init(sourceKind: SourceKind) {
        switch sourceKind {
        case .observer:
            self = .observer
        case .location:
            self = .location
        case .screencast:
            self = .screencast
        case .watch:
            self = .watch
        }
    }

    var sourceKind: SourceKind {
        switch self {
        case .observer:
            .observer
        case .location:
            .location
        case .screencast:
            .screencast
        case .watch:
            .watch
        }
    }
}

struct ObserverWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "solstone" }

    @Parameter(title: "source", default: .observer)
    var source: ObserverWidgetSource

    init() {
        self.source = .observer
    }

    init(source: ObserverWidgetSource) {
        self.source = source
    }
}
