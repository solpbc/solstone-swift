// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import XCTest

final class I18nPilotGalleryTests: XCTestCase {
    func testPseudolocaleScreenshot() {
        let app=XCUIApplication()
        app.launchArguments=["--ui-test","--i18n-pilot-gallery"]
        app.launch()
        XCTAssertTrue(app.scrollViews["i18n-pilot.gallery"].waitForExistence(timeout:30))
        let first=app.staticTexts["i18n-pilot.0"]
        XCTAssertTrue(first.label.hasPrefix("["),first.label)
        let shot=XCTAttachment(screenshot:app.screenshot())
        shot.name="source-sync-en-XA";shot.lifetime = .keepAlways
        add(shot)
    }
}
