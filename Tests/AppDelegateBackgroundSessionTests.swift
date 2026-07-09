// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import UIKit
import XCTest

nonisolated final class AppDelegateBackgroundSessionTests: XCTestCase {
    @MainActor
    func testRetiredObservationIdentifierFallsThroughSafely() {
        let appDelegate = AppDelegate()
        let completionCounter = CompletionCounter()

        appDelegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: "app.solstone.swift.observer-upload"
        ) {
            completionCounter.increment()
        }

        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testShareIdentifierRoutesToImportQueue() async {
        let appDelegate = AppDelegate()
        let importQueue = ImportQueue(startPathMonitor: false)
        appDelegate.importQueue = importQueue
        let completionCounter = CompletionCounter()

        appDelegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: ImportQueue.backgroundSessionIdentifier
        ) {
            completionCounter.increment()
        }

        await Task.yield()
        XCTAssertEqual(completionCounter.value(), 0)
        importQueue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }
}

private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }

    func value() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }
}
