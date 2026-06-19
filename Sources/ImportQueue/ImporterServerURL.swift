// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ImporterServerURL {
    static func saveURL(localPort: Int) -> URL? {
        ObserverServerURL.url(localPort: localPort, path: "/app/import/api/save")
    }

    static func startURL(localPort: Int) -> URL? {
        ObserverServerURL.url(localPort: localPort, path: "/app/import/api/start")
    }
}
