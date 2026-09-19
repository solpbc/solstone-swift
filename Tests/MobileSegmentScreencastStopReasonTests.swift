// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class MobileSegmentScreencastStopReasonTests: XCTestCase {
    func testStorageLowSentence() {
        XCTAssertEqual(
            MobileSegmentScreencastStopPolicy.ownerSentence(for: .storageLow),
            "screen stopped. this iphone is low on storage."
        )
        XCTAssertEqual(
            MobileSegmentScreencastStopPolicy.ownerSentence(for: .storageLow),
            SourceVocabulary.screencastStorageLowText
        )
    }

    func testMinimumFreeBytesFloor() {
        XCTAssertEqual(
            MobileSegmentScreencastStoragePolicy.minimumFreeBytes,
            1_000_000_000
        )
    }

    func testStopPolicyErrorCreation() {
        let error = MobileSegmentScreencastStopPolicy.stopError(for: .storageLow)
        XCTAssertEqual(error.domain, "app.solstone.swift.screencast")
        XCTAssertEqual(error.code, 100)
        XCTAssertEqual(
            error.userInfo[NSLocalizedDescriptionKey] as? String,
            "screen stopped. this iphone is low on storage."
        )
    }

    func testShouldErrorExitPolicy() {
        XCTAssertTrue(MobileSegmentScreencastStopPolicy.shouldErrorExit(for: .storageLow))
        XCTAssertTrue(MobileSegmentScreencastStopPolicy.shouldErrorExit(for: .appGroupUnavailable))
        XCTAssertTrue(MobileSegmentScreencastStopPolicy.shouldErrorExit(for: .finalizeTimeout))
        XCTAssertTrue(MobileSegmentScreencastStopPolicy.shouldErrorExit(for: .writerFailure))
        XCTAssertTrue(MobileSegmentScreencastStopPolicy.shouldErrorExit(for: .filesystemHandoffFailure))
        XCTAssertFalse(MobileSegmentScreencastStopPolicy.shouldErrorExit(for: .noVideo))
    }

    func testWriterSentencesArePairwiseUnequal() {
        let timeout = MobileSegmentScreencastStopPolicy.ownerSentence(for: .finalizeTimeout)
        let writer = MobileSegmentScreencastStopPolicy.ownerSentence(for: .writerFailure)
        let handoff = MobileSegmentScreencastStopPolicy.ownerSentence(for: .filesystemHandoffFailure)
        XCTAssertNotEqual(timeout, writer)
        XCTAssertNotEqual(timeout, handoff)
        XCTAssertNotEqual(writer, handoff)
    }

    func testAllReasonsHaveNonEmptyLowercaseFirstSentence() {
        for reason in MobileSegmentScreencastDiagnosticReason.allCases {
            let sentence = MobileSegmentScreencastStopPolicy.ownerSentence(for: reason)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertTrue(sentence.first?.isLowercase == true, "Sentence must start lowercase: \(sentence)")
        }
        let allRawValues = MobileSegmentScreencastDiagnosticReason.allCases.map(\.rawValue)
        XCTAssertFalse(allRawValues.contains("stale_or_missing_pointer"))
    }
}
