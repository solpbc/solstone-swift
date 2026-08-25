// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AppIntents
import XCTest

@MainActor
final class ObserverManagerAppDependencyTests: XCTestCase {
    func testAppDependencyResolvesTheSingleRegisteredObserverManager() async throws {
        let registeredIdentifier = try XCTUnwrap(ObserverManagerDependencyRegistrationWitness.registeredIdentifier)
        XCTAssertEqual(ObserverManagerDependencyRegistrationWitness.registrationCount, 1)

        try await ObserverManagerDependencyResolutionIntent()(donate: false)

        XCTAssertEqual(ObserverManagerDependencyRegistrationWitness.resolvedIdentifier, registeredIdentifier)
    }
}

private struct ObserverManagerDependencyResolutionIntent: AppIntent {
    static var title: LocalizedStringResource { "observer manager dependency resolution" }

    @Dependency private var observerManager: ObserverManager

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let observerManager = self.observerManager
        await MainActor.run {
            ObserverManagerDependencyRegistrationWitness.recordResolution(of: observerManager)
        }
        return .result(value: "resolved")
    }
}
