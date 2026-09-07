// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

final class DeviceDescriptionSnapshotTests: XCTestCase {
    func testSanitizationAndFieldBounds() {
        let snapshot = DeviceDescriptionSnapshot.sanitize(
            name: "  iPhone of Alice  ",
            platform: "  ios  ",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )

        XCTAssertEqual(snapshot.name, "iPhone of Alice")
        XCTAssertEqual(snapshot.platform, "ios")
        XCTAssertEqual(snapshot.deviceType, "phone")
        XCTAssertEqual(snapshot.appID, "app.solstone.swift")
        XCTAssertEqual(snapshot.appVersion, "1.0.0")
    }

    func testControlCharactersRejected() {
        let snapshot = DeviceDescriptionSnapshot.sanitize(
            name: "Alice's\nPhone",
            platform: "ios\u{0000}",
            deviceType: "phone\t",
            appID: "app.solstone.swift",
            appVersion: "1.0.0\r\n"
        )

        XCTAssertNil(snapshot.name)
        XCTAssertNil(snapshot.platform)
        XCTAssertNil(snapshot.deviceType)
        XCTAssertEqual(snapshot.appID, "app.solstone.swift")
        XCTAssertNil(snapshot.appVersion)
    }

    func testOverBoundFieldsBecomeNullDoNotTruncate() {
        let name80 = String(repeating: "a", count: 80)
        let name81 = String(repeating: "a", count: 81)

        let field64 = String(repeating: "b", count: 64)
        let field65 = String(repeating: "b", count: 65)

        let snapshot = DeviceDescriptionSnapshot.sanitize(
            name: name80,
            platform: field64,
            deviceType: field65,
            appID: field64,
            appVersion: field65
        )

        XCTAssertEqual(snapshot.name, name80)
        XCTAssertEqual(snapshot.platform, field64)
        XCTAssertNil(snapshot.deviceType)
        XCTAssertEqual(snapshot.appID, field64)
        XCTAssertNil(snapshot.appVersion)

        let overNameSnapshot = DeviceDescriptionSnapshot.sanitize(
            name: name81,
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        XCTAssertNil(overNameSnapshot.name)
        XCTAssertEqual(overNameSnapshot.platform, "ios")
    }

    func testMultibyteUtf8Boundaries() {
        // "é" is 2 UTF-8 bytes
        let e40 = String(repeating: "é", count: 40) // 80 bytes
        let e41 = String(repeating: "é", count: 41) // 82 bytes
        let e32 = String(repeating: "é", count: 32) // 64 bytes
        let e33 = String(repeating: "é", count: 33) // 66 bytes

        let snapE = DeviceDescriptionSnapshot.sanitize(
            name: e40,
            platform: e32,
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        XCTAssertEqual(snapE.name, e40)
        XCTAssertEqual(snapE.platform, e32)

        let snapEOver = DeviceDescriptionSnapshot.sanitize(
            name: e41,
            platform: e33,
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        XCTAssertNil(snapEOver.name)
        XCTAssertNil(snapEOver.platform)

        // "你" is 3 UTF-8 bytes
        let ni26_plus2 = String(repeating: "你", count: 26) + "ab" // 26 * 3 + 2 = 80 bytes
        let ni27 = String(repeating: "你", count: 27) // 27 * 3 = 81 bytes
        let ni21_plus1 = String(repeating: "你", count: 21) + "a" // 21 * 3 + 1 = 64 bytes
        let ni22 = String(repeating: "你", count: 22) // 22 * 3 = 66 bytes

        let snapNi = DeviceDescriptionSnapshot.sanitize(
            name: ni26_plus2,
            platform: ni21_plus1,
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        XCTAssertEqual(snapNi.name, ni26_plus2)
        XCTAssertEqual(snapNi.platform, ni21_plus1)

        let snapNiOver = DeviceDescriptionSnapshot.sanitize(
            name: ni27,
            platform: ni22,
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        XCTAssertNil(snapNiOver.name)
        XCTAssertNil(snapNiOver.platform)
    }

    func testIdfvAbsenceProofInAsReported() throws {
        let snapshot = DeviceDescriptionSnapshot(
            name: "iPhone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )
        let reported = snapshot.asReported()
        let encoded = try JSONEncoder().encode(reported)
        let jsonString = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(jsonString.lowercased().contains("idfv"))
        XCTAssertFalse(jsonString.lowercased().contains("identifierforvendor"))
        XCTAssertFalse(jsonString.lowercased().contains("vendor"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let expectedKeys: Set<String> = ["name", "platform", "device_type", "app_id", "app_version"]
        XCTAssertEqual(Set(json.keys), expectedKeys)
    }

    func testIdiomMapping() {
        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.phone).platform, "ios")
        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.phone).deviceType, "phone")

        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.pad).platform, "ipados")
        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.pad).deviceType, "tablet")

        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.mac).platform, "macos")
        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.mac).deviceType, "desktop")

        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.vision).platform, "visionos")
        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.vision).deviceType, "headset")

        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.unspecified).platform, "ios")
        XCTAssertEqual(DeviceDescriptionSnapshot.mapUserInterfaceIdiom(.unspecified).deviceType, "unidentified")
    }

    func testAsReportedMapping() {
        let snapshot = DeviceDescriptionSnapshot(
            name: "My Phone",
            platform: "ios",
            deviceType: "phone",
            appID: "app.solstone.swift",
            appVersion: "1.0.0"
        )

        let reported = snapshot.asReported()
        XCTAssertEqual(reported.name, "My Phone")
        XCTAssertEqual(reported.platform, "ios")
        XCTAssertEqual(reported.deviceType, "phone")
        XCTAssertEqual(reported.appID, "app.solstone.swift")
        XCTAssertEqual(reported.appVersion, "1.0.0")
    }
}
