// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum PhoneAudioWriterLease {
    private static var heldSegmentIDs: Set<UUID> = []

    static func acquire(_ segmentID: UUID) {
        self.heldSegmentIDs.insert(segmentID)
    }

    static func release(_ segmentID: UUID) {
        self.heldSegmentIDs.remove(segmentID)
    }

    static func isHeld(_ segmentID: UUID) -> Bool {
        self.heldSegmentIDs.contains(segmentID)
    }
}
