// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SourceStateMappingTests: XCTestCase {
    func testObserverStatesMapToSourceStates() {
        XCTAssertEqual(sourceState(for: .idle, paused: false), .off)
        XCTAssertEqual(sourceState(for: .starting, paused: false), .enrolling)
        XCTAssertEqual(sourceState(for: .active(Self.session()), paused: false), .active)
        XCTAssertEqual(sourceState(for: .stopping, paused: false), .active)
        XCTAssertEqual(sourceState(for: .error(.permissionDenied), paused: false), .needsAttention)
        XCTAssertEqual(sourceState(for: .error(.diskFull), paused: false), .needsAttention)
        XCTAssertEqual(sourceState(for: .idle, paused: true), .paused)
    }

    private static func session() -> ObserverSession {
        ObserverSession(
            sessionID: UUID(),
            mode: .meeting,
            startedAt: Date(),
            currentChunkIndex: 0,
            elapsed: 0
        )
    }
}
