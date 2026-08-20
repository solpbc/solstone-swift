// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import UniformTypeIdentifiers
import XCTest

nonisolated final class ShareExtensionItemProviderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareExtensionItemProviderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    // Criterion 6
    @MainActor
    func testInPlaceAndFallbackNeverCallLoadFileRepresentation() async throws {
        let source = try self.makeFile(named: "share.pdf", data: Data("pdf-bytes".utf8))
        try await self.assertNeverLoadsFileRepresentation(source: source, isInPlace: true)
        try await self.assertNeverLoadsFileRepresentation(source: source, isInPlace: false)
    }

    @MainActor
    func testShortCopyIsNotSuccess() async throws {
        let source = try self.makeFile(named: "share.pdf", data: Data("full-payload-bytes".utf8))
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(
            cacheRootURL: queueRoot,
            payloadIO: ShortCopyPayloadIO()
        )
        let coordinator = ShareImportCoordinator(queue: store)
        let itemProvider = CountingItemProvider(fileURL: source, isInPlace: true)
        let provider = ShareExtensionItemProvider(provider: itemProvider)

        let result = await coordinator.accept(provider: provider)

        XCTAssertEqual(result, .failure(.unreadable))
        XCTAssertEqual(itemProvider.loadFileRepresentationCount, 0)
        let pending = queueRoot.appendingPathComponent("pending", isDirectory: true)
        if FileManager.default.fileExists(atPath: pending.path) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path), [])
        }
    }

    @MainActor
    private func assertNeverLoadsFileRepresentation(source: URL, isInPlace: Bool) async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let coordinator = ShareImportCoordinator(queue: store)
        let itemProvider = CountingItemProvider(fileURL: source, isInPlace: isInPlace)
        let provider = ShareExtensionItemProvider(provider: itemProvider)

        let result = await coordinator.accept(provider: provider)

        guard case .success = result else {
            XCTFail("expected success for isInPlace=\(isInPlace)")
            return
        }
        XCTAssertEqual(itemProvider.loadFileRepresentationCount, 0)
        XCTAssertEqual(itemProvider.loadInPlaceCount, 1)
    }

    private func makeFile(named name: String, data: Data) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

private final class CountingItemProvider: NSItemProvider, @unchecked Sendable {
    private var fileURL: URL
    private var offersInPlace: Bool
    private let lock = NSLock()
    private var fileRepresentationCount = 0
    private var inPlaceCount = 0

    var loadFileRepresentationCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.fileRepresentationCount
    }

    var loadInPlaceCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.inPlaceCount
    }

    override init() {
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        self.offersInPlace = false
        super.init()
    }

    convenience init(fileURL: URL, isInPlace: Bool) {
        self.init()
        self.fileURL = fileURL
        self.offersInPlace = isInPlace
    }

    override var registeredTypeIdentifiers: [String] {
        [UTType.pdf.identifier]
    }

    override func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> Progress {
        self.lock.lock()
        self.fileRepresentationCount += 1
        self.lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            completionHandler(self.fileURL, nil)
        }
        return Progress()
    }

    override func loadInPlaceFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (URL?, Bool, (any Error)?) -> Void
    ) -> Progress {
        self.lock.lock()
        self.inPlaceCount += 1
        self.lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            completionHandler(self.fileURL, self.offersInPlace, nil)
        }
        return Progress()
    }
}

private final class ShortCopyPayloadIO: ShareImportPayloadIO, @unchecked Sendable {
    private let base = FoundationShareImportPayloadIO()

    func byteCount(at url: URL) throws -> Int64 { try self.base.byteCount(at: url) }
    func itemDates(at url: URL) throws -> (created: Date?, modified: Date?) { try self.base.itemDates(at: url) }
    func importantUsageCapacity(at url: URL) throws -> Int64? { try self.base.importantUsageCapacity(at: url) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try Data("short".utf8).write(to: destinationURL)
    }
    func readWholeFile(at url: URL) throws -> Data { try self.base.readWholeFile(at: url) }
}
