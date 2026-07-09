// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ShareImportSaveBodyTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportSaveBodyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        super.tearDown()
    }

    @MainActor
    func testSaveBodiesMatchGoldenFixturesAfterBoundaryNormalization() throws {
        for name in ["quick-text", "jpeg", "pdf", "m4a"] {
            let fixture = try self.fixture(named: name)
            let expected = try Data(contentsOf: try self.fixtureURL(name: name, suffix: "save.body"))
            let payload = try self.payload(fromSaveBody: expected, fixture: fixture)
            let kind: TransferPayloadKind = fixture.source == "quick" ? .text : .file
            let item = try self.storedItem(fixture: fixture, payload: payload, kind: kind, phase: .savePending)

            let actual = try ShareImportSaveBody.build(
                item: item.item,
                spool: item.spool,
                observerHandle: "observer-fixture-handle"
            )

            XCTAssertEqual(
                self.normalizedSaveBody(actual, itemID: fixture.itemID),
                self.normalizedSaveBody(expected, itemID: fixture.itemID),
                name
            )
        }
    }

    @MainActor
    func testStartBodiesMatchGoldenFixturesExactly() throws {
        for name in ["quick-text", "jpeg", "pdf", "m4a"] {
            let fixture = try self.fixture(named: name)
            let expected = try Data(contentsOf: try self.fixtureURL(name: name, suffix: "start.body"))
            let saveBody = try Data(contentsOf: try self.fixtureURL(name: name, suffix: "save.body"))
            let payload = try self.payload(fromSaveBody: saveBody, fixture: fixture)
            let kind: TransferPayloadKind = fixture.source == "quick" ? .text : .file
            let item = try self.storedItem(fixture: fixture, payload: payload, kind: kind, phase: .startPending)

            let actual = try DefaultTransferBodyBuilder.build(item: item.item, spool: item.spool)

            XCTAssertEqual(actual, expected, name)
        }
    }

    @MainActor
    func testAdoptedSaveBodyClientItemIDMatchesGoldenFixtureBytes() async throws {
        let fixture = try self.fixture(named: "quick-text")
        let itemID = try XCTUnwrap(UUID(uuidString: fixture.itemID))
        let storeRoot = self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: storeRoot, now: { Self.baseDate })
        _ = try ShareImportLegacyTestSupport.writeLegacyItem(
            root: storeRoot,
            itemID: itemID,
            source: fixture.source,
            raw: Data("adopted quick text".utf8),
            contentType: fixture.descriptorContentType,
            requestFilename: fixture.descriptorFilename,
            originalFilename: fixture.originalFilename
        )
        TransferURLProtocol.handler = { request, _ in
            (
                transferTestResponse(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/fixture/adopted","timestamp":"2026-07-09T00:00:00Z"}"#.utf8)
            )
        }
        let engine = TransferEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true)),
            transport: TransferTransport(
                sessionConfiguration: makeTransferTestURLSessionConfiguration(),
                authProvider: { _ in "test-transfer-key" }
            ),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            bodyBuilder: { item, spool in
                if item.manifest.saveThenStart?.phase == .savePending {
                    return try ShareImportSaveBody.build(item: item, spool: spool, observerHandle: "observer-fixture-handle")
                }
                return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
            }
        )
        try await engine.start()

        let unresolved = await store.adoptToTransfer(
            engine: engine,
            diagnosticLog: nil,
            quarantineRootURL: self.tempDirectory.appendingPathComponent("TransferQuarantine", isDirectory: true)
        )
        XCTAssertEqual(unresolved, 0)
        try await transferTestWaitFor("adopted share save body") {
            TransferURLProtocol.bodies.count == 1
        }

        let expected = try Data(contentsOf: try self.fixtureURL(name: "quick-text", suffix: "save.body"))
        let expectedClientItemID = try XCTUnwrap(self.multipartValue(named: "client_item_id", in: expected))
        let actualClientItemID = try XCTUnwrap(self.multipartValue(named: "client_item_id", in: TransferURLProtocol.bodies[0]))
        XCTAssertEqual(actualClientItemID, expectedClientItemID)
        XCTAssertEqual(actualClientItemID, fixture.itemID.lowercased())
    }

    private func storedItem(
        fixture: ShareImportBodyFixtureMetadata,
        payload: Data,
        kind: TransferPayloadKind,
        phase: TransferSaveThenStartPhase
    ) throws -> (spool: TransferSpool, item: TransferStoredItem) {
        let itemID = try XCTUnwrap(UUID(uuidString: fixture.itemID))
        let partID = kind == .text ? "text" : "file"
        let state: TransferSaveThenStartState
        switch phase {
        case .savePending:
            state = TransferSaveThenStartState(phase: .savePending)
        case .startPending:
            state = TransferSaveThenStartState(
                phase: .startPending,
                savedPath: fixture.savePath,
                savedTimestamp: fixture.saveTimestamp,
                recommendedAction: TransferRecommendedAction.start.rawValue
            )
        }
        let manifest = TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Date(timeIntervalSince1970: 1_783_536_000),
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: partID,
                    kind: kind,
                    relativePath: "raw.bin",
                    filename: fixture.descriptorFilename,
                    contentType: fixture.descriptorContentType
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: ImporterServerURL.savePath,
                startPath: ImporterServerURL.startPath,
                requiresAuth: false
            ),
            saveThenStart: state
        )
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent(fixture.itemID, isDirectory: true))
        let staged = try spool.stage(manifest: manifest, payloads: [partID: payload])
        return (spool, try spool.commitStagedItem(itemID: staged.item.manifest.itemID))
    }

    private func payload(fromSaveBody body: Data, fixture: ShareImportBodyFixtureMetadata) throws -> Data {
        let boundary = "Boundary-\(fixture.itemID)"
        let marker: Data
        if fixture.source == "quick" {
            marker = Data("Content-Disposition: form-data; name=\"text\"\r\n\r\n".utf8)
        } else {
            marker = Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(fixture.descriptorFilename)\"\r\nContent-Type: \(fixture.descriptorContentType)\r\n\r\n".utf8
            )
        }
        let startRange = try XCTUnwrap(body.range(of: marker), fixture.itemID)
        let payloadStart = startRange.upperBound
        let endMarker = Data("\r\n--\(boundary)".utf8)
        let payloadEnd = try XCTUnwrap(body[payloadStart...].range(of: endMarker)?.lowerBound, fixture.itemID)
        return Data(body[payloadStart..<payloadEnd])
    }

    private func normalizedSaveBody(_ body: Data, itemID: String) -> Data {
        var result = body
        let replacement = Data("Boundary-NORMALIZED".utf8)
        for token in ["Boundary-\(itemID)", "Boundary-\(itemID.uppercased())"] {
            let needle = Data(token.utf8)
            while let range = result.range(of: needle) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private func fixture(named name: String) throws -> ShareImportBodyFixtureMetadata {
        let data = try Data(contentsOf: try self.fixtureURL(name: name, suffix: "metadata.json"))
        return try JSONDecoder().decode(ShareImportBodyFixtureMetadata.self, from: data)
    }

    private func fixtureURL(name: String, suffix: String) throws -> URL {
        let resourceName = "\(name).\(suffix)"
        let resourceURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL, "test bundle resources are unavailable")
        let rootCandidate = resourceURL.appendingPathComponent(resourceName, isDirectory: false)
        if FileManager.default.fileExists(atPath: rootCandidate.path) {
            return rootCandidate
        }
        for directory in ["ShareImportBodies", "Fixtures/ShareImportBodies"] {
            let candidate = resourceURL
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(resourceName, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ShareImportFixtureError.missingFixture(resourceName)
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_783_536_000)
}

private enum ShareImportFixtureError: Error {
    case missingFixture(String)
}

private struct ShareImportBodyFixtureMetadata: Decodable {
    let descriptorContentType: String
    let descriptorFilename: String
    let itemID: String
    let originalFilename: String
    let savePath: String
    let saveTimestamp: String
    let source: String
}
