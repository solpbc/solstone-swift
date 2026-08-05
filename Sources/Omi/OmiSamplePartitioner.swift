// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OmiSamplePartitioner {
    static func partitions(
        samples: [Int16],
        alreadyWritten: Int,
        sampleLimit: Int
    ) -> [ArraySlice<Int16>] {
        precondition(sampleLimit > 0)
        precondition(alreadyWritten >= 0)
        guard !samples.isEmpty else { return [] }

        var partitions: [ArraySlice<Int16>] = []
        var start = samples.startIndex
        var capacity = alreadyWritten >= sampleLimit
            ? sampleLimit
            : sampleLimit - alreadyWritten

        while start < samples.endIndex {
            let end = samples.index(start, offsetBy: min(capacity, samples.distance(from: start, to: samples.endIndex)))
            partitions.append(samples[start..<end])
            start = end
            capacity = sampleLimit
        }
        return partitions
    }
}
