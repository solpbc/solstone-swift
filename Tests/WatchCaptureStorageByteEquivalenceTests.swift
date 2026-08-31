// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchCaptureStorageByteEquivalenceTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchCaptureStorageByteEquivalenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
        self.root = nil
    }

    func testEmptyFixtureBytesMatchActorOutput() async throws {
        try await self.assertScenarioBytes(.empty)
    }

    func testOneSegmentFixtureBytesMatchActorOutput() async throws {
        try await self.assertScenarioBytes(.oneSegment)
    }

    func testSeveralSegmentsFixtureBytesMatchActorOutput() async throws {
        try await self.assertScenarioBytes(.severalSegments)
    }

    func testMixedStateFixtureBytesMatchActorOutput() async throws {
        try await self.assertScenarioBytes(.mixedState)
    }

    func testMixedStateMutationAndTransferTraceMatchesPreActorFixture() async throws {
        let recorder = FixtureTraceRecorder(rootURL: self.root)
        let writer = RecordingWatchFileWriter(rootURL: self.root, recorder: recorder)
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        let actor = WatchCaptureStorageActor(paths: paths, fileWriter: writer)
        let session = MockWatchConnectivitySession()
        session.activationState = .activated

        try self.seedTraceScenario(at: self.root)
        self.seedOutstandingTransfer(on: session)
        session.transferredFiles.removeAll()
        session.onTransferFile = { [weak recorder] url, metadata in
            recorder?.recordTransferFile(url: url, metadata: metadata)
        }

        let sender = WatchRelaySender(
            paths: paths,
            storageActor: actor,
            session: session,
            clock: { Self.traceClock }
        )

        // This is the durable portion of launch reconciliation before it asks the
        // relay sender to drain. It intentionally leaves the actor's extra read
        // checks visible in `rawEvents`; AC12 freezes only mutations and transfer.
        _ = try await actor.readSessionRecord(transactionClass: .maintenance)
        _ = await actor.scanCatalog(transactionClass: .maintenance)
        _ = await actor.scanCatalog(transactionClass: .maintenance)
        await sender.requestDrain(trigger: .launchReconciliation)

        let expected = try self.traceFixture()
        let rawEvents = recorder.events
        XCTAssertGreaterThan(rawEvents.count, expected.events.count)

        let expectedMutations = expected.events.compactMap(FixtureTraceEvent.mutationProjection)
        let actualMutations = rawEvents.compactMap(FixtureTraceEvent.mutationProjection)
        XCTAssertEqual(actualMutations, expectedMutations)

        self.assertBundleWritePrecedesTransfer(
            expected.events,
            bundlePath: Self.traceBundlePath
        )
        self.assertBundleWritePrecedesTransfer(
            rawEvents,
            bundlePath: Self.traceBundlePath
        )
        self.assertBundleWritePrecedesTransfer(
            expectedMutations,
            bundlePath: Self.traceBundlePath
        )
        self.assertBundleWritePrecedesTransfer(
            actualMutations,
            bundlePath: Self.traceBundlePath
        )
        XCTAssertEqual(session.transferredFiles.count, 1)
    }
}

private extension WatchCaptureStorageByteEquivalenceTests {
    enum Scenario: String, CaseIterable {
        case empty = "empty"
        case oneSegment = "one-segment"
        case severalSegments = "several-segments"
        case mixedState = "mixed-state"

        var states: [WatchSegmentState] {
            switch self {
            case .empty:
                []
            case .oneSegment:
                [.queued]
            case .severalSegments:
                [.queued, .transferring, .delivered]
            case .mixedState:
                [.captured, .finalized, .queued, .transferring, .acked]
            }
        }
    }

    struct FixtureFile: Codable {
        let path: String
        let data: Data
    }

    struct TraceFixture: Codable {
        let events: [FixtureTraceEvent]
    }

    static let fixtureDate = Date(timeIntervalSince1970: 1_735_689_600)
    static let traceClock = Date(timeIntervalSince1970: 1_735_690_500)
    static let traceBundlePath = ".relay-bundles/11111111-1111-1111-1111-111111111111.watchrelay"

    func assertScenarioBytes(
        _ scenario: Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let expected = try self.fixture(named: scenario.rawValue)
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter()
        )
        try await self.reconstruct(scenario, expected: expected, actor: actor)

        let actual = try self.visibleFiles(at: self.root)
        let expectedByPath = Dictionary(uniqueKeysWithValues: expected.map { ($0.path, $0.data) })
        XCTAssertEqual(Set(actual.keys), Set(expectedByPath.keys), file: file, line: line)
        for path in expectedByPath.keys.sorted() {
            XCTAssertEqual(actual[path], expectedByPath[path], "byte mismatch at \(path)", file: file, line: line)
        }
    }

    func reconstruct(
        _ scenario: Scenario,
        expected: [FixtureFile],
        actor: WatchCaptureStorageActor
    ) async throws {
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        let writer = FoundationWatchFileWriter()
        let sourceSizes = try self.sourceBytesBySegment(from: expected)

        for (offset, state) in scenario.states.enumerated() {
            let index = offset + 1
            let manifest = try self.fixtureManifest(index: index, state: state)
            let directory = try await actor.prepareSegmentDirectory(day: manifest.day, segment: manifest.segment)
            try await writer.writeData(
                Data("audio-\(manifest.id.uuidString)".utf8),
                to: paths.audioURL(directory: directory),
                options: .atomic
            )

            let locationURL = paths.locationURL(directory: directory)
            try await actor.openLocationLogHeader(at: locationURL)
            try await actor.appendLocationFix(Self.fixtureLocation, at: locationURL)
            let locationStats = try await actor.finalizeLocationLog(at: locationURL, armed: true)
            XCTAssertEqual(locationStats, WatchCaptureLocationLogFinalizedStats(fixCount: 1, gap: false))

            // Attempt persistence is actor-owned and requires a transferring
            // manifest. Restore the fixture's final state after preparing it.
            var transferring = manifest
            transferring.state = .transferring
            try await actor.writeManifest(transferring, ensuringDirectory: false)
            let catalog = await actor.scanCatalog(transactionClass: .maintenance)
            let transferEntry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == manifest.id })
            let bundleURL = self.root
                .appendingPathComponent(".relay-bundles", isDirectory: true)
                .appendingPathComponent("\(manifest.id.uuidString).watchrelay", isDirectory: false)
            let attempt = WatchRelayAttemptRecord(
                segmentID: manifest.id,
                generation: 1,
                attemptID: manifest.id,
                attemptStartedAt: Self.fixtureDate
            )
            let preparation = try await actor.prepareRelayTransfer(
                transferEntry,
                bundleURL: bundleURL,
                attempt: attempt
            )
            XCTAssertEqual(preparation.attempt, attempt)

            let sourceBytes = try XCTUnwrap(sourceSizes[manifest.id])
            try await writer.writeData(
                Data(repeating: 0, count: Int(sourceBytes)),
                to: bundleURL,
                options: .atomic
            )
            let recordedDiagnostics = await actor.recordRelayEnqueue(
                manifest: manifest,
                directoryURL: directory,
                bundleURL: bundleURL,
                at: Self.fixtureDate
            )
            XCTAssertTrue(recordedDiagnostics)
            try await actor.writeManifest(manifest, ensuringDirectory: false)
        }

        let expectedSnapshot = try XCTUnwrap(expected.first { $0.path == WatchComplicationSnapshot.fileName })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WatchComplicationSnapshot.self, from: expectedSnapshot.data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try await actor.writeComplicationSnapshot(
            encoder.encode(snapshot),
            to: self.root.appendingPathComponent(WatchComplicationSnapshot.fileName, isDirectory: false)
        )
    }

    func fixtureManifest(index: Int, state: WatchSegmentState) throws -> WatchSegmentManifest {
        let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
        return WatchSegmentManifest(
            id: id,
            day: "20250101",
            segment: String(format: "12000%d_300", index),
            startedAt: Self.fixtureDate.addingTimeInterval(Double(index) * 300),
            duration: 300,
            sensors: [.audio, .location],
            partial: false,
            lost: false,
            gap: false,
            fixCount: index,
            state: state,
            failureReason: nil
        )
    }

    func sourceBytesBySegment(from expected: [FixtureFile]) throws -> [UUID: Int64] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Dictionary(uniqueKeysWithValues: expected.compactMap { file in
            guard file.path.hasSuffix("/relay-diagnostics.json") else { return nil }
            let sidecar = try decoder.decode(WatchRelaySegmentDiagnosticsSidecar.self, from: file.data)
            return (sidecar.segmentID, try XCTUnwrap(sidecar.sourceBytes))
        })
    }

    func visibleFiles(at root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let relativePath = self.relativePath(child, from: root)
            if (try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for (path, data) in try self.visibleFiles(at: child) {
                    result["\(relativePath)/\(path)"] = data
                }
            } else {
                result[relativePath] = try Data(contentsOf: child)
            }
        }
        return result
    }

    func fixture(named name: String) throws -> [FixtureFile] {
        try JSONDecoder().decode([FixtureFile].self, from: Data(contentsOf: try self.fixtureURL(named: name)))
    }

    func traceFixture() throws -> TraceFixture {
        try JSONDecoder().decode(
            TraceFixture.self,
            from: Data(contentsOf: try self.fixtureURL(named: "mixed-state-trace"))
        )
    }

    func fixtureURL(named name: String) throws -> URL {
        let resourceURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let filename = "\(name).json"
        for directory in ["", "WatchCaptureStoragePreActor", "Fixtures/WatchCaptureStoragePreActor"] {
            let candidate = directory.isEmpty
                ? resourceURL.appendingPathComponent(filename, isDirectory: false)
                : resourceURL.appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw FixtureError.missing(filename)
    }

    func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    func seedTraceScenario(at root: URL) throws {
        let day = root.appendingPathComponent("20241231", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let states: [(UUID, String, WatchSegmentState, Date?)] = [
            (try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")), "163320_300", .queued, nil),
            (try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")), "163820_300", .transferring, nil),
            (try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333")), "164320_300", .delivered, Self.traceClock),
        ]
        for (offset, item) in states.enumerated() {
            let directory = day.appendingPathComponent(item.1, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = WatchSegmentManifest(
                id: item.0,
                day: "20241231",
                segment: item.1,
                startedAt: Date(timeIntervalSince1970: 1_735_688_000 + Double(offset) * 300),
                duration: 300,
                sensors: [.audio, .location],
                partial: false,
                lost: false,
                gap: false,
                fixCount: 1,
                state: item.2,
                failureReason: nil,
                deliveredAt: item.3
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: directory.appendingPathComponent("manifest.json", isDirectory: false),
                options: .atomic
            )
            try Data(repeating: 0x41, count: 13).write(
                to: directory.appendingPathComponent("audio.m4a", isDirectory: false),
                options: .atomic
            )
            try Data(repeating: 0x4C, count: 17).write(
                to: directory.appendingPathComponent("location.jsonl", isDirectory: false),
                options: .atomic
            )
        }
    }

    func seedOutstandingTransfer(on session: MockWatchConnectivitySession) {
        let id = "22222222-2222-2222-2222-222222222222"
        session.transferFile(
            self.root.appendingPathComponent("existing.watchrelay", isDirectory: false),
            metadata: ["id": id]
        )
    }

    func assertBundleWritePrecedesTransfer(
        _ events: [FixtureTraceEvent],
        bundlePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bundleWrite = events.firstIndex { event in
            event.kind == "writer"
                && event.method == "writeData"
                && event.path == bundlePath
                && event.phase == "returned"
        }
        let transfer = events.firstIndex { event in
            event.kind == "transferFile" && event.path == bundlePath
        }
        XCTAssertNotNil(bundleWrite, file: file, line: line)
        XCTAssertNotNil(transfer, file: file, line: line)
        if let bundleWrite, let transfer {
            XCTAssertLessThan(bundleWrite, transfer, file: file, line: line)
        }
    }

    func assertBundleWritePrecedesTransfer(
        _ events: [FixtureMutationEvent],
        bundlePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bundleWrite = events.firstIndex { event in
            event.kind == "writer"
                && event.method == "writeData"
                && event.path == bundlePath
                && event.phase == "returned"
        }
        let transfer = events.firstIndex { event in
            event.kind == "transferFile" && event.path == bundlePath
        }
        XCTAssertNotNil(bundleWrite, file: file, line: line)
        XCTAssertNotNil(transfer, file: file, line: line)
        if let bundleWrite, let transfer {
            XCTAssertLessThan(bundleWrite, transfer, file: file, line: line)
        }
    }

    static let fixtureLocation = WatchLocationFix(
        t: fixtureDate,
        lat: 40,
        lon: -105,
        hAcc: 5,
        alt: 1600,
        vAcc: 8,
        speed: 0,
        course: 0,
        stationary: true
    )
}

private extension WatchCaptureStorageByteEquivalenceTests {
    enum FixtureError: Error {
        case missing(String)
    }
}

private struct FixtureTraceEvent: Codable, Equatable, Sendable {
    let kind: String
    let method: String
    let path: String
    let phase: String
    let dataDescription: String?
    let metadata: String?
    let segmentID: String?
    let sequence: Int?

    init(
        kind: String,
        method: String,
        path: String,
        phase: String,
        dataDescription: String? = nil,
        metadata: String? = nil,
        segmentID: String? = nil,
        sequence: Int? = nil
    ) {
        self.kind = kind
        self.method = method
        self.path = path
        self.phase = phase
        self.dataDescription = dataDescription
        self.metadata = metadata
        self.segmentID = segmentID
        self.sequence = sequence
    }

    static func mutationProjection(_ event: FixtureTraceEvent) -> FixtureMutationEvent? {
        if event.kind == "transferFile" {
            return FixtureMutationEvent(
                kind: event.kind,
                method: event.method,
                path: event.path,
                phase: event.phase,
                dataDescription: event.dataDescription,
                metadata: event.metadata,
                segmentID: event.segmentID
            )
        }
        guard event.kind == "writer", Self.mutatingMethods.contains(event.method) else { return nil }
        return FixtureMutationEvent(
            kind: event.kind,
            method: event.method,
            path: event.path,
            phase: event.phase,
            dataDescription: event.dataDescription,
            metadata: nil,
            segmentID: nil
        )
    }

    private static let mutatingMethods: Set<String> = [
        "writeData",
        "appendLine",
        "atomicReplaceFile",
        "removeItem",
        "moveItem",
        "createDirectory",
        "createFileIfNeeded",
    ]
}

private struct FixtureMutationEvent: Equatable {
    let kind: String
    let method: String
    let path: String
    let phase: String
    let dataDescription: String?
    let metadata: String?
    let segmentID: String?
}

@MainActor
private final class FixtureTraceRecorder {
    private(set) var events: [FixtureTraceEvent] = []

    func recordWriter(
        method: String,
        path: String,
        phase: String,
        dataDescription: String? = nil
    ) {
        self.events.append(FixtureTraceEvent(
            kind: "writer",
            method: method,
            path: path,
            phase: phase,
            dataDescription: dataDescription
        ))
    }

    func recordTransferFile(url: URL, metadata: [String: Any]) {
        var normalized = metadata
        if normalized["attempt_id"] != nil {
            normalized["attempt_id"] = "<generated-attempt-id>"
        }
        let canonicalMetadata = String(
            data: (try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])) ?? Data(),
            encoding: .utf8
        )
        let id = normalized["id"] as? String
        self.events.append(FixtureTraceEvent(
            kind: "transferFile",
            method: "transferFile",
            path: self.relativePath(url),
            phase: "called",
            metadata: canonicalMetadata,
            segmentID: id
        ))
    }

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func relativePath(_ url: URL) -> String {
        let root = self.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != root else { return "." }
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }
}

private struct RecordingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private let rootURL: URL
    private let recorder: FixtureTraceRecorder

    init(rootURL: URL, recorder: FixtureTraceRecorder) {
        self.rootURL = rootURL
        self.recorder = recorder
    }

    func createDirectory(at url: URL) async throws {
        try await self.perform("createDirectory", at: url) {
            try await self.base.createDirectory(at: url)
        }
    }

    func createFileIfNeeded(at url: URL) async throws {
        try await self.perform("createFileIfNeeded", at: url) {
            try await self.base.createFileIfNeeded(at: url)
        }
    }

    func fileExists(at url: URL) async -> Bool {
        await self.recorder.recordWriter(method: "fileExists", path: self.relativePath(url), phase: "called")
        let value = await self.base.fileExists(at: url)
        await self.recorder.recordWriter(
            method: "fileExists",
            path: self.relativePath(url),
            phase: "returned",
            dataDescription: String(value)
        )
        return value
    }

    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        try await self.perform("itemKind", at: url, returned: { value in
            switch value {
            case .missing:
                return "missing"
            case .file:
                return "file"
            case .directory:
                return "directory"
            }
        }) {
            try await self.base.itemKind(at: url)
        }
    }

    func fileSize(at url: URL) async throws -> Int64 {
        try await self.perform("fileSize", at: url, returned: { "bytes:\($0)" }) {
            try await self.base.fileSize(at: url)
        }
    }

    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.perform("fileFingerprint", at: url) {
            try await self.base.fileFingerprint(at: url)
        }
    }

    func readData(from url: URL) async throws -> Data {
        try await self.perform("readData", at: url, returned: { "bytes:\($0.count)" }) {
            try await self.base.readData(from: url)
        }
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.perform("writeData", at: url, dataDescription: "bytes:\(data.count)") {
            try await self.base.writeData(data, to: url, options: options)
        }
    }

    func appendLine(_ line: Data, to url: URL) async throws {
        try await self.perform("appendLine", at: url, dataDescription: "bytes:\(line.count)") {
            try await self.base.appendLine(line, to: url)
        }
    }

    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.perform("atomicReplaceFile", at: url, dataDescription: "bytes:\(data.count)") {
            try await self.base.atomicReplaceFile(at: url, with: data)
        }
    }

    func removeItem(at url: URL) async throws {
        try await self.perform("removeItem", at: url) {
            try await self.base.removeItem(at: url)
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.perform("moveItem", at: sourceURL) {
            try await self.base.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.perform("contentsOfDirectory", at: url) {
            try await self.base.contentsOfDirectory(at: url)
        }
    }

    private func perform<Value: Sendable>(
        _ method: String,
        at url: URL,
        dataDescription: String? = nil,
        returned: @escaping @Sendable (Value) -> String? = { _ in nil },
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        await self.recorder.recordWriter(
            method: method,
            path: self.relativePath(url),
            phase: "called",
            dataDescription: dataDescription
        )
        do {
            let value = try await body()
            await self.recorder.recordWriter(
                method: method,
                path: self.relativePath(url),
                phase: "returned",
                dataDescription: dataDescription ?? returned(value)
            )
            return value
        } catch {
            await self.recorder.recordWriter(
                method: method,
                path: self.relativePath(url),
                phase: "threw",
                dataDescription: dataDescription
            )
            throw error
        }
    }

    private func relativePath(_ url: URL) -> String {
        let root = self.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != root else { return "." }
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }
}
