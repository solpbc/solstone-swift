// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OmiSamplePartitionerTests: XCTestCase {
    func testPartitionsPreserveOrderAndRespectLimits() {
        let cases: [(samples: [Int16], alreadyWritten: Int, sampleLimit: Int, counts: [Int])] = [
            ([], 0, 4, []),
            ([11, 12, 13, 14], 0, 4, [4]),
            ([21, 22, 23, 24, 25, 26, 27], 2, 4, [2, 4, 1]),
            ([31, 32, 33, 34, 35, 36, 37, 38], 0, 4, [4, 4]),
            ([41, 42, 43, 44, 45, 46, 47, 48, 49, 50], 1, 3, [2, 3, 3, 2]),
            ([51, 52, 53, 54, 55], 4, 4, [4, 1]),
        ]

        for item in cases {
            let partitions = OmiSamplePartitioner.partitions(
                samples: item.samples,
                alreadyWritten: item.alreadyWritten,
                sampleLimit: item.sampleLimit
            )

            XCTAssertEqual(partitions.map(\.count), item.counts)
            XCTAssertEqual(partitions.flatMap(Array.init), item.samples)
            XCTAssertTrue(partitions.allSatisfy { !$0.isEmpty })
            XCTAssertTrue(partitions.allSatisfy { $0.count <= item.sampleLimit })
            if let first = partitions.first, item.alreadyWritten < item.sampleLimit {
                XCTAssertLessThanOrEqual(first.count, item.sampleLimit - item.alreadyWritten)
            }
        }
    }

    func testAlreadyWrittenAboveLimitStartsWithFreshChunk() {
        let samples: [Int16] = [61, 62, 63, 64, 65]
        let partitions = OmiSamplePartitioner.partitions(
            samples: samples,
            alreadyWritten: 7,
            sampleLimit: 4
        )

        XCTAssertEqual(partitions.map(\.count), [4, 1])
        XCTAssertEqual(partitions.flatMap(Array.init), samples)
        XCTAssertTrue(partitions.allSatisfy { !$0.isEmpty && $0.count <= 4 })
    }
}
