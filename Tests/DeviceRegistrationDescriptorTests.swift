// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class DeviceRegistrationDescriptorTests: XCTestCase {
    func testOwnerNameIsPresentationOnlyAndIDFVKeepsRegistrationUnique() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "8F14E45F-EA4C-4F4C-AE91-7C3D84B7562A"))
        let secondID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))

        let first = try XCTUnwrap(DeviceRegistrationDescriptor.make(
            deviceName: "  Jeremie’s iPhone  ",
            model: "iPhone",
            isPad: false,
            identifierForVendor: firstID
        ))
        let second = try XCTUnwrap(DeviceRegistrationDescriptor.make(
            deviceName: "Jeremie’s iPhone",
            model: "iPhone",
            isPad: false,
            identifierForVendor: secondID
        ))

        XCTAssertEqual(first.displayName, "Jeremie’s iPhone")
        XCTAssertEqual(second.displayName, first.displayName)
        XCTAssertEqual(first.hostname, "iphone-8f14e45f-ea4c-4f4c-ae91-7c3d84b7562a")
        XCTAssertEqual(second.hostname, "iphone-11111111-2222-3333-4444-555555555555")
        XCTAssertNotEqual(first.hostname, second.hostname)
    }

    func testGenericNamesUseShortFallbackAndPadHostname() throws {
        let identifier = try XCTUnwrap(UUID(uuidString: "8F14E45F-EA4C-4F4C-AE91-7C3D84B7562A"))
        let phone = try XCTUnwrap(DeviceRegistrationDescriptor.make(
            deviceName: "iPhone",
            model: "iPhone",
            isPad: false,
            identifierForVendor: identifier
        ))
        let pad = try XCTUnwrap(DeviceRegistrationDescriptor.make(
            deviceName: "ipad",
            model: "iPad",
            isPad: true,
            identifierForVendor: identifier
        ))

        XCTAssertEqual(phone.displayName, "iPhone (8F14)")
        XCTAssertEqual(phone.hostname, "iphone-8f14e45f-ea4c-4f4c-ae91-7c3d84b7562a")
        XCTAssertEqual(pad.displayName, "iPad (8F14)")
        XCTAssertEqual(pad.hostname, "ipad-8f14e45f-ea4c-4f4c-ae91-7c3d84b7562a")
        XCTAssertEqual(
            DeviceRegistrationDescriptor.displayName(
                deviceName: "",
                model: "iPhone",
                identifierForVendor: nil
            ),
            "iPhone"
        )
    }
}
