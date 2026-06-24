// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class WatchUploaderHolder {
    let uploader: ObserverUploader
    // Watch-only staging cleanup hook: watch keeps a durable staging layer that drop must clear.
    var removeStaging: (@MainActor @Sendable (UUID) -> Void)?

    init(_ uploader: ObserverUploader) {
        self.uploader = uploader
    }

    var pendingCount: Int {
        self.uploader.pendingCount
    }

    var failedCount: Int {
        self.uploader.failedCount
    }

    var lastUploadAt: Date? {
        self.uploader.lastUploadAt
    }

    var lastError: String? {
        self.uploader.lastError
    }
}
