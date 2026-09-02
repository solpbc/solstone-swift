// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchRelayACKQueueSnapshot: Equatable, Sendable {
    let total: Int
    let recognizedACK: Int
    let parseableACK: Int
    let distinctIdentities: Int
    let duplicateExtras: Int
    let malformedOrMissing: Int
    let nonACK: Int
    let identityCounts: [UUID: Int]

    init(userInfoTransfers: [WatchConnectivityUserInfoTransferSnapshot] = []) {
        var recognizedACK = 0
        var parseableACK = 0
        var malformedOrMissing = 0
        var nonACK = 0
        var identityCounts: [UUID: Int] = [:]

        for transfer in userInfoTransfers {
            guard transfer.recognizedType == .watchSegmentACK else {
                nonACK += 1
                continue
            }

            recognizedACK += 1
            guard transfer.idState == .parseable, let segmentID = transfer.segmentID else {
                malformedOrMissing += 1
                continue
            }

            parseableACK += 1
            identityCounts[segmentID, default: 0] += 1
        }

        let duplicateExtras = identityCounts.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }

        self.total = userInfoTransfers.count
        self.recognizedACK = recognizedACK
        self.parseableACK = parseableACK
        self.distinctIdentities = identityCounts.keys.count
        self.duplicateExtras = duplicateExtras
        self.malformedOrMissing = malformedOrMissing
        self.nonACK = nonACK
        self.identityCounts = identityCounts
        assert(self.hasConsistentCounts)
    }

    var hasConsistentCounts: Bool {
        self.total >= 0
            && self.recognizedACK >= 0
            && self.parseableACK >= 0
            && self.distinctIdentities >= 0
            && self.duplicateExtras >= 0
            && self.malformedOrMissing >= 0
            && self.nonACK >= 0
            && self.total == self.recognizedACK + self.nonACK
            && self.recognizedACK == self.parseableACK + self.malformedOrMissing
            && self.parseableACK == self.distinctIdentities + self.duplicateExtras
            && self.distinctIdentities == self.identityCounts.keys.count
            && self.duplicateExtras == self.identityCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
    }
}
