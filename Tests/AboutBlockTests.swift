// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import CryptoKit
import Foundation
import XCTest

nonisolated final class AboutBlockTests: XCTestCase {
    func testContractFixturesAndUnknownVersionBehavior() throws {
        let contract = try Self.decode(ContractFixture.self, named: "contract")
        for fixture in contract.fixtures {
            XCTAssertEqual(
                AboutBlock.line(
                    name: "journal",
                    version: fixture.version,
                    build: fixture.build ?? "",
                    os: fixture.os,
                    osVersion: fixture.osVersion,
                    arch: fixture.arch
                ),
                fixture.about
            )
        }

        let resources = try Self.decode(ResourcesFixture.self, named: "resources")
        XCTAssertEqual(
            AboutBlock.line(name: "journal", version: ""),
            resources.behavior.unknownVersion
        )
    }

    func testLeadingVArchAliasesAndOmittedFacts() {
        XCTAssertEqual(
            AboutBlock.line(name: "ios app", version: "vv2.4", arch: "aarch64"),
            AboutBlock.line(name: "ios app", version: "2.4", arch: "arm64")
        )
        XCTAssertEqual(
            AboutBlock.line(name: "ios app", version: "1", os: "ios", osVersion: "", arch: "x64"),
            AboutBlock.line(name: "ios app", version: "1", os: "ios", arch: "x86_64")
        )
        XCTAssertEqual(AboutBlock.line(name: "ios app", version: "1", os: "", osVersion: "17", arch: ""), "ios app 1")
        XCTAssertEqual(AboutBlock.line(name: "ios app", version: "1", os: "ios", osVersion: "", arch: ""), "ios app 1 · ios")
        XCTAssertEqual(AboutBlock.line(name: "ios app", version: "1", arch: "riscv64"), "ios app 1 · riscv64")
    }

    func testCurrentAndMissingObservationHaveNoFreshnessSuffix() {
        let observedAt: TimeInterval = 1_700_000_000
        let now = Date(timeIntervalSince1970: observedAt + 172_800)
        XCTAssertFalse(AboutBlock.line(
            name: "journal", version: "1", isCurrent: true, observedAt: observedAt, now: now
        ).contains("last seen"))
        XCTAssertFalse(AboutBlock.line(
            name: "journal", version: "1", isCurrent: false, observedAt: nil, now: now
        ).contains("last seen"))
    }

    func testDisconnectedLineUsesFixtureRelativeSuffix() throws {
        let native = try Self.jsonObject(named: "native-about")
        let invalid = try XCTUnwrap(native["invalid"] as? [[String: Any]])
        let fixtureLine = try XCTUnwrap(invalid.compactMap { $0["journal_line"] as? String }
            .first { $0.contains(" · last seen ") })
        let suffix = try XCTUnwrap(fixtureLine.components(separatedBy: " · last seen ").last)
        let observedAt: TimeInterval = 1_700_000_000
        let line = AboutBlock.line(
            name: "journal",
            version: "2.0.29",
            isCurrent: false,
            observedAt: observedAt,
            now: Date(timeIntervalSince1970: observedAt + 172_800)
        )
        XCTAssertTrue(line.hasSuffix(suffix))
    }

    func testBlockDropsEmptyLinesAndPreservesOrder() {
        let phone = AboutBlock.line(name: "ios app", version: "2")
        let journal = AboutBlock.line(name: "journal", version: "1")
        XCTAssertEqual(AboutBlock.block([phone, "", journal]), "\(phone)\n\(journal)")
    }

#if canImport(solstone_swift)
    @MainActor
    func testPhoneAssemblyOrdersLinesAndOmitsIneligibleWatch() throws {
        let suite = "AboutBlockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = JournalVersionMetadata(defaults: defaults) { _ in nil }
        metadata.setIdentity("identity")
        metadata.noteConnected(localPort: 7071)
        _ = metadata.applyValidated(name: "stored name", version: "1.2.3", pairingIdentity: "identity")
        metadata.acceptHostFacts(
            os: "ubuntu", osVersion: "24.04", arch: "x86_64", build: nil,
            identity: "identity", activePort: 7071, version: "1.2.3"
        )
        let now = Date()
        let phone = PhoneAboutBlock.iosAppLine()
        let journal = PhoneAboutBlock.journalLine(metadata: metadata, now: now)
        let watchFacts = WatchAboutFacts(marketingVersion: "4.0", build: "9", osVersion: "26")
        let watch = PhoneAboutBlock.watchLine(facts: watchFacts)

        XCTAssertEqual(
            PhoneAboutBlock.block(journalVersion: metadata, watchFacts: nil, now: now),
            AboutBlock.block([phone, journal])
        )
        XCTAssertEqual(
            PhoneAboutBlock.block(journalVersion: metadata, watchFacts: watchFacts, now: now),
            AboutBlock.block([phone, watch, journal])
        )
        XCTAssertFalse(journal.contains("stored name"))
    }
#endif

    func testJournalFactsAreRenderedByLine() throws {
        let contract = try Self.decode(ContractFixture.self, named: "contract")
        let fixture = try XCTUnwrap(contract.fixtures.first)
        XCTAssertEqual(
            AboutBlock.line(
                name: "journal",
                version: fixture.version,
                build: fixture.build ?? "",
                os: fixture.os,
                osVersion: fixture.osVersion,
                arch: fixture.arch
            ),
            fixture.about
        )
    }

    func testBundledBytesMatchManifestAndAdoptionRecord() throws {
        let bundle = Bundle(for: Self.self)
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "manifest", withExtension: "json"))
        let manifestData = try Data(contentsOf: manifestURL)
        XCTAssertEqual(Self.sha256(manifestData), "301c1d84616379e11aaf22bb341e524bb4b2317051ea08453db9fdd87c706ab0")

        let manifest = try JSONDecoder().decode(ManifestFixture.self, from: manifestData)
        XCTAssertEqual(Set(manifest.artifacts.keys), Set([
            "contract.json", "about.schema.json", "resources.json", "native-about.schema.json", "native-about.json"
        ]))
        for (filename, expectedHash) in manifest.artifacts {
            let artifactName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            let dataURL = try XCTUnwrap(bundle.url(forResource: artifactName, withExtension: "json"))
            let data = try Data(contentsOf: dataURL)
            XCTAssertEqual(Self.sha256(data), expectedHash, filename)
        }

        let adoptionURL = try XCTUnwrap(bundle.url(forResource: "adoption", withExtension: "json"))
        let adoptionData = try Data(contentsOf: adoptionURL)
        let adoptionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: adoptionData) as? [String: Any])
        XCTAssertEqual(Set(adoptionObject.keys), Set(["authority_commit", "manifest_sha256"]))
        let adoption = try JSONDecoder().decode(AdoptionFixture.self, from: adoptionData)
        XCTAssertEqual(adoption.authorityCommit, "ec1983799b66d3616708851d01803e4f3d6f0a20")
        XCTAssertEqual(adoption.manifestSHA256, Self.sha256(manifestData))
    }

    @MainActor
    func testWatchEqualRevisionNonceRequiresCachedIdentityAndVersion() throws {
        let name = "AboutBlockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = WatchJournalVersionState(defaults: defaults)
        let nonce = state.beginReachableSession()
        let base = WatchJournalVersionPayload(
            revision: 1,
            identity: "identity-a",
            version: "1.2.3",
            current: true,
            nonce: nil,
            versionObservedAt: 1_700_000_000,
            journalOS: nil,
            journalOSVersion: nil,
            journalArch: nil,
            journalBuild: nil
        )
        state.receive(try JSONEncoder().encode(base), live: false)

        let mismatched = WatchJournalVersionPayload(
            revision: 1,
            identity: "identity-b",
            version: "9.9.9",
            current: true,
            nonce: nonce,
            versionObservedAt: nil,
            journalOS: nil,
            journalOSVersion: nil,
            journalArch: nil,
            journalBuild: nil
        )
        state.receive(try JSONEncoder().encode(mismatched), live: true)
        XCTAssertEqual(state.version, "1.2.3")
        XCTAssertFalse(state.isCurrent)

        let matching = WatchJournalVersionPayload(
            revision: 1,
            identity: "identity-a",
            version: "1.2.3",
            current: true,
            nonce: nonce,
            versionObservedAt: nil,
            journalOS: nil,
            journalOSVersion: nil,
            journalArch: nil,
            journalBuild: nil
        )
        state.receive(try JSONEncoder().encode(matching), live: true)
        XCTAssertTrue(state.isCurrent)

        let replacement = WatchJournalVersionPayload(
            revision: 2,
            identity: "identity-c",
            version: "2.0.0",
            current: false,
            nonce: nil,
            versionObservedAt: 1_800_000_000,
            journalOS: "ubuntu",
            journalOSVersion: "24.04",
            journalArch: "x86_64",
            journalBuild: "42"
        )
        state.receive(try JSONEncoder().encode(replacement), live: false)
        XCTAssertEqual(state.version, "2.0.0")
        XCTAssertEqual(state.versionObservedAt, 1_800_000_000)
        XCTAssertEqual(state.journalOS, "ubuntu")
        XCTAssertEqual(state.journalOSVersion, "24.04")
        XCTAssertEqual(state.journalArch, "x86_64")
        XCTAssertEqual(state.journalBuild, "42")
    }

    func testLegacyWatchPayloadDecodesWithoutOptionalAboutFacts() throws {
        let payload = try JSONDecoder().decode(
            WatchJournalVersionPayload.self,
            from: Data(#"{"revision":1,"identity":"old","version":"1.0","current":false,"nonce":null}"#.utf8)
        )
        XCTAssertNil(payload.versionObservedAt)
        XCTAssertNil(payload.journalOS)
        XCTAssertNil(payload.journalOSVersion)
        XCTAssertNil(payload.journalArch)
        XCTAssertNil(payload.journalBuild)
    }
}

private extension AboutBlockTests {
    static func decode<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name,
            withExtension: "json"
        ))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func jsonObject(named name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name,
            withExtension: "json"
        ))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ContractFixture: Decodable {
    struct Example: Decodable {
        let version: String
        let build: String?
        let os: String
        let osVersion: String
        let arch: String
        let about: String
        enum CodingKeys: String, CodingKey {
            case version, build, arch, about
            case os = "os"
            case osVersion = "os_version"
        }
    }
    let fixtures: [Example]
}

private struct ResourcesFixture: Decodable {
    struct Behavior: Decodable {
        let unknownVersion: String
        enum CodingKeys: String, CodingKey { case unknownVersion = "unknown_version" }
    }
    let behavior: Behavior
}

private struct ManifestFixture: Decodable {
    let artifacts: [String: String]
}

private struct AdoptionFixture: Decodable {
    let authorityCommit: String
    let manifestSHA256: String
    enum CodingKeys: String, CodingKey {
        case authorityCommit = "authority_commit"
        case manifestSHA256 = "manifest_sha256"
    }
}
