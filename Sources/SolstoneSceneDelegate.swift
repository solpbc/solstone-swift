// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import os

private let sceneLog = Logger(subsystem: "app.solstone.swift", category: "scene")

@MainActor
final class SolstoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    struct WillConnectRecord {
        let sessionRoleRawValue: String
        let hadSizeRestrictions: Bool
        let appliedMinimumSize: CGSize?
    }

    static private(set) var lastWillConnect: WillConnectRecord?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        let windowScene = scene as? UIWindowScene
        let restrictions = windowScene?.sizeRestrictions
        let hadSizeRestrictions = restrictions != nil
        var appliedMinimumSize: CGSize?
        if let restrictions {
            // 420 x 600 is a provisional minimum; the number is unmeasured.
            let applied = CGSize(width: 420, height: 600)
            restrictions.minimumSize = applied
            appliedMinimumSize = applied
        }
        Self.lastWillConnect = WillConnectRecord(
            sessionRoleRawValue: session.role.rawValue,
            hadSizeRestrictions: hadSizeRestrictions,
            appliedMinimumSize: appliedMinimumSize
        )
        let appliedMinDescription = appliedMinimumSize == nil ? "none" : "set"
        sceneLog.info(
            "connected role=\(session.role.rawValue, privacy: .public) size-restrictions=\(hadSizeRestrictions) applied-min=\(appliedMinDescription, privacy: .public)"
        )
    }

    func preferredWindowingControlStyle(
        for windowScene: UIWindowScene
    ) -> UIWindowScene.WindowingControlStyle {
        UIWindowScene.WindowingControlStyle.automatic
    }
}
