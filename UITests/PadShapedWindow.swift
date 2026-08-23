// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

/// True when the app is running in an iPad-shaped window.
///
/// `make ci` and `make ci-ipad` run the identical test set -- there is no test plan and no
/// `-only-testing` -- so every test written against the phone shell also runs on an iPad
/// simulator. Several of them assert behaviour that is correctly different there, and this is
/// how they are scoped rather than deleted. They stay live on the iPhone lane, which is the lane
/// whose behaviour they describe.
///
/// Measured on the window rather than on `UIDevice.current.userInterfaceIdiom` so it is usable
/// from a nonisolated context. iPad Pro 13-inch is 1032 x 1376; iPhone 17 Pro is 402 x 874 in
/// either orientation, so the short edge separates them with wide margin.
///
/// One definition, one threshold. A second copy would drift.
func UITestsIsPadShapedWindow(_ app: XCUIApplication) -> Bool {
    let frame = app.windows.firstMatch.frame
    return min(frame.width, frame.height) >= 700
}
