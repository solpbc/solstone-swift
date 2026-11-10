// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Crypto
import Foundation
import os
import XCTest

private final class DeliveryBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private actor ObsidianAcknowledgementBarrier {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { self.continuation != nil }
    func holdFirst() async {
        self.calls += 1
        if self.calls == 1 {
            await withCheckedContinuation { self.continuation = $0 }
        }
    }
    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

private actor ObsidianStatusReadBarrier {
    private var continuations: [String: CheckedContinuation<JournalStatusReport, Never>] = [:]
    func read(_ identity: String) async -> JournalStatusReport {
        await withCheckedContinuation { self.continuations[identity] = $0 }
    }
    func hasStarted(_ identity: String) -> Bool { self.continuations[identity] != nil }
    func finish(_ identity: String, report: JournalStatusReport) {
        self.continuations.removeValue(forKey: identity)?.resume(returning: report)
    }
}

private actor ObsidianVaultReadBarrier {
    private var continuations: [Int: CheckedContinuation<[ObsidianSameNameAdvisory]?, Never>] = [:]
    private(set) var count = 0
    func read() async -> [ObsidianSameNameAdvisory]? {
        self.count += 1
        let index = self.count
        return await withCheckedContinuation { self.continuations[index] = $0 }
    }
    func finish(_ index: Int, _ result: [ObsidianSameNameAdvisory]?) {
        self.continuations.removeValue(forKey: index)?.resume(returning: result)
    }
}

nonisolated final class ObsidianStubResolver: TransferEndpointResolver, Sendable {
    private let state: OSAllocatedUnfairLock<TransferEndpointResolution>

    init(_ resolution: TransferEndpointResolution) {
        self.state = OSAllocatedUnfairLock(initialState: resolution)
    }

    func set(_ resolution: TransferEndpointResolution) {
        self.state.withLock { $0 = resolution }
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        self.state.withLock { $0 }
    }

    func isCurrent(_ endpoint: TransferResolvedEndpoint) async -> Bool {
        self.state.withLock { $0 } == .available(endpoint)
    }
}

nonisolated final class ObsidianReportBox: Sendable {
    private let state: OSAllocatedUnfairLock<JournalStatusReport>

    init(_ report: JournalStatusReport) {
        self.state = OSAllocatedUnfairLock(initialState: report)
    }

    var value: JournalStatusReport {
        self.state.withLock { $0 }
    }

    func set(_ report: JournalStatusReport) {
        self.state.withLock { $0 = report }
    }
}

/// A stub journal URL protocol for Obsidian delivery tests.
nonisolated final class ObsidianIngestURLProtocol: URLProtocol, @unchecked Sendable {
    struct CustomResponse: Sendable {
        var statusCode: Int
        var data: Data
    }

    private struct State {
        var requests: [URLRequest] = []
        var ingestRequests: [Data] = []
        var vaultsRequestsCount = 0
        var statusResponse: (Int, Data) = (200, Data(#"{"version":{"current":"3.0.0"},"capabilities":["obsidian_notes"]}"#.utf8))
        var customIngestQueue: [CustomResponse] = []
        var customVaultsResponse: (Int, Data)? = nil
        var defaultIngestResponse: CustomResponse? = nil
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset() {
        self.state.withLock { $0 = State() }
    }

    static var vaultsRequestsCount: Int {
        self.state.withLock { $0.vaultsRequestsCount }
    }

    static var ingestRequests: [Data] {
        self.state.withLock { $0.ingestRequests }
    }

    static func setStatusResponse(statusCode: Int, data: Data) {
        self.state.withLock { $0.statusResponse = (statusCode, data) }
    }

    static func queueIngestResponse(statusCode: Int, data: Data) {
        self.state.withLock { $0.customIngestQueue.append(CustomResponse(statusCode: statusCode, data: data)) }
    }

    static func setDefaultIngestResponse(statusCode: Int, data: Data) {
        self.state.withLock { $0.defaultIngestResponse = CustomResponse(statusCode: statusCode, data: data) }
    }

    static func setVaultsResponse(statusCode: Int, data: Data) {
        self.state.withLock { $0.customVaultsResponse = (statusCode, data) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.extractBody(from: self.request)
        let path = self.request.url?.path ?? ""

        Self.state.withLock { state in
            state.requests.append(self.request)
            if path == "/app/devices/ingest" {
                state.ingestRequests.append(body)
            } else if path == "/app/devices/ingest/obsidian/vaults" {
                state.vaultsRequestsCount += 1
            }
        }

        let statusCode: Int
        let data: Data

        if path == "/api/system/status" {
            (statusCode, data) = Self.state.withLock { $0.statusResponse }
        } else if path == "/app/devices/ingest/obsidian/vaults" {
            if let custom = Self.state.withLock({ $0.customVaultsResponse }) {
                (statusCode, data) = custom
            } else {
                (statusCode, data) = (200, Data(#"{"vaults":[]}"#.utf8))
            }
        } else if path == "/app/devices/ingest" {
            let nextResponse = Self.state.withLock { state -> CustomResponse? in
                if !state.customIngestQueue.isEmpty {
                    return state.customIngestQueue.removeFirst()
                }
                return state.defaultIngestResponse
            }
            if let custom = nextResponse {
                statusCode = custom.statusCode
                data = custom.data
            } else {
                statusCode = 200
                data = transferTestMatchingReceipt(body: body, contentType: self.request.value(forHTTPHeaderField: "Content-Type"))
            }
        } else {
            statusCode = 200
            data = Data()
        }

        let response = HTTPURLResponse(url: self.request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func extractBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
final class ObsidianDeliveryRig {
    let root: URL
    let resolver: ObsidianStubResolver
    let report: ObsidianReportBox
    let mirror: TransferStatusMirror
    let engine: TransferEngine
    let gate: ObsidianCapabilityGate
    let holder: ObsidianTransferHolder

    static func endpoint(credential: String = "journal-a", port: Int = 7071) -> TransferResolvedEndpoint {
        TransferResolvedEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            port: port,
            dispatchOwner: TransferDispatchOwner(
                pairingGeneration: 1,
                ownerID: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!,
                credentialCID: credential
            )
        )
    }

    init(
        report: JournalStatusReport = .read(version: "3.0.0", capabilities: ["obsidian_notes"]),
        advisories: [ObsidianSameNameAdvisory]? = [],
        activeVaultID: String? = nil,
        bodyBuilder: TransferBodyBuilder? = nil,
        clock: any TransferClock = LiveTransferClock()
    ) async throws {
        self.root = URL(fileURLWithPath: "/var/tmp/obsidian_delivery_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.report = ObsidianReportBox(report)
        let resolver = ObsidianStubResolver(.available(Self.endpoint()))
        self.resolver = resolver

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObsidianIngestURLProtocol.self]
        ObsidianIngestURLProtocol.reset()

        let reportBox = self.report
        let gate = ObsidianCapabilityGate(
            readStatus: { _ in reportBox.value },
            fetchVaults: { _ in advisories },
            isCurrent: { await resolver.isCurrent($0) },
            retryDelay: .milliseconds(50)
        )
        self.gate = gate
        self.mirror = TransferStatusMirror()
        self.engine = TransferEngine(
            spool: TransferSpool(rootURL: self.root.appendingPathComponent("Transfers", isDirectory: true)),
            transport: TransferTransport(sessionConfiguration: configuration),
            endpointResolver: resolver,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [1], maxDelay: 300)),
            clock: clock,
            statusMirror: self.mirror,
            bodyBuilder: bodyBuilder ?? DefaultTransferBodyBuilder.build,
            sourceGate: self.gate
        )
        let holder = ObsidianTransferHolder(transferEngine: self.engine, mirror: self.mirror)
        holder.activeVaultID = activeVaultID
        holder.isEnabled = true
        holder.isPaused = false
        self.holder = holder

        let engine = self.engine
        // Receipt-only tests substitute a completed producer checkpoint. The
        // durable failure/relaunch test below installs the real source commit.
        await engine.registerObsidianAcknowledgementCommit { _, _, _ in }
        await self.gate.configure(
            isSourceEnabled: { [weak holder] in await holder?.isEnabled ?? true },
            isSourcePaused: { [weak holder] in await holder?.isPaused ?? false },
            activeVaultID: { [weak holder] in await holder?.activeVaultID },
            isAcceptedForSameName: { _, _ in true },
            wake: { await engine.kick() },
            publishCapability: { [weak holder] cap in Task { @MainActor in holder?.capability = cap } },
            publishAdvisory: { [weak holder] adv in Task { @MainActor in holder?.sameNameAdvisory = adv } }
        )
        try await self.engine.start()
        _ = await self.prime(vaultID: activeVaultID ?? "vault-1")
    }

    func prime(vaultID: String = "vault-1", folderName: String = "Notes") async -> Bool {
        let endpoint = Self.endpoint(credential: "journal-a")
        let manifest = ObsidianDeliveryTests.makeManifest(vaultID: vaultID, folderName: folderName)
        _ = await self.gate.admits(manifest: manifest, endpoint: endpoint)
        for _ in 0..<100 {
            if await self.gate.currentCapability != .unknown { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await self.gate.currentCapability == .listed
    }

    func tearDown() async {
        await self.engine.pause()
        try? FileManager.default.removeItem(at: self.root)
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(label)")
        throw CancellationError()
    }

    func enqueueObsidianItem(
        vaultID: String = "vault-1",
        folderName: String = "Notes",
        window: ObsidianWindow = ObsidianWindow(day: "20261108", segment: "094000_300"),
        lines: [ObsidianNoteLine]? = nil,
        noteIdentities: [String] = []
    ) async throws -> (ObsidianOutboxItem, URL) {
        let stamp = ObsidianStamp(epochSeconds: 1_700_000_000, timeZone: TimeZone(secondsFromGMT: -25200)!)
        let defaultLines = [
            ObsidianNoteLine(
                change: .changed,
                vault: folderName,
                path: "\(window.segment).md",
                changedAt: stamp,
                observedAt: stamp,
                text: "hello obsidian \(window.segment)\n",
                contentHash: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        ]
        let noteLines = lines ?? defaultLines
        let fullString = noteLines.map { $0.serialized() }.joined()
        let data = Data(fullString.utf8)
        let itemID = ObsidianWire.itemID(vaultID: vaultID, jsonlBytes: data)
        let filename = ObsidianWire.fileName(for: data)
        let sha256 = ObsidianWire.sha256Hex(data)
        let fileURL = self.root.appendingPathComponent("\(itemID.uuidString).jsonl")
        try data.write(to: fileURL)

        let createdAt = window.startDate(offsetSeconds: -25200) ?? Date(timeIntervalSince1970: 1_700_000_000)
        let item = ObsidianOutboxItem(
            itemID: itemID,
            filename: filename,
            window: window,
            createdAt: createdAt,
            lineCount: noteLines.count,
            byteCount: data.count,
            sha256Hex: sha256,
            timeZoneIdentifier: "America/Denver",
            offsetSeconds: -25200,
            vaultID: vaultID,
            folderName: folderName,
            noteIdentityHashes: noteIdentities
        )
        let manifest = ObsidianTransfer.manifest(for: item)
        _ = try await self.engine.enqueueIfAbsent(
            manifest: manifest,
            payloadFileURLs: [ObsidianTransfer.partID: fileURL]
        )
        return (item, fileURL)
    }

    func enqueueNonObsidianItem(sourceKey: String = "sample_src") async throws -> (TransferManifest, URL) {
        let itemID = UUID()
        let filename = "sample_file.jsonl"
        let data = Data("{\"sample\":true}\n".utf8)
        let fileURL = self.root.appendingPathComponent("\(itemID.uuidString).jsonl")
        try data.write(to: fileURL)

        let manifest = TransferManifest(
            itemID: itemID,
            source: sourceKey,
            createdAt: Date(),
            priority: TransferPriorityInputs(basePriority: .low, sourceKey: sourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "sample",
                    kind: .file,
                    relativePath: filename,
                    filename: filename,
                    contentType: "application/x-ndjson",
                    byteCount: data.count,
                    contentHash: "hash"
                )
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                platform: "ios",
                segment: "094000_300",
                day: "20261108",
                startedAt: Date(),
                durationS: 300,
                sources: [sourceKey],
                ingestProtocolVersion: 3,
                tz: "America/Denver",
                utcOffsetSeconds: -25200
            ),
            meta: .object(["test": .bool(true)])
        )
        _ = try await self.engine.enqueueIfAbsent(
            manifest: manifest,
            payloadFileURLs: ["sample": fileURL]
        )
        return (manifest, fileURL)
    }
}

@MainActor
final class ObsidianDeliveryTests: XCTestCase {
    private var testDir: URL!

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("expected asynchronous boundary was not reached")
        throw CancellationError()
    }

    func testSwitchingOpaqueVaultsWithTheSameNameInvalidatesFetchAndWarning() async throws {
        for finishBeforeSwitch in [false, true] {
            let selected = OSAllocatedUnfairLock(initialState: "A")
            let accepted = OSAllocatedUnfairLock(initialState: Set<String>())
            let reads = ObsidianVaultReadBarrier()
            let gate = ObsidianCapabilityGate(readStatus: { _ in .read(version: "2.0.73", capabilities: ["obsidian_notes"]) },
                fetchVaults: { _ in await reads.read() })
            await gate.configure(isSourceEnabled: { true }, isSourcePaused: { false },
                activeVaultID: { selected.withLock { $0 } },
                isAcceptedForSameName: { vault, token in accepted.withLock { $0.contains(vault + token) } },
                recordAcceptance: { vault, token in accepted.withLock { $0.insert(vault + token).inserted } },
                wake: {}, publishCapability: { _ in }, publishAdvisory: { _ in })
            let endpoint = ObsidianDeliveryRig.endpoint()
            let first = Self.makeManifest(vaultID: "A", folderName: "Notes")
            let second = Self.makeManifest(vaultID: "B", folderName: "Notes")
            _ = await gate.admits(manifest: first, endpoint: endpoint)
            try await self.waitUntil { await gate.currentCapability == .listed }
            _ = await gate.admits(manifest: first, endpoint: endpoint)
            try await self.waitUntil { await reads.count == 1 }
            let warning = [ObsidianSameNameAdvisory(vault: "Notes", device: "studio", lastSyncedAt: "2026-11-10T11:00:00Z")]
            if finishBeforeSwitch {
                await reads.finish(1, warning)
                try await self.waitUntil { await gate.currentAdvisory != nil }
            }
            selected.withLock { $0 = "B" }
            _ = await gate.admits(manifest: second, endpoint: endpoint)
            try await self.waitUntil { await reads.count == 2 }
            if !finishBeforeSwitch { await reads.finish(1, warning) }
            await reads.finish(2, warning)
            try await self.waitUntil { await gate.currentAdvisory != nil }
            await gate.continueSameName()
            let admitsSecond = await gate.admits(manifest: second, endpoint: endpoint)
            let admitsFirst = await gate.admits(manifest: first, endpoint: endpoint)
            XCTAssertTrue(admitsSecond)
            XCTAssertFalse(admitsFirst)
        }
    }

    func testMalformedVaultListHoldsAndNullableDeviceRemainsValid() async throws {
        let client = AuthenticatedHomeClient(sessionFactory: { _ in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ObsidianIngestURLProtocol.self]
            return URLSession(configuration: configuration)
        })
        for body in [#"{"vaults":[{"device":"studio"}]}"#,
                     #"{"vaults":[{"vault":"Notes","device":12,"last_synced_at":"2026-11-10T11:00:00Z"}]}"#,
                     #"{"vaults":[{"vault":"Notes","device":null}]}"#] {
            ObsidianIngestURLProtocol.setVaultsResponse(statusCode: 200, data: Data(body.utf8))
            let result = await client.fetchObsidianVaults(localPort: 7071)
            XCTAssertNil(result, body)
        }
        let valid = #"{"vaults":[{"vault":"Notes","device":null,"last_synced_at":"2026-11-10T11:00:00Z"}]}"#
        ObsidianIngestURLProtocol.setVaultsResponse(statusCode: 200, data: Data(valid.utf8))
        let result = await client.fetchObsidianVaults(localPort: 7071)
        XCTAssertEqual(result, [ObsidianSameNameAdvisory(vault: "Notes", device: nil, lastSyncedAt: "2026-11-10T11:00:00Z")])
        ObsidianIngestURLProtocol.setVaultsResponse(statusCode: 404, data: Data())
        let absent = await client.fetchObsidianVaults(localPort: 7071)
        XCTAssertEqual(absent, [])
    }

    func testAdoptedOfflineNotesRemainVisibleWithoutReopeningThePage() async throws {
        let rig = try await ObsidianDeliveryRig(activeVaultID: "waiting")
        rig.resolver.set(.unavailable("offline"))
        let store = ObsidianStore(rootURL: rig.root.appendingPathComponent("Source"))
        let source = ObsidianSourceEngine(store: store, delivery: ObsidianTransferDelivery(engine: rig.engine))
        let stamp = ObsidianStamp(epochSeconds: 1_700_000_100, timeZone: TimeZone(identifier: "America/Denver")!)
        var vault = ObsidianVaultState(id: "waiting", folderName: "Notes")
        vault.pendingChanges = [ObsidianPendingChange(change: .changed, vault: "Notes", path: "note.md",
            changedAt: stamp, observedAt: stamp, text: "note", contentHash: ObsidianWire.sha256Hex(Data("note".utf8)),
            logicalKey: "logical-note", windowKey: stamp.window.key)]
        store.document.vaults["waiting"] = vault
        store.document.selectedVaultID = "waiting"
        store.document.enabled = true
        try store.save()
        await source.closeDueWindowsAndDeliver()
        XCTAssertTrue(store.document.vaults["waiting"]?.outboxItems.isEmpty ?? false)
        XCTAssertEqual(source.status.pendingAndQueuedNotes, 1)
        let transfers = await rig.engine.itemSnapshots(sourceKey: "obsidian")
        XCTAssertEqual(transfers.count, 1)
        store.document.selectedVaultID = "other-vault"
        source.refreshStatus()
        XCTAssertTrue(source.status.hasHeldEarlierVault)
        await rig.tearDown()
    }

    func testAcknowledgedPayloadSurvivesFailedSourceCommitAndRelaunch() async throws {
        let clock = FakeTransferClock(wall: Date())
        let rig = try await ObsidianDeliveryRig(activeVaultID: "durable", clock: clock)
        let sourceRoot = rig.root.appendingPathComponent("Source")
        let store = ObsidianStore(rootURL: sourceRoot)
        var vault = ObsidianVaultState(id: "durable", folderName: "Notes")
        vault.table["note.md"] = ObsidianNoteRecord(path: "note.md", documentIdentifier: 1,
            mtimeMs: 0, sizeBytes: 4, contentHash: "hash", text: "note", logicalID: "logical-note", representedPath: "note.md")
        vault.foundNotesCount = 1
        vault.foundNoteIdentities = ["logical-note"]
        store.document.vaults["durable"] = vault
        store.document.selectedVaultID = "durable"
        try store.save()
        let source = ObsidianSourceEngine(store: store)
        source.journalIdentityProvider = { "journal-test" }
        await rig.engine.registerObsidianAcknowledgementCommit { manifest, kind, _ in
            try await source.commitDelivered(manifest: manifest, successKind: kind, journalIdentity: "journal-test")
        }
        store.testFailNextSave = true
        ObsidianIngestURLProtocol.setDefaultIngestResponse(statusCode: 200, data: Data(#"{"status":"ok"}"#.utf8))
        let (item, _) = try await rig.enqueueObsidianItem(vaultID: "durable", noteIdentities: ["logical-note"])
        try await rig.waitFor("source commit failure retained the acknowledged payload") {
            let snapshots = await rig.engine.itemSnapshots(sourceKey: "obsidian")
            return snapshots.first(where: { $0.itemID == item.itemID })?.nextAttemptAt != nil
        }
        let payload = rig.root.appendingPathComponent("Transfers/\(TransferSpool.queuedDirectoryName)/\(item.itemID.uuidString)/\(item.filename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(source.status.deliveredNotesCount, 0)
        XCTAssertTrue(ObsidianStore(rootURL: sourceRoot).document.vaults["durable"]?.acknowledgedNotesByJournal.isEmpty ?? false)
        await rig.engine.pause()

        clock.advanceWall(by: 61)
        let reopened = ObsidianSourceEngine(store: ObsidianStore(rootURL: sourceRoot))
        reopened.journalIdentityProvider = { "journal-test" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObsidianIngestURLProtocol.self]
        let reloaded = TransferEngine(spool: TransferSpool(rootURL: rig.root.appendingPathComponent("Transfers")),
            transport: TransferTransport(sessionConfiguration: configuration), endpointResolver: rig.resolver,
            clock: clock, sourceGate: rig.gate)
        await reloaded.registerObsidianAcknowledgementCommit { manifest, kind, _ in
            try await reopened.commitDelivered(manifest: manifest, successKind: kind, journalIdentity: "journal-test")
        }
        ObsidianIngestURLProtocol.setDefaultIngestResponse(statusCode: 200, data: Data(#"{"status":"duplicate","file_descriptors":[]}"#.utf8))
        try await reloaded.start()
        await reloaded.kick()
        try await rig.waitFor("duplicate replay durably committed progress before retiring bytes") {
            let snapshots = await reloaded.itemSnapshots(sourceKey: "obsidian")
            return snapshots.isEmpty && reopened.status.deliveredNotesCount == 1
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(ObsidianStore(rootURL: sourceRoot).document.vaults["durable"]?.acknowledgedNotesByJournal["journal-test"], ["logical-note"])
        await reloaded.pause()
        clock.resumeSleeps()
        await rig.tearDown()
    }

    func testInFlightVaultHeadBlocksLaterWindowWhileAnotherSourceCanDrain() async throws {
        let rig = try await ObsidianDeliveryRig(activeVaultID: "ordered")
        let barrier = ObsidianAcknowledgementBarrier()
        await rig.engine.registerObsidianAcknowledgementCommit { _, _, _ in await barrier.holdFirst() }
        _ = try await rig.enqueueObsidianItem(vaultID: "ordered")
        try await rig.waitFor("first request awaiting its durable commit") { await barrier.isWaiting }
        let (later, _) = try await rig.enqueueObsidianItem(vaultID: "ordered", window: ObsidianWindow(day: "20261108", segment: "094500_300"))
        let (other, _) = try await rig.enqueueNonObsidianItem()
        try await rig.waitFor("independent source made progress") {
            let snapshots = await rig.engine.itemSnapshots(sourceKey: other.sourceKey)
            return snapshots.isEmpty
        }
        let snapshots = await rig.engine.itemSnapshots(sourceKey: "obsidian")
        XCTAssertEqual(snapshots.first(where: { $0.itemID == later.itemID })?.attempts, 0)
        XCTAssertEqual(ObsidianIngestURLProtocol.ingestRequests.count, 2)
        await barrier.release()
        try await rig.waitFor("both ordered windows delivered") { rig.holder.deliveredCount == 2 }
        await rig.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        ObsidianIngestURLProtocol.reset()
        self.testDir = URL(fileURLWithPath: "/var/tmp/obsidian_delivery_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.testDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ObsidianIngestURLProtocol.reset()
        if let dir = self.testDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    static func makeManifest(
        vaultID: String,
        folderName: String = "Notes",
        sourceKey: String = ObsidianTransfer.sourceKey,
        itemID: UUID = UUID()
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: sourceKey,
            createdAt: Date(),
            priority: TransferPriorityInputs(basePriority: .low, sourceKey: sourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: ObsidianTransfer.partID,
                    kind: .file,
                    relativePath: "obsidian_test.jsonl",
                    filename: "obsidian_test.jsonl",
                    contentType: ObsidianTransfer.contentType,
                    byteCount: 100,
                    contentHash: "hash"
                )
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                platform: "ios",
                segment: "094000_300",
                day: "20261108",
                startedAt: Date(),
                durationS: 300,
                sources: [sourceKey],
                ingestProtocolVersion: 3,
                tz: "America/Denver",
                utcOffsetSeconds: -25200
            ),
            meta: .object([
                "vaultID": .string(vaultID),
                "folderName": .string(folderName),
                "notes": .int(1)
            ])
        )
    }

    // MARK: - 1. Receipt Verification: note_transcript.md and duplicate delivery

    func testNoteTranscriptAndDuplicateDeliverObsidianItemWhileNonObsidianMovesToAttention() async throws {
        let rig = try await ObsidianDeliveryRig(activeVaultID: "vault-rec")

        // 1. note_transcript.md descriptor on HTTP 200 ok
        let okReceiptWithTranscript = Data(#"{"status":"ok","file_descriptors":[{"submitted":"note_transcript.md","size":100,"sha256":"abc","disposition":"stored"}]}"#.utf8)
        ObsidianIngestURLProtocol.setDefaultIngestResponse(statusCode: 200, data: okReceiptWithTranscript)

        // Enqueue obsidian item: delivers because obsidian treats status "ok" as terminal success regardless of descriptor filenames
        let (obsItem1, _) = try await rig.enqueueObsidianItem(vaultID: "vault-rec")
        await rig.engine.kick()
        try await rig.waitFor("obsidian delivered on note_transcript.md ok") {
            rig.holder.deliveredCount == 1 && rig.holder.pendingCount == 0
        }
        let obsSnaps1 = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
        XCTAssertTrue(obsSnaps1.isEmpty || obsSnaps1.allSatisfy { $0.state != .attention })

        // Enqueue non-obsidian item with same ok response: moves to attention because submitted does not match expected part
        let (nonObsManifest1, _) = try await rig.enqueueNonObsidianItem(sourceKey: "sample_src")
        await rig.engine.kick()
        try await rig.waitFor("non-obsidian attention on mismatched descriptor") {
            let snaps = await rig.engine.itemSnapshots(sourceKey: "sample_src")
            return snaps.first?.state == .attention
        }
        let spoolRoot = rig.root.appendingPathComponent("Transfers", isDirectory: true)
        let attentionPayload1 = spoolRoot.appendingPathComponent(TransferSpool.attentionDirectoryName).appendingPathComponent(nonObsManifest1.itemID.uuidString).appendingPathComponent("sample_file.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attentionPayload1.path))

        // 2. Empty file_descriptors list on HTTP 200 duplicate
        let dupReceiptEmpty = Data(#"{"status":"duplicate","file_descriptors":[]}"#.utf8)
        ObsidianIngestURLProtocol.setDefaultIngestResponse(statusCode: 200, data: dupReceiptEmpty)

        // Enqueue second obsidian item: delivers
        let (obsItem2, _) = try await rig.enqueueObsidianItem(
            vaultID: "vault-rec",
            window: ObsidianWindow(day: "20261108", segment: "094500_300")
        )
        await rig.engine.kick()
        try await rig.waitFor("obsidian delivered on duplicate with empty descriptors") {
            rig.holder.deliveredCount == 2
        }

        // Enqueue second non-obsidian item with duplicate: moves to attention and keeps payload
        let (nonObsManifest2, _) = try await rig.enqueueNonObsidianItem(sourceKey: "sample_src2")
        await rig.engine.kick()
        try await rig.waitFor("non-obsidian attention on empty descriptors duplicate") {
            let snaps = await rig.engine.itemSnapshots(sourceKey: "sample_src2")
            return snaps.first?.state == .attention
        }
        let attentionPayload2 = spoolRoot.appendingPathComponent(TransferSpool.attentionDirectoryName).appendingPathComponent(nonObsManifest2.itemID.uuidString).appendingPathComponent("sample_file.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attentionPayload2.path))

        await rig.tearDown()
    }

    // MARK: - 2. Receipt Verification: Malformed body and non-ok status

    func testMalformedBodyAndUnrecognizedStatusDoNotDeliverObsidianPayload() async throws {
        ObsidianIngestURLProtocol.reset()
        let rig = try await ObsidianDeliveryRig(activeVaultID: "vault-malformed")

        // 1. Malformed body that does not decode
        ObsidianIngestURLProtocol.queueIngestResponse(statusCode: 200, data: Data("bad non json content".utf8))
        let (item1, _) = try await rig.enqueueObsidianItem(vaultID: "vault-malformed")
        await rig.engine.kick()
        try await rig.waitFor("malformed body moves obsidian item to attention or paced retry") {
            let snaps = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
            guard let snap1 = snaps.first(where: { $0.itemID == item1.itemID }) else { return false }
            return snap1.state == .attention || (snap1.state == .queued && snap1.attempts >= 1)
        }
        XCTAssertEqual(rig.holder.deliveredCount, 0)
        let spoolRoot = rig.root.appendingPathComponent("Transfers", isDirectory: true)
        let item1URL = spoolRoot.appendingPathComponent(TransferSpool.attentionDirectoryName).appendingPathComponent(item1.itemID.uuidString).appendingPathComponent(item1.filename)
        let queued1URL = spoolRoot.appendingPathComponent(TransferSpool.queuedDirectoryName).appendingPathComponent(item1.itemID.uuidString).appendingPathComponent(item1.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item1URL.path) || FileManager.default.fileExists(atPath: queued1URL.path))

        // 2. Status other than ok / duplicate / collision (e.g. "pending")
        let pendingStatusData = Data(#"{"status":"pending","file_descriptors":[]}"#.utf8)
        ObsidianIngestURLProtocol.queueIngestResponse(statusCode: 200, data: pendingStatusData)
        let (item2, _) = try await rig.enqueueObsidianItem(
            vaultID: "vault-malformed",
            window: ObsidianWindow(day: "20261108", segment: "094500_300")
        )
        await rig.engine.kick()
        try await rig.waitFor("non-ok status moves obsidian item to attention or paced retry") {
            let snaps = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
            guard let snap2 = snaps.first(where: { $0.itemID == item2.itemID }) else { return false }
            return snap2.state == .attention || (snap2.state == .queued && snap2.attempts >= 1)
        }
        XCTAssertEqual(rig.holder.deliveredCount, 0)
        let item2URL = spoolRoot.appendingPathComponent(TransferSpool.attentionDirectoryName).appendingPathComponent(item2.itemID.uuidString).appendingPathComponent(item2.filename)
        let queued2URL = spoolRoot.appendingPathComponent(TransferSpool.queuedDirectoryName).appendingPathComponent(item2.itemID.uuidString).appendingPathComponent(item2.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item2URL.path) || FileManager.default.fileExists(atPath: queued2URL.path))

        await rig.tearDown()
    }

    // MARK: - 3. Refusals: obsidian_note_ahead pacing and survival across relaunch

    func testObsidianNoteAheadStaysQueuedPersistsRetrySurvivesRelaunchAndBlocksLaterWindow() async throws {
        let clock = FakeTransferClock(wall: Date())
        let rig = try await ObsidianDeliveryRig(activeVaultID: "vault-ahead", clock: clock)

        // Set refusal 409 obsidian_note_ahead
        let aheadResponse = Data(#"{"status":"failed","error":"refused","reason_code":"obsidian_note_ahead"}"#.utf8)
        ObsidianIngestURLProtocol.setDefaultIngestResponse(statusCode: 409, data: aheadResponse)

        let (item1, _) = try await rig.enqueueObsidianItem(
            vaultID: "vault-ahead",
            window: ObsidianWindow(day: "20261108", segment: "094000_300")
        )
        let (item2, _) = try await rig.enqueueObsidianItem(
            vaultID: "vault-ahead",
            window: ObsidianWindow(day: "20261108", segment: "094500_300")
        )

        await rig.engine.kick()
        try await rig.waitFor("item 1 409 handled") {
            let snaps = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
            guard let snap1 = snaps.first(where: { $0.itemID == item1.itemID }) else { return false }
            return snap1.attempts >= 1 && snap1.nextAttemptAt != nil
        }

        for targetAttempt in 2...4 {
            clock.advanceWall(by: 2)
            await rig.engine.kick()
            try await rig.waitFor("oldest window completed retry \(targetAttempt)") {
                let snapshots = await rig.engine.itemSnapshots(sourceKey: "obsidian")
                return snapshots.first(where: { $0.itemID == item1.itemID }).map { $0.attempts >= targetAttempt && $0.nextAttemptAt != nil } ?? false
            }
        }
        let beforeRestart = await rig.engine.itemSnapshots(sourceKey: "obsidian")
        XCTAssertEqual(beforeRestart.first(where: { $0.itemID == item2.itemID })?.attempts, 0)

        // Stays queued and persists its next retry without mutating producer identity
        let snapsBeforeRelaunch = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
        let snap1 = try XCTUnwrap(snapsBeforeRelaunch.first(where: { $0.itemID == item1.itemID }))
        XCTAssertNotEqual(snap1.state, .attention)
        XCTAssertNotNil(snap1.nextAttemptAt)
        XCTAssertFalse(ObsidianTransfer.isLaneHeld(from: snap1.manifest))

        // Pause engine and create a new engine instance on the same spool
        let spoolURL = rig.root.appendingPathComponent("Transfers", isDirectory: true)
        await rig.engine.pause()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObsidianIngestURLProtocol.self]
        let newEngine = TransferEngine(
            spool: TransferSpool(rootURL: spoolURL),
            transport: TransferTransport(sessionConfiguration: configuration),
            endpointResolver: rig.resolver,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [1], maxDelay: 300)),
            clock: clock,
            statusMirror: rig.mirror,
            bodyBuilder: DefaultTransferBodyBuilder.build,
            sourceGate: rig.gate
        )
        try await newEngine.start()

        // Item 1 survived relaunch with its paced retry
        let reloadedSnaps = await newEngine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
        let reloadedItem1 = try XCTUnwrap(reloadedSnaps.first(where: { $0.itemID == item1.itemID }))
        let beforeRetry = try XCTUnwrap(snap1.nextAttemptAt)
        let reloadedRetry = try XCTUnwrap(reloadedItem1.nextAttemptAt)
        // Transfer's established ISO8601 spool contract stores whole seconds.
        XCTAssertEqual(reloadedRetry.timeIntervalSince1970, floor(beforeRetry.timeIntervalSince1970))

        // Later window of that vault is not eligible even after more than orderedRetryLimit (3) failures
        let reloadedItem2 = try XCTUnwrap(reloadedSnaps.first(where: { $0.itemID == item2.itemID }))
        XCTAssertEqual(reloadedItem2.attempts, 0)

        await newEngine.pause()
        clock.resumeSleeps()
        await rig.tearDown()
    }

    // MARK: - 4. Refusals: obsidian_note_invalid

    func testObsidianNoteInvalidMovesToAttentionAndLaterFileCanRun() async throws {
        let rig = try await ObsidianDeliveryRig(activeVaultID: "vault-invalid")

        let invalidResponse = Data(#"{"status":"failed","error":"refused","reason_code":"obsidian_note_invalid"}"#.utf8)
        let okResponse = Data(#"{"status":"ok"}"#.utf8)
        ObsidianIngestURLProtocol.queueIngestResponse(statusCode: 400, data: invalidResponse)
        ObsidianIngestURLProtocol.queueIngestResponse(statusCode: 200, data: okResponse)

        let (item1, _) = try await rig.enqueueObsidianItem(
            vaultID: "vault-invalid",
            window: ObsidianWindow(day: "20261108", segment: "094000_300")
        )
        let (item2, _) = try await rig.enqueueObsidianItem(
            vaultID: "vault-invalid",
            window: ObsidianWindow(day: "20261108", segment: "094500_300")
        )

        await rig.engine.kick()
        try await rig.waitFor("item 1 attention and item 2 delivered") {
            let snaps = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
            let s1 = snaps.first(where: { $0.itemID == item1.itemID })
            return s1?.state == .attention && rig.holder.deliveredCount >= 1
        }

        let snaps = await rig.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
        let s1 = try XCTUnwrap(snaps.first(where: { $0.itemID == item1.itemID }))
        XCTAssertEqual(s1.state, .attention)

        await rig.tearDown()
    }

    // MARK: - 5. Opaque IDs differ from folder names & Advisory Matching

    func testOpaqueIDsDifferFromFolderNamesAdvisoryMatchingAndVaultIsolation() async throws {
        let advisoryBox = DeliveryBox<[ObsidianSameNameAdvisory]?>([
            ObsidianSameNameAdvisory(vault: "Notes", device: "MacBook", lastSyncedAt: nil)
        ])
        let activeIDBox = DeliveryBox<String?>("vault-UUID-1")
        let acceptedBox = DeliveryBox<Set<String>>([])

        let gate = ObsidianCapabilityGate(
            readStatus: { _ in .read(version: "3.0.0", capabilities: ["obsidian_notes"]) },
            fetchVaults: { _ in advisoryBox.value },
            isCurrent: { _ in true },
            retryDelay: .milliseconds(20)
        )
        await gate.configure(
            isSourceEnabled: { true },
            isSourcePaused: { false },
            activeVaultID: { activeIDBox.value },
            isAcceptedForSameName: { id, _ in acceptedBox.value.contains(id) },
            recordAcceptance: { id, _ in acceptedBox.value.insert(id).inserted },
            wake: {},
            publishCapability: { _ in },
            publishAdvisory: { _ in }
        )

        let endpoint = ObsidianDeliveryRig.endpoint()

        // 1. Prime capability
        _ = await gate.admits(manifest: Self.makeManifest(vaultID: "vault-UUID-1", folderName: "Notes"), endpoint: endpoint)
        for _ in 0..<50 {
            if await gate.currentCapability == .listed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // 2. Advisory matches folderName "Notes" while vaultID is opaque UUID -> holds and retries
        let manifest1 = Self.makeManifest(vaultID: "vault-UUID-1", folderName: "Notes")
        let adm1 = await gate.admits(manifest: manifest1, endpoint: endpoint)
        XCTAssertFalse(adm1)
        for _ in 0..<50 {
            if await gate.currentAdvisory != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let adv = await gate.currentAdvisory
        XCTAssertEqual(adv?.vault, "Notes")

        // 3. Different folder name does not match advisory -> admitted
        let manifestDifferentFolder = Self.makeManifest(vaultID: "vault-UUID-1", folderName: "DifferentNotes")
        _ = await gate.admits(manifest: manifestDifferentFolder, endpoint: endpoint)
        for _ in 0..<50 {
            if await gate.admits(manifest: manifestDifferentFolder, endpoint: endpoint) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let admDiff = await gate.admits(manifest: manifestDifferentFolder, endpoint: endpoint)
        XCTAssertTrue(admDiff)

        // 4. Inactive vault A is not admitted and does not block selected vault B
        let idA = "vault-UUID-A"
        let idB = "vault-UUID-B"
        activeIDBox.value = idB

        let manifestA = Self.makeManifest(vaultID: idA, folderName: "FolderA")
        let manifestB = Self.makeManifest(vaultID: idB, folderName: "FolderB")

        let admA = await gate.admits(manifest: manifestA, endpoint: endpoint)
        XCTAssertFalse(admA)

        _ = await gate.admits(manifest: manifestB, endpoint: endpoint)
        for _ in 0..<50 {
            if await gate.admits(manifest: manifestB, endpoint: endpoint) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let admB = await gate.admits(manifest: manifestB, endpoint: endpoint)
        XCTAssertTrue(admB)

        // 5. Re-pick of A's id admits A again
        activeIDBox.value = idA
        _ = await gate.admits(manifest: manifestA, endpoint: endpoint)
        for _ in 0..<50 {
            if await gate.admits(manifest: manifestA, endpoint: endpoint) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let admARepick = await gate.admits(manifest: manifestA, endpoint: endpoint)
        XCTAssertTrue(admARepick)
    }

    // MARK: - 6. Slow Status Read cannot set .listed after endpoint change

    func testSlowStatusReadForEndpointACannotSetListedAfterEndpointChange() async throws {
        let sync = ObsidianStatusReadBarrier()

        let gate = ObsidianCapabilityGate(
            readStatus: { endpoint in await sync.read(endpoint.dispatchOwner?.credentialCID ?? "") },
            fetchVaults: { _ in [] },
            isCurrent: { _ in true }
        )

        await gate.configure(isSourceEnabled: { true }, isSourcePaused: { false },
            activeVaultID: { "vault-1" }, isAcceptedForSameName: { _, _ in true },
            wake: {}, publishCapability: { _ in }, publishAdvisory: { _ in })

        let endpointA = ObsidianDeliveryRig.endpoint(credential: "journal-a")
        let endpointB = ObsidianDeliveryRig.endpoint(credential: "journal-b")
        let manifest = Self.makeManifest(vaultID: "vault-1")

        // 1. Start read on endpoint A (slow)
        _ = await gate.admits(manifest: manifest, endpoint: endpointA)

        for _ in 0..<100 {
            if await sync.hasStarted("journal-a") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // 2. Switch to endpoint B while A's read is held
        _ = await gate.admits(manifest: manifest, endpoint: endpointB)

        // 3. Complete A's slow read with obsidian_notes capability
        await sync.finish("journal-a", report: .read(version: "3.0.0", capabilities: ["obsidian_notes"]))

        // Allow any background tasks on A to settle
        try? await Task.sleep(for: .milliseconds(60))

        // Gate must STILL be .unknown because endpoint changed to B and B's read is held
        let capWhileBHeld = await gate.currentCapability
        XCTAssertEqual(capWhileBHeld, .unknown)

        // 4. Now complete B's read
        await sync.finish("journal-b", report: .read(version: "3.0.0", capabilities: ["obsidian_notes"]))
        for _ in 0..<50 {
            if await gate.currentCapability == .listed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let capAfterB = await gate.currentCapability
        XCTAssertEqual(capAfterB, .listed)
    }

    // MARK: - 7. Unpaired vault makes no request to /app/devices/ingest/obsidian/vaults

    func testTurnOnAndCheckNowOnUnpairedVaultMakesNoVaultsRequest() async throws {
        ObsidianIngestURLProtocol.reset()
        let storeURL = self.testDir.appendingPathComponent("store_unpaired", isDirectory: true)
        let intakeURL = self.testDir.appendingPathComponent("intake_unpaired", isDirectory: true)
        let vaultURL = self.testDir.appendingPathComponent("vault_unpaired", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: intakeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultURL.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)

        let store = ObsidianStore(rootURL: storeURL)
        let intake = SourceIntakeStore(directoryURL: intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/vault_unpaired",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()
        await engine.checkNow()

        XCTAssertEqual(ObsidianIngestURLProtocol.vaultsRequestsCount, 0)
    }

    // MARK: - 8. EnqueueIfAbsent Idempotency & Distinct Vault IDs

    func testEnqueueIfAbsentIdempotencyAndDistinctVaultIDDerivation() async throws {
        let rig = try await ObsidianDeliveryRig(activeVaultID: "vault-idempotent")
        await rig.engine.pause()

        let vaultID = "vault-idempotent"
        let jsonlBytes = Data("{\"path\":\"n.md\",\"text\":\"hello\"}\n".utf8)
        let itemID = ObsidianWire.itemID(vaultID: vaultID, jsonlBytes: jsonlBytes)
        let fileURL = self.testDir.appendingPathComponent("\(itemID.uuidString).jsonl")
        try jsonlBytes.write(to: fileURL)

        let item = ObsidianOutboxItem(
            itemID: itemID,
            filename: "obsidian_file.jsonl",
            window: ObsidianWindow(day: "20261108", segment: "094000_300"),
            createdAt: Date(),
            lineCount: 1,
            byteCount: jsonlBytes.count,
            sha256Hex: ObsidianWire.sha256Hex(jsonlBytes),
            timeZoneIdentifier: "America/Denver",
            offsetSeconds: -25200,
            vaultID: vaultID,
            folderName: "Notes"
        )
        let manifest = ObsidianTransfer.manifest(for: item)

        // 1. Two enqueueIfAbsent calls of the same vault id and same JSONL bytes: second is .alreadyPresent
        let outcome1 = try await rig.engine.enqueueIfAbsent(manifest: manifest, payloadFileURLs: [ObsidianTransfer.partID: fileURL])
        try jsonlBytes.write(to: fileURL)
        let outcome2 = try await rig.engine.enqueueIfAbsent(manifest: manifest, payloadFileURLs: [ObsidianTransfer.partID: fileURL])
        XCTAssertEqual(outcome1, .enqueued)
        XCTAssertEqual(outcome2, .alreadyPresent)

        // 2. Two vaults, same folder name, same bytes: different item ids
        let vaultIDA = UUID().uuidString
        let vaultIDB = UUID().uuidString
        let idA = ObsidianWire.itemID(vaultID: vaultIDA, jsonlBytes: jsonlBytes)
        let idB = ObsidianWire.itemID(vaultID: vaultIDB, jsonlBytes: jsonlBytes)
        XCTAssertNotEqual(idA, idB)

        await rig.tearDown()
    }

    // MARK: - 9. Off / Pause / Resume on Capability Gate

    func testOffPauseResume() async throws {
        let gate = ObsidianCapabilityGate(
            readStatus: { _ in .read(version: "3.0.0", capabilities: ["obsidian_notes"]) },
            fetchVaults: { _ in [] },
            isCurrent: { _ in true }
        )

        let isEnabled = DeliveryBox<Bool>(true)
        let isPaused = DeliveryBox<Bool>(false)

        await gate.configure(
            isSourceEnabled: { isEnabled.value },
            isSourcePaused: { isPaused.value },
            activeVaultID: { "vault-1" },
            isAcceptedForSameName: { _, _ in true },
            wake: {},
            publishCapability: { _ in },
            publishAdvisory: { _ in }
        )

        let endpoint = ObsidianDeliveryRig.endpoint()
        let manifest = Self.makeManifest(vaultID: "vault-1")

        // Resolve capability
        _ = await gate.admits(manifest: manifest, endpoint: endpoint)
        for _ in 0..<50 {
            if await gate.currentCapability == .listed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // Active: admitted
        let adm1 = await gate.admits(manifest: manifest, endpoint: endpoint)
        XCTAssertTrue(adm1)

        // Off: refused
        isEnabled.value = false
        let adm2 = await gate.admits(manifest: manifest, endpoint: endpoint)
        XCTAssertFalse(adm2)

        // Resume enabled, but Paused: refused
        isEnabled.value = true
        isPaused.value = true
        let adm3 = await gate.admits(manifest: manifest, endpoint: endpoint)
        XCTAssertFalse(adm3)

        // Resumed: admitted
        isPaused.value = false
        let adm4 = await gate.admits(manifest: manifest, endpoint: endpoint)
        XCTAssertTrue(adm4)
    }
}
