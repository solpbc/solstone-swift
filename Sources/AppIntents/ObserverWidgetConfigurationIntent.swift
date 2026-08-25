// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents

enum ObserverWidgetSource: String, AppEnum {
    case observer
    case location
    case omi
    case screencast
    case watch

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "source" }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .observer: "observer",
            .location: "location",
            .omi: "omi",
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
        case .omi:
            self = .omi
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
        case .omi:
            .omi
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
