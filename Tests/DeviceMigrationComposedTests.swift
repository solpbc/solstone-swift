// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import XCTest
import os
@testable import solstone_swift

@MainActor
private final class IssuedMigrationControl: MigrationControlExchanging {
    let response: Data
    var failBeforeResponse = false
    private(set) var bodies: [Data] = []

    init(response: Data) { self.response = response }

    func postRekey(pairing: StoredPairing, candidates: [TransportEndpoint], body: Data,
                   shouldContinue: @MainActor @Sendable () -> Bool,
                   afterResponse: @MainActor @Sendable (Data) async throws -> Void) async throws {
        self.bodies.append(body)
        guard !self.failBeforeResponse else { throw URLError(.notConnectedToInternet) }
        guard shouldContinue() else { throw CancellationError() }
        try await afterResponse(self.response)
    }
}

@MainActor
final class DeviceMigrationComposedTests: XCTestCase {
    private struct Fixture: @unchecked Sendable {
        let old: StoredPairing
        let operation: UUID
        let key: String
        let csr: String
        let response: [String: Any]
        var bytes: Data { get throws { try JSONSerialization.data(withJSONObject: self.response, options: [.sortedKeys]) } }
    }

    private struct Context: Sendable {
        let fixture: Fixture
        let migration: DeviceMigrationStore
        let confirmation: JournalSendConfirmationStore
        let holder: OSAllocatedUnfairLock<StoredPairing?>
        let saveFails: OSAllocatedUnfairLock<Bool>
        let credentials: PairingCredentialStore
        let control: IssuedMigrationControl
        let coordinator: DeviceMigrationCoordinator
        let pending: PendingDeviceRekey
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent("issued-crypto-memory-fixture-261006.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let old = try XCTUnwrap(object["old_pairing_public"] as? [String: String])
        let responses = try XCTUnwrap(object["responses"] as? [String: [String: Any]])
        return Fixture(old: StoredPairing(
            instanceID: try XCTUnwrap(old["instance_id"]), homeLabel: try XCTUnwrap(old["home_label"]),
            relayEndpoint: try XCTUnwrap(old["relay_endpoint"]), fingerprint: try XCTUnwrap(old["fingerprint"]),
            clientCertPEM: try XCTUnwrap(old["client_cert"]), clientKeyPEM: "unused old control fixture key",
            caChainPEM: try XCTUnwrap(old["ca_chain_pem"]), relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "192.0.2.10", port: 7657, scope: "lan")],
            pairedAt: Date(timeIntervalSince1970: 0)),
            operation: try XCTUnwrap(UUID(uuidString: XCTUnwrap(object["operation_id"] as? String))),
            key: try XCTUnwrap(object["private_key_pem"] as? String), csr: try XCTUnwrap(object["csr_pem"] as? String),
            response: try XCTUnwrap(responses["without_optional_network_metadata"]))
    }

    private func context(record: String? = nil, confirmed: Bool = true, legacy: Bool = false,
                         response: Data? = nil) throws -> Context {
        let fixture = try self.fixture()
        let migration = DeviceMigrationStore.memory()
        _ = try migration.adopt(pairing: fixture.old, includeFreshPairOffer: false)
        let confirmation = JournalSendConfirmationStore.memory(
            initialRecord: confirmed ? journalSendConfirmationKey(for: fixture.old) : record,
            initialMarker: !legacy)
        if legacy { _ = try confirmation.settle(loadPairing: { fixture.old }) }
        let holder = OSAllocatedUnfairLock<StoredPairing?>(initialState: fixture.old)
        let saveFails = OSAllocatedUnfairLock(initialState: false)
        let credentials = PairingCredentialStore(confirmationStore: confirmation, migrationStore: migration,
            loadPairing: { holder.withLock { $0 } }, savePairing: { value in
                if saveFails.withLock({ $0 }) { throw MigrationPersistenceTestError.write }
                holder.withLock { $0 = value }
            }, deletePairing: { holder.withLock { $0 = nil } })
        let owner = try XCTUnwrap(credentials.snapshot().deviceOwnerID)
        var marker = DeviceMigrationMarker.fresh()
        marker.adoption = .adopted(try DevicePairingIdentity.make(for: fixture.old))
        try migration.saveMarker(marker)
        _ = try migration.beginMigrationMarker(for: DevicePairingIdentity.make(for: fixture.old))
        let bytes = try JSONEncoder().encode(MigrationRekeyRequest(operationID: fixture.operation,
            csr: fixture.csr, deviceLabel: "memory fixture", clientLabel: "memory fixture"))
        let pending = PendingDeviceRekey(operationID: fixture.operation, pairingOwnerID: owner,
            previousCID: fixture.old.fingerprint, csrPEM: fixture.csr, privateKeyPEM: fixture.key,
            requestBytes: bytes, responseBytes: nil)
        try migration.savePendingRekey(pending, ownerID: owner)
        let control = IssuedMigrationControl(response: try (response ?? fixture.bytes))
        return Context(fixture: fixture, migration: migration, confirmation: confirmation,
            holder: holder, saveFails: saveFails, credentials: credentials, control: control,
            coordinator: DeviceMigrationCoordinator(credentials: credentials, confirmation: confirmation, control: control),
            pending: pending)
    }

    private func migrate(_ context: Context) async throws {
        try await context.coordinator.prepareForOrdinaryAdmission(pairing: context.fixture.old,
            pairingGeneration: context.credentials.snapshot().pairingGeneration, mayContinue: { true })
    }

    func testHTTPAuthorizationAndAmbiguousDecisionErrorsStayUnknown() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedDeviceIngestURLProtocol.self]
        let client = DeviceMigrationJournalClient(session: URLSession(configuration: configuration))
        defer { LinkedDeviceIngestURLProtocol.reset() }
        for (status, reason) in [(401, "unauthorized"), (403, "migration_forbidden"),
                                (403, "migration_replay_forbidden"), (404, "paired_device_not_found"),
                                (409, "migration_already_decided"), (409, "migration_operation_conflict"),
                                (409, "migration_target_conflict"), (400, "migration_request_invalid")] {
            let body = try JSONSerialization.data(withJSONObject: ["error": reason, "reason_code": reason, "detail": reason])
            LinkedDeviceIngestURLProtocol.handler = { request in
                (transferTestResponse(for: request, statusCode: status), body)
            }
            guard case .unavailable = await client.putDecision(localPort: 7111, exactBody: Data("saved request".utf8)) else {
                return XCTFail("HTTP \(status) \(reason) does not prove definite refusal")
            }
        }
        for reason in ["migration_proof_missing", "migration_self_replacement"] {
            let body = try JSONSerialization.data(withJSONObject: ["error": reason, "reason_code": reason, "detail": reason])
            LinkedDeviceIngestURLProtocol.handler = { request in (transferTestResponse(for: request, statusCode: 409), body) }
            guard case .refused = await client.putDecision(localPort: 7111, exactBody: Data("saved request".utf8)) else {
                return XCTFail("pinned authorized business refusal was not classified")
            }
            guard case .unavailable = await client.fetchState(localPort: 7111) else {
                return XCTFail("a GET cannot establish an unapplied decision")
            }
        }
        LinkedDeviceIngestURLProtocol.handler = { request in
            (transferTestResponse(for: request, statusCode: 409), Data(#"{"reason_code":"migration_proof_missing"}"#.utf8))
        }
        guard case .unavailable = await client.putDecision(localPort: 7111, exactBody: Data()) else {
            return XCTFail("an incomplete error envelope must remain unknown")
        }
    }

    func testConfirmationRebindAndCredentialSaveFailuresRecoverWithoutAnotherOperation() async throws {
        for failConfirmation in [true, false] {
            let context = try self.context()
            if failConfirmation { context.confirmation.failNextRecordWrite() }
            else { context.saveFails.withLock { $0 = true } }
            do { try await self.migrate(context); XCTFail("injected commit failure did not fail") }
            catch { XCTAssertTrue(error is JournalSendConfirmationStoreError || error is MigrationPersistenceTestError) }
            XCTAssertEqual(context.credentials.snapshot().pairing?.fingerprint, context.fixture.old.fingerprint)
            XCTAssertEqual(context.credentials.snapshot().pairingGeneration, 0)
            let identity = try DevicePairingIdentity.make(for: context.fixture.old)
            let transaction = try XCTUnwrap(context.migration.loadPortable(for: identity).transaction)
            XCTAssertTrue(transaction.priorSendWasConfirmed)
            XCTAssertTrue(transaction.sameInstanceAndCA)
            let retained = try XCTUnwrap(context.migration.loadPendingRekey(ownerID: context.pending.pairingOwnerID))
            XCTAssertEqual(retained.requestBytes, context.pending.requestBytes)
            XCTAssertEqual(retained.privateKeyPEM, context.pending.privateKeyPEM)
            XCTAssertNotNil(retained.responseBytes)
            context.saveFails.withLock { $0 = false }
            let cold = PairingCredentialStore(confirmationStore: context.confirmation, migrationStore: context.migration,
                loadPairing: { context.holder.withLock { $0 } }, savePairing: { value in context.holder.withLock { $0 = value } })
            let recovered = DeviceMigrationCoordinator(credentials: cold, confirmation: context.confirmation, control: context.control)
            try await recovered.prepareForOrdinaryAdmission(pairing: context.fixture.old,
                pairingGeneration: cold.snapshot().pairingGeneration, mayContinue: { true })
            let new = try XCTUnwrap(cold.snapshot().pairing)
            XCTAssertNotEqual(new.fingerprint, context.fixture.old.fingerprint)
            XCTAssertTrue(context.confirmation.allowsSend(pairing: new))
            XCTAssertFalse(context.confirmation.allowsSend(pairing: context.fixture.old))
            XCTAssertEqual(context.control.bodies, [context.pending.requestBytes])
            XCTAssertNil(try context.migration.loadPendingRekey(ownerID: context.pending.pairingOwnerID))
        }
    }

    func testUnconfirmedRejectedMalformedAndMismatchedConfirmationRemainHeldButLegacyAdopts() async throws {
        for record in [nil, "rejected", "malformed", "some-other-journal-and-certificate"] as [String?] {
            let context = try self.context(record: record, confirmed: false)
            try await self.migrate(context)
            let new = try XCTUnwrap(context.credentials.snapshot().pairing)
            XCTAssertFalse(context.confirmation.allowsSend(pairing: new))
            XCTAssertFalse(try XCTUnwrap(context.migration.loadPortable(for: DevicePairingIdentity.make(for: new)).transaction).priorSendWasConfirmed)
        }
        let legacy = try self.context(confirmed: false, legacy: true)
        XCTAssertTrue(legacy.confirmation.allowsSend(pairing: legacy.fixture.old))
        try await self.migrate(legacy)
        XCTAssertTrue(legacy.confirmation.allowsSend(pairing: legacy.credentials.snapshot().pairing))
    }

    func testWrongOperationCIDCAInstanceProtocolAndMalformedResponseNeverCommit() async throws {
        let fixture = try self.fixture()
        for mutation in ["operation_id", "cid", "previous_cid", "protocol_version", "instance_id", "ca_chain", "malformed"] {
            var response = fixture.response
            switch mutation {
            case "operation_id": response[mutation] = UUID().uuidString
            case "cid", "previous_cid": response[mutation] = "sha256:" + String(repeating: "f", count: 64)
            case "protocol_version": response[mutation] = 99
            case "instance_id", "ca_chain":
                var pairing = try XCTUnwrap(response["pairing"] as? [String: Any])
                if mutation == "instance_id" { pairing[mutation] = "different-journal" }
                else { pairing[mutation] = [CertlessTrustConstants.caPEM] }
                response["pairing"] = pairing
            default: break
            }
            let bytes = mutation == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: response)
            let context = try self.context(response: bytes)
            do { try await self.migrate(context); XCTFail("invalid \(mutation) response committed") }
            catch {
                XCTAssertTrue(error is DeviceMigrationControlError, "\(mutation): \(error)")
                if mutation == "instance_id" || mutation == "ca_chain" {
                    XCTAssertEqual(error as? DeviceMigrationControlError, .identityChanged)
                }
            }
            XCTAssertEqual(context.credentials.snapshot().pairing, fixture.old)
            XCTAssertEqual(context.credentials.snapshot().pairingGeneration, 0)
            XCTAssertTrue(context.confirmation.allowsSend(pairing: fixture.old))
            XCTAssertNil(try context.migration.loadPortable(for: DevicePairingIdentity.make(for: fixture.old)).transaction)
        }
    }

    func testHeldAudioLocationScreencastShareAndWatchSurviveRekeyAndDrainOnlyAfterNewAdmission() async throws {
        for offline in [true, false] {
            let context = try self.context()
            context.control.failBeforeResponse = offline
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationBacklog-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root); TransferURLProtocol.reset() }
            let resolver = LoopbackTransferEndpointResolver(credentials: context.credentials, confirmation: context.confirmation)
            let admissions = OSAllocatedUnfairLock<[String]>(initialState: [])
            let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
            let transport = TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration(),
                admission: { await resolver.isCurrent($0) }, requestAdmission: { endpoint, start in
                    await resolver.startRequest(endpoint) {
                        admissions.withLock { $0.append(endpoint.dispatchOwner!.credentialCID) }
                        start()
                    }
                })
            TransferURLProtocol.handler = { request, body in
                if request.url?.path == "/imports/save" {
                    return (transferTestResponse(for: request, statusCode: 200),
                        Data(#"{"recommended_action":"do_not_start","path":"/imports/share","timestamp":"2026-07-09T00:00:00Z"}"#.utf8))
                }
                return (transferTestResponse(for: request, statusCode: 200),
                    transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type")))
            }
            let engine = TransferEngine(spool: TransferSpool(rootURL: root), transport: transport,
                endpointResolver: resolver, diagnosticsSink: { event in events.withLock { $0.append(event) } },
                bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder)
            try await engine.start()
            let now = Date(timeIntervalSince1970: 1_780_480_800)
            var mobile = MobileSegmentManifest(segmentID: UUID(), startedAt: now,
                openedWithSources: [.audio, .location, .screencast], activeSourceSetVersion: 1)
            mobile.day = "20260628"; mobile.segment = "090000_60"; mobile.endedAt = now.addingTimeInterval(60); mobile.durationS = 60
            let manifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(manifest: mobile, now: now,
                sources: [.audio, .location, .screencast], payloadParts: [ObserverAudioTransferEnqueuer.audioPart(),
                    ObserverAudioTransferEnqueuer.locationPart(), ObserverAudioTransferEnqueuer.screencastPart()])
            let watch = ObserverAudioTransferEnqueuer.makeWatchManifest(sidecar: makeTransferTestSidecar(
                sessionID: UUID(), chunkIndex: 1, startedAt: now), hasLocation: false)
            let share = TransferCutoverDispatchTests.shareManifest(itemID: UUID(), index: 0)
            _ = try await engine.enqueue(manifest: manifest, payloads: ["audio": Data("held audio".utf8),
                "location": Data("held location".utf8), "screencast": Data("held screen".utf8)])
            _ = try await engine.enqueue(manifest: watch, payloads: ["audio": Data("held watch".utf8)])
            _ = try await engine.enqueue(manifest: share, payloads: ["text": Data("share-0".utf8)])
            let before = await engine.snapshot()
            XCTAssertEqual(before.counters.queuedCount, 3)
            XCTAssertTrue(TransferURLProtocol.requests.isEmpty)
            let ordinary = MockCFTunnelTransport()
            let connectedCIDs = OSAllocatedUnfairLock<[String]>(initialState: [])
            ordinary.onConnectInvoked = {
                let pairing = context.credentials.snapshot().pairing
                XCTAssertNotEqual(pairing?.fingerprint, context.fixture.old.fingerprint)
                XCTAssertEqual(context.credentials.snapshot().pairingGeneration, 1)
                XCTAssertTrue(context.confirmation.allowsSend(pairing: pairing))
                connectedCIDs.withLock { $0.append(pairing!.fingerprint) }
            }
            let cache = EndpointCache(fileURL: root.appendingPathComponent("endpoints.json"))
            await cache.bootstrap(from: context.fixture.old)
            let manager = TunnelManager(transport: ordinary, endpointCache: cache, store: context.credentials,
                migrationCoordinator: context.coordinator)
            await manager.connect()
            if offline {
                XCTAssertNil(manager.activeConnection)
                XCTAssertEqual(ordinary.connectCallCount, 0)
                XCTAssertTrue(admissions.withLock { $0.isEmpty })
                let held = await engine.snapshot()
                XCTAssertEqual(held.counters.queuedCount, 3)
            } else {
                let connection = try XCTUnwrap(manager.activeConnection)
                let new = try XCTUnwrap(context.credentials.snapshot().pairing)
                XCTAssertEqual(connectedCIDs.withLock { $0 }, [new.fingerprint])
                XCTAssertTrue(TransferURLProtocol.requests.isEmpty)
                await resolver.update(activeLocalPort: connection.port, connectionEpoch: connection.epoch)
                await engine.endpointAvailabilityChanged()
                try await transferTestWaitFor("all held kinds drained", timeout: .seconds(8)) {
                    await engine.snapshot().counters.deliveredCount == 3
                }
                XCTAssertEqual(admissions.withLock { $0 }, [new.fingerprint, new.fingerprint, new.fingerprint])
                XCTAssertEqual(TransferURLProtocol.requests.count, 3)
                let observerBodies = TransferURLProtocol.requests.filter { $0.url?.path == "/app/devices/ingest" }
                XCTAssertEqual(observerBodies.count, 2)
                let uploaded = TransferURLProtocol.bodies.map { String(decoding: $0, as: UTF8.self) }.joined()
                for canary in ["held audio", "held location", "held screen", "held watch", "share-0"] {
                    XCTAssertTrue(uploaded.contains(canary), "held payload changed or vanished: \(canary)")
                }
                let snapshot = await engine.snapshot()
                XCTAssertEqual(snapshot.counters.queuedCount, 0)
                XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount, 1)
                XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.watch]?.deliveredCount, 1)
                XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.share]?.deliveredCount, 1)
            }
            XCTAssertTrue(events.withLock { $0.allSatisfy { $0.outcome != .dropped } })
            XCTAssertEqual(context.control.bodies, [context.pending.requestBytes])
            await manager.disconnect()
            await cache.wipe()
            await engine.pause()
        }
    }

    func testSameHardwareReinstallWithWipedDefaultsRetainsBaselineWithoutRekeyOrChoice() async throws {
        let fixture = try self.fixture()
        let migration = DeviceMigrationStore.memory()
        _ = try migration.adopt(pairing: fixture.old, includeFreshPairOffer: false)
        let before = try migration.loadPortable(for: DevicePairingIdentity.make(for: fixture.old))
        let confirmation = JournalSendConfirmationStore.memory(initialRecord: journalSendConfirmationKey(for: fixture.old), initialMarker: true)
        let credentials = PairingCredentialStore(confirmationStore: confirmation, migrationStore: migration,
            loadPairing: { fixture.old }, savePairing: { _ in XCTFail("same-hardware reinstall must not rekey") })
        let control = IssuedMigrationControl(response: try fixture.bytes)
        let coordinator = DeviceMigrationCoordinator(credentials: credentials, confirmation: confirmation, control: control)
        let name = "MigrationReinstall-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: true, isOnboardingCompleted: false))
        try await coordinator.prepareForOrdinaryAdmission(pairing: fixture.old, pairingGeneration: 0, mayContinue: { true })
        XCTAssertFalse(ReinstallNotice.isFirstLaunchAfterReinstall(defaults: defaults, isPaired: true, isOnboardingCompleted: false))
        XCTAssertTrue(control.bodies.isEmpty)
        XCTAssertEqual(try migration.loadPortable(for: DevicePairingIdentity.make(for: fixture.old)), before)
        XCTAssertTrue(confirmation.allowsSend(pairing: fixture.old))
    }
}
