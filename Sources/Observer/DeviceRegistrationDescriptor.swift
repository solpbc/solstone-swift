// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit

nonisolated struct DeviceRegistrationDescriptor: Equatable, Sendable {
    let hostname: String
    let displayName: String
    let vendorIdentifier: String

    static func make(
        deviceName: String,
        model: String,
        isPad: Bool,
        identifierForVendor: UUID?
    ) -> Self? {
        guard let identifierForVendor else { return nil }
        let vendorIdentifier = identifierForVendor.uuidString.lowercased()
        return Self(
            hostname: "\(isPad ? "ipad" : "iphone")-\(vendorIdentifier)",
            displayName: self.displayName(
                deviceName: deviceName,
                model: model,
                identifierForVendor: identifierForVendor
            ),
            vendorIdentifier: vendorIdentifier
        )
    }

    static func displayName(
        deviceName: String,
        model: String,
        identifierForVendor: UUID?
    ) -> String {
        let cleanName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModel = cleanModel.isEmpty ? "device" : cleanModel
        if !cleanName.isEmpty,
           cleanName.compare(fallbackModel, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        {
            return cleanName
        }
        guard let identifierForVendor else { return fallbackModel }
        return "\(fallbackModel) (\(identifierForVendor.uuidString.prefix(4).uppercased()))"
    }

    @MainActor
    static func current() -> Self? {
        let device = UIDevice.current
        return self.make(
            deviceName: device.name,
            model: device.model,
            isPad: device.userInterfaceIdiom == .pad,
            identifierForVendor: device.identifierForVendor
        )
    }

    @MainActor
    static func currentDisplayName() -> String {
        let device = UIDevice.current
        return self.displayName(
            deviceName: device.name,
            model: device.model,
            identifierForVendor: device.identifierForVendor
        )
    }
}
