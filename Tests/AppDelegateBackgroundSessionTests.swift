// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import UIKit
import XCTest

nonisolated final class AppDelegateBackgroundSessionTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateBackgroundSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testObserverIdentifierRoutesOnlyToObserverUploader() async {
        let appDelegate = AppDelegate()
        let observerUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("observer", isDirectory: true),
            startPathMonitor: false
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("queue", isDirectory: true),
            startPathMonitor: false
        )
        appDelegate.observerUploader = observerUploader
        appDelegate.importQueue = importQueue
        let completionCounter = CompletionCounter()

        appDelegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: ObserverUploader.backgroundSessionIdentifier
        ) {
            completionCounter.increment()
        }

        await Task.yield()
        XCTAssertEqual(completionCounter.value(), 0)
        importQueue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 0)
        observerUploader.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testOmiIdentifierRoutesOnlyToOmiUploader() async {
        let appDelegate = AppDelegate()
        let observerUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("observer", isDirectory: true),
            startPathMonitor: false
        )
        let omiUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("omi", isDirectory: true),
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("queue", isDirectory: true),
            startPathMonitor: false
        )
        appDelegate.observerUploader = observerUploader
        appDelegate.omiUploader = omiUploader
        appDelegate.importQueue = importQueue
        let completionCounter = CompletionCounter()

        appDelegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: OmiSegmentWriter.backgroundSessionIdentifier
        ) {
            completionCounter.increment()
        }

        await Task.yield()
        XCTAssertEqual(completionCounter.value(), 0)
        observerUploader.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 0)
        importQueue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 0)
        omiUploader.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testShareIdentifierRoutesOnlyToImportQueue() async {
        let appDelegate = AppDelegate()
        let observerUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("observer", isDirectory: true),
            startPathMonitor: false
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("queue", isDirectory: true),
            startPathMonitor: false
        )
        appDelegate.observerUploader = observerUploader
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
        observerUploader.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 0)
        importQueue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testRetiredLocationIdentifierCompletesImmediately() async {
        let appDelegate = AppDelegate()
        let observerUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("observer", isDirectory: true),
            startPathMonitor: false
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("queue", isDirectory: true),
            startPathMonitor: false
        )
        appDelegate.observerUploader = observerUploader
        appDelegate.importQueue = importQueue
        let completionCounter = CompletionCounter()

        appDelegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: "app.solstone.swift.location-upload"
        ) {
            completionCounter.increment()
        }

        await Task.yield()
        XCTAssertEqual(completionCounter.value(), 1)
        observerUploader.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
        importQueue.finishBackgroundEvents()
        XCTAssertEqual(completionCounter.value(), 1)
    }

    @MainActor
    func testUnknownIdentifierCompletesImmediately() {
        let appDelegate = AppDelegate()
        let completionCounter = CompletionCounter()

        appDelegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: "app.solstone.swift.unknown-upload"
        ) {
            completionCounter.increment()
        }

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
