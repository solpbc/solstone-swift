// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum AppGroupContainer {
    static let identifier = "group.app.solstone.swift"

    static func rootURL(fileManager: FileManager = .default) throws -> URL {
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.identifier) else {
            throw AppGroupContainerError.unavailable(identifier: Self.identifier)
        }
        return url
    }
}

nonisolated enum AppGroupContainerError: Error, Equatable, Sendable {
    case unavailable(identifier: String)
}
