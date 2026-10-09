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

    private func audioRecoveryFixtureURL(named filename: String) throws -> URL {
        let resourceURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL, "test bundle resources are unavailable")
        let candidates = [
            resourceURL.appendingPathComponent(filename, isDirectory: false),
            resourceURL.appendingPathComponent("AudioRecovery", isDirectory: true).appendingPathComponent(filename, isDirectory: false),
            resourceURL.appendingPathComponent("Fixtures/AudioRecovery", isDirectory: true).appendingPathComponent(filename, isDirectory: false),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        XCTFail("Fixture \(filename) not found in candidate paths: \(candidates)")
        throw CocoaError(.fileNoSuchFile)
    }

    func testRecoveryFixturesDurationAndClassification() async throws {
        let prefixURL = try self.audioRecoveryFixtureURL(named: "tail-complete-prefix.m4a")
        let moofURL = try self.audioRecoveryFixtureURL(named: "tail-cut-moof.m4a")
        let mdatURL = try self.audioRecoveryFixtureURL(named: "tail-cut-mdat.m4a")

        let inspector = PhoneAudioInspector.live

        // 1. tail-complete-prefix.m4a -> 9.916
        let prefixProbe = await MobileSegmentDuration.probeContainerDuration(at: prefixURL)
        XCTAssertEqual(try XCTUnwrap(prefixProbe), 9.916, accuracy: 1.0 / 16000)
        let prefixVerdict = await MobileSegmentDuration.classifyAudioContainer(at: prefixURL)
        if case .decodable(let dur) = prefixVerdict {
            XCTAssertEqual(try XCTUnwrap(dur), 9.916, accuracy: 1.0 / 16000)
        } else {
            XCTFail("Expected .decodable, got \(prefixVerdict)")
        }
        let prefixAudioFile = try AVAudioFile(forReading: prefixURL)
        XCTAssertEqual(Double(prefixAudioFile.length) / prefixAudioFile.processingFormat.sampleRate, 9.916, accuracy: 1.0 / 16000)
        let prefixInspect = await inspector.inspect(prefixURL)
        if case .duration(let dur) = prefixInspect {
            XCTAssertEqual(dur, 9.916, accuracy: 1.0 / 16000)
        } else {
            XCTFail("Expected inspect .duration, got \(prefixInspect)")
        }

        // 2. tail-cut-moof.m4a -> 9.916
        let moofProbe = await MobileSegmentDuration.probeContainerDuration(at: moofURL)
        XCTAssertEqual(try XCTUnwrap(moofProbe), 9.916, accuracy: 1.0 / 16000)
        let moofVerdict = await MobileSegmentDuration.classifyAudioContainer(at: moofURL)
        if case .decodable(let dur) = moofVerdict {
            XCTAssertEqual(try XCTUnwrap(dur), 9.916, accuracy: 1.0 / 16000)
        } else {
            XCTFail("Expected .decodable, got \(moofVerdict)")
        }
        let moofAudioFile = try AVAudioFile(forReading: moofURL)
        XCTAssertEqual(Double(moofAudioFile.length) / moofAudioFile.processingFormat.sampleRate, 9.916, accuracy: 1.0 / 16000)
        let moofInspect = await inspector.inspect(moofURL)
        if case .duration(let dur) = moofInspect {
            XCTAssertEqual(dur, 9.916, accuracy: 1.0 / 16000)
        } else {
            XCTFail("Expected inspect .duration, got \(moofInspect)")
        }

        // 3. tail-cut-mdat.m4a -> 10.876
        let mdatProbe = await MobileSegmentDuration.probeContainerDuration(at: mdatURL)
        XCTAssertEqual(try XCTUnwrap(mdatProbe), 10.876, accuracy: 1.0 / 16000)
        let mdatVerdict = await MobileSegmentDuration.classifyAudioContainer(at: mdatURL)
        if case .decodable(let dur) = mdatVerdict {
            XCTAssertEqual(try XCTUnwrap(dur), 10.876, accuracy: 1.0 / 16000)
        } else {
            XCTFail("Expected .decodable, got \(mdatVerdict)")
        }
        let mdatAudioFile = try AVAudioFile(forReading: mdatURL)
        XCTAssertEqual(Double(mdatAudioFile.length) / mdatAudioFile.processingFormat.sampleRate, 10.876, accuracy: 1.0 / 16000)
        let mdatInspect = await inspector.inspect(mdatURL)
        if case .duration(let dur) = mdatInspect {
            XCTAssertEqual(dur, 10.876, accuracy: 1.0 / 16000)
        } else {
            XCTFail("Expected inspect .duration, got \(mdatInspect)")
        }
    }
}
