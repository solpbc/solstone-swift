// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiLaunchCaptureRecordTests: XCTestCase {
    func testHeaderLayoutUsesFixedOffsetsAndComputedHeaderByteCount() throws {
        let generation = UUID()
        let header = OmiLaunchCaptureHeader(
            generationID: generation,
            sequence: 42,
            acquiredAtUnixMicros: 1_800_000_000_123_456,
            declaredPayloadBytes: OmiLaunchCaptureFormat.maximumPayloadBytes
        ).encoded()

        XCTAssertEqual(header.count, OmiLaunchCaptureFormat.headerByteCount)
        XCTAssertEqual(header.prefix(OmiLaunchCaptureFormat.magic.count), OmiLaunchCaptureFormat.magic)
        let decoded = try XCTUnwrap(OmiLaunchCaptureHeader.decode(header).get())
        XCTAssertEqual(decoded.generationID, generation)
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.acquiredAtUnixMicros, 1_800_000_000_123_456)
        XCTAssertEqual(decoded.declaredPayloadBytes, OmiLaunchCaptureFormat.maximumPayloadBytes)
    }

    func testGenerationFilenameAndHeaderRoundTrip() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let generation = UUID()
        let url = OmiLaunchCaptureFormat.fileURL(rootURL: root, generationID: generation)
        XCTAssertEqual(OmiLaunchCaptureFormat.generationID(from: url), generation)
    }

    func testRecordTagChangesForPayloadMutation() {
        let header = OmiLaunchCaptureHeader(
            generationID: UUID(),
            sequence: 0,
            acquiredAtUnixMicros: 0,
            declaredPayloadBytes: 1
        ).encoded()
        XCTAssertNotEqual(
            OmiLaunchCaptureDigest.recordTag(header: header, payload: Data([1])),
            OmiLaunchCaptureDigest.recordTag(header: header, payload: Data([2]))
        )
    }

    func testUnixMicrosRoundTripIsStableForDeterministicPartitions() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.123_456)
        let micros = OmiLaunchCaptureLogic.unixMicros(date)
        XCTAssertEqual(micros / 300_000_000, 6_000_000)
        XCTAssertEqual(Date(timeIntervalSince1970: Double(micros) / 1_000_000), date)
    }
}
