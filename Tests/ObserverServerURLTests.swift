// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ObserverServerURLTests: XCTestCase {
    func testImporterURLsBuildKeylessRoutes() throws {
        XCTAssertEqual(ImporterServerURL.savePath, "/app/import/api/save")
        XCTAssertEqual(ImporterServerURL.startPath, "/app/import/api/start")
    }
}
