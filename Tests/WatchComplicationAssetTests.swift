// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchComplicationAssetTests: XCTestCase {
    func testComplicationMarkAssetsExist() {
        let markNames = WatchComplicationMark.allCases.map { mark in
            let snapshot = WatchComplicationSnapshot(
                stateWord: "state",
                role: .calm,
                mark: mark,
                showsElapsed: false,
                sessionStartedAt: nil,
                handoffLine: nil,
                handoffSubtext: nil,
                handoffRole: nil,
                trustLine: nil
            )
            return watchComplicationMarkAssetName(for: snapshot)
        }
        let names = markNames + [watchComplicationMarkAssetName(for: nil)]

        XCTAssertEqual(Set(names).count, 4)

        let root = StringLiteralGrepSupport.worktreeRoot()
        for name in Set(names) {
            let imageset = root.appendingPathComponent(
                "SolstoneWatchComplication/Assets.xcassets/\(name).imageset",
                isDirectory: true
            )
            var isDirectory = ObjCBool(false)

            XCTAssertTrue(
                FileManager.default.fileExists(atPath: imageset.path, isDirectory: &isDirectory),
                "\(name).imageset should exist"
            )
            XCTAssertTrue(isDirectory.boolValue, "\(name).imageset should be a directory")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: imageset.appendingPathComponent("Contents.json").path
                ),
                "\(name).imageset should contain Contents.json"
            )
        }
    }
}
