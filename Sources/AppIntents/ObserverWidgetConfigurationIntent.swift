// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents

enum ObserverWidgetSource: String, AppEnum {
    case observer
    case location
    case screencast
    case watch

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: LocalizedStringResource("m696f732e696e74656e74732e6f6e7468697370686f6e65736f757263656c6162656c", table: "Localizable")) }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .observer: DisplayRepresentation(title: LocalizedStringResource("m696f732e6170702e617564696f", table: "Localizable")),
            .location: DisplayRepresentation(title: LocalizedStringResource("m696f732e6c6f636174696f6e2e736f75726365646973706c61796e616d65", table: "Localizable")),
            .screencast: DisplayRepresentation(title: LocalizedStringResource("m696f732e73637265656e636173742e626f6479", table: "Localizable")),
            .watch: DisplayRepresentation(title: LocalizedStringResource("m696f732e6170702e7761746368736f75726365646973706c61796e616d65", table: "Localizable")),
        ]
    }

    /// `nil` for a source with no widget: calendar and Safari have none.
    init?(sourceKind: SourceKind) {
        switch sourceKind {
        case .observer:
            self = .observer
        case .location:
            self = .location
        case .screencast:
            self = .screencast
        case .watch:
            self = .watch
        case .calendar, .safari, .obsidian, .screenshots:
            return nil
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
    static var title: LocalizedStringResource { LocalizedStringResource("m696f732e707573682e746573742e7469746c65", table: "Localizable") }

    @Parameter(title: LocalizedStringResource("m696f732e696e74656e74732e6f6e7468697370686f6e65736f757263656c6162656c", table: "Localizable"), default: .observer)
    var source: ObserverWidgetSource

    init() {
        self.source = .observer
    }

    init(source: ObserverWidgetSource) {
        self.source = source
    }
}
