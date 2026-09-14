// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import XCTest

final class MobileSegmentAudioContainerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        self.temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentAudioContainerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.temporaryDirectory)
        super.tearDown()
    }

    // AC3: Default transient pin on unrecognised error without I/O
    func testAudioContainerVerdictPureMappingDefaultsToUnknownOrTransient() {
        let unrecognisedError = NSError(domain: "UnrecognisedProbeDomain", code: 12345)
        let unrecognisedVerdict = MobileSegmentDuration.audioContainerVerdict(duration: nil, error: unrecognisedError)
        XCTAssertEqual(
            unrecognisedVerdict,
            .unknownOrTransient(domain: "UnrecognisedProbeDomain", code: 12345)
        )

        let permanentError = NSError(domain: AVFoundationErrorDomain, code: -11829)
        let permanentVerdict = MobileSegmentDuration.audioContainerVerdict(duration: nil, error: permanentError)
        XCTAssertEqual(
            permanentVerdict,
            .permanentlyUndecodable(domain: AVFoundationErrorDomain, code: -11829)
        )

        let validVerdict = MobileSegmentDuration.audioContainerVerdict(duration: 12.5, error: nil)
        XCTAssertEqual(validVerdict, .decodable(12.5))

        let nonFiniteVerdict = MobileSegmentDuration.audioContainerVerdict(duration: .nan, error: nil)
        XCTAssertEqual(nonFiniteVerdict, .decodable(nil))

        let zeroVerdict = MobileSegmentDuration.audioContainerVerdict(duration: 0, error: nil)
        XCTAssertEqual(zeroVerdict, .decodable(nil))
    }

    // AC4: Simulator I/O classification separates permanent ftyp-only from transient mode-000
    func testClassifyAudioContainerDistinguishesFtypOnlyFromUnreadableMode000() async throws {
        let ftypURL = self.temporaryDirectory.appendingPathComponent("ftyp_only.m4a")
        try MobileSegmentTestFixtures.writeFtypOnlyAudio(at: ftypURL)

        let ftypVerdict = await MobileSegmentDuration.classifyAudioContainer(at: ftypURL)
        XCTAssertEqual(
            ftypVerdict,
            .permanentlyUndecodable(domain: AVFoundationErrorDomain, code: -11829)
        )

        let unreadableURL = self.temporaryDirectory.appendingPathComponent("unreadable_mode000.m4a")
        try MobileSegmentTestFixtures.writeUnreadableRegularAudio(at: unreadableURL)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
        }

        let unreadableVerdict = await MobileSegmentDuration.classifyAudioContainer(at: unreadableURL)
        XCTAssertEqual(
            unreadableVerdict,
            .unknownOrTransient(domain: NSCocoaErrorDomain, code: 257)
        )
    }
}
