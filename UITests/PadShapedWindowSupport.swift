// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

extension XCTestCase {
    /// True when the app is running in an iPad-shaped window.
    ///
    /// `make ci` and `make ci-ipad` run the identical test set, so a test that
    /// describes one shell's behaviour has to say which lane it belongs to. The
    /// iPad renders a two-column split whose leading column is permanently the
    /// deck; the phone renders the shell those tests were written against. Tests
    /// that assert the phone shape are skipped here rather than deleted, and stay
    /// live on the lane whose behaviour they describe.
    ///
    /// The definition and the threshold live in `UITests/PadShapedWindow.swift`, so
    /// no call site can drift from it. This is the ergonomic form for the many test
    /// classes that need it.
    func isPadShapedWindow(_ app: XCUIApplication) -> Bool {
        UITestsIsPadShapedWindow(app)
    }
}
