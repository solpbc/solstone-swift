// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OnThisPhoneDeliveryRefreshGrepTests: XCTestCase {
    func testEveryTransferSourceReloadsOwnerSnapshotWhenDeliveryCompletes() throws {
        let viewURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/OnThisPhoneView.swift")
        let text = try String(contentsOf: viewURL, encoding: .utf8)

        for marker in [
            "mobileSegment: self.mobileSegmentTransferHolder.lastUploadAt",
            "omi: self.omiUploaderHolder.lastUploadAt",
            "watch: self.watchUploaderHolder.lastUploadAt",
            "share: self.shareTransferHolder.lastUploadAt",
        ] {
            XCTAssertTrue(
                text.contains(marker),
                "missing delivered-state marker: \(marker)"
            )
        }

        XCTAssertTrue(text.contains(".onChange(of: self.deliveryMarkers)"))
        XCTAssertEqual(
            text.components(separatedBy: "loadSnapshot(trigger: .delivery)").count - 1,
            1
        )
    }
}
