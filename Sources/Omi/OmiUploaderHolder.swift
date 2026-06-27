// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation

@MainActor
@Observable
final class OmiUploaderHolder {
    let uploader: ObserverUploader

    init(_ uploader: ObserverUploader) {
        self.uploader = uploader
    }

    var pendingCount: Int {
        self.uploader.pendingCount
    }

    var failedCount: Int {
        self.uploader.failedCount
    }

    var inFlightCount: Int {
        self.uploader.inFlightCount
    }
}
