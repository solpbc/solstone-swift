// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit

nonisolated struct DeviceDescriptionSnapshot: Equatable, Sendable {
    let name: String?
    let platform: String?
    let deviceType: String?
    let appID: String?
    let appVersion: String?

    nonisolated static func mapUserInterfaceIdiom(_ idiom: UIUserInterfaceIdiom) -> (platform: String, deviceType: String) {
        switch idiom {
        case .phone:
            return ("ios", "phone")
        case .pad:
            return ("ipados", "tablet")
        case .mac:
            return ("macos", "desktop")
        case .vision:
            return ("visionos", "headset")
        default:
            return ("ios", "unidentified")
        }
    }

    @MainActor
    static func current() -> DeviceDescriptionSnapshot {
        let device = UIDevice.current
        let rawModel = device.model
        let rawName = device.name
        let (rawPlatform, rawDeviceType) = self.mapUserInterfaceIdiom(device.userInterfaceIdiom)

        let resolvedName: String?
        let sanitizedName = self.sanitize(rawName, maxBytes: 80)
        let sanitizedModel = self.sanitize(rawModel, maxBytes: 80)
        if let sanitizedName,
           let sanitizedModel,
           sanitizedName.compare(sanitizedModel, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            resolvedName = sanitizedName
        } else {
            resolvedName = sanitizedModel
        }

        let rawAppID = Bundle.main.bundleIdentifier
        let rawAppVersion = AppVersion.shortVersion == "?" ? nil : AppVersion.shortVersion

        return self.sanitize(
            name: resolvedName,
            platform: rawPlatform,
            deviceType: rawDeviceType,
            appID: rawAppID,
            appVersion: rawAppVersion
        )
    }

    static func sanitize(
        name: String?,
        platform: String?,
        deviceType: String?,
        appID: String?,
        appVersion: String?
    ) -> DeviceDescriptionSnapshot {
        DeviceDescriptionSnapshot(
            name: self.sanitize(name, maxBytes: 80),
            platform: self.sanitize(platform, maxBytes: 64),
            deviceType: self.sanitize(deviceType, maxBytes: 64),
            appID: self.sanitize(appID, maxBytes: 64),
            appVersion: self.sanitize(appVersion, maxBytes: 64)
        )
    }

    private static func sanitize(_ value: String?, maxBytes: Int) -> String? {
        guard let value else { return nil }

        // Reject control characters anywhere in the input value
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                return nil
            }
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Over-bound fields become null; do not truncate
        guard trimmed.utf8.count <= maxBytes else {
            return nil
        }
        return trimmed
    }

    func asReported() -> ClientsSelfReported {
        ClientsSelfReported(
            name: self.name,
            platform: self.platform,
            deviceType: self.deviceType,
            appID: self.appID,
            appVersion: self.appVersion
        )
    }
}
