// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class DeviceRegistrationDescriptorTests: XCTestCase {
    func testOwnerNameIsTrimmedForDisplayName() throws {
        let identifier = try XCTUnwrap(UUID(uuidString: "8F14E45F-EA4C-4F4C-AE91-7C3D84B7562A"))

        let displayName = DeviceRegistrationDescriptor.displayName(
            deviceName: "  Jeremie’s iPhone  ",
            model: "iPhone",
            identifierForVendor: identifier
        )

        XCTAssertEqual(displayName, "Jeremie’s iPhone")
    }

    func testGenericNamesUseShortDisplayFallback() throws {
        let identifier = try XCTUnwrap(UUID(uuidString: "8F14E45F-EA4C-4F4C-AE91-7C3D84B7562A"))
        let phone = DeviceRegistrationDescriptor.displayName(
            deviceName: "iPhone",
            model: "iPhone",
            identifierForVendor: identifier
        )
        let pad = DeviceRegistrationDescriptor.displayName(
            deviceName: "ipad",
            model: "iPad",
            identifierForVendor: identifier
        )

        XCTAssertEqual(phone, "iPhone (8F14)")
        XCTAssertEqual(pad, "iPad (8F14)")
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
