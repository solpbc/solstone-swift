// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import XCTest
@testable import solstone_swift

private enum MigrationPutBehavior: Sendable, Equatable {
    case unavailable
    case refused
    case success
    case wrongSameDeviceTarget
}

private actor MigrationJournalStub: DeviceMigrationJournalAccess {
    private var state: DeviceMigrationJournalResult<DeviceMigrationServerSnapshot>
    private var clientsResults: [DeviceMigrationJournalResult<ReplacementClientList>]
    private var putBehaviors: [MigrationPutBehavior]
    private var requestBodies: [Data] = []
    private var stateFetchContinuation: CheckedContinuation<DeviceMigrationJournalResult<DeviceMigrationServerSnapshot>, Never>?
    private var stateFetchStarted = false
    private var stateFetchCount = 0
    private var pauseNextStateFetch = false
    private var putContinuation: CheckedContinuation<DeviceMigrationJournalResult<DeviceMigrationDecisionResponse>, Never>?
    private var putStarted = false
    private var pauseNextPut = false
    private var clientFetchContinuation: CheckedContinuation<DeviceMigrationJournalResult<ReplacementClientList>, Never>?
    private var clientFetchStarted = false
    private var pauseNextClientFetch = false

    init(
        state: DeviceMigrationJournalResult<DeviceMigrationServerSnapshot>,
        clientsResults: [DeviceMigrationJournalResult<ReplacementClientList>] = [],
        putBehaviors: [MigrationPutBehavior] = []
    ) {
        self.state = state
        self.clientsResults = clientsResults
        self.putBehaviors = putBehaviors
    }

    func fetchState(localPort: Int) async -> DeviceMigrationJournalResult<DeviceMigrationServerSnapshot> {
        self.stateFetchCount += 1
        if self.pauseNextStateFetch {
            self.pauseNextStateFetch = false
            self.stateFetchStarted = true
            return await withCheckedContinuation { self.stateFetchContinuation = $0 }
        }
        return self.state
    }

    func putDecision(localPort: Int, exactBody: Data) async -> DeviceMigrationJournalResult<DeviceMigrationDecisionResponse> {
        self.requestBodies.append(exactBody)
        let behavior = self.putBehaviors.isEmpty ? .unavailable : self.putBehaviors.removeFirst()
        if self.pauseNextPut {
            self.pauseNextPut = false
            self.putStarted = true
            return await withCheckedContinuation { self.putContinuation = $0 }
        }
        switch behavior {
        case .unavailable:
            return .unavailable
        case .refused:
            return .refused
        case .success, .wrongSameDeviceTarget:
            break
        }

        guard let json = try? JSONSerialization.jsonObject(with: exactBody) as? [String: Any],
              let operationText = json["operation_id"] as? String,
              let operationID = UUID(uuidString: operationText),
              let choiceText = json["choice"] as? String,
              let choice = DeviceMigrationChoice(rawValue: choiceText) else { return .invalidResponse }

        let state: DeviceMigrationServerState
        let previousCID: String?
        let replacedCID: String?
        switch choice {
        case .newDevice:
            state = .newDevice
            previousCID = MigrationOwnerFixture.oldCID
            replacedCID = nil
        case .sameDevice:
            state = .sameDevice
            previousCID = MigrationOwnerFixture.oldCID
            replacedCID = behavior == .wrongSameDeviceTarget ? MigrationOwnerFixture.targetCID : MigrationOwnerFixture.oldCID
        case .replaceDevice:
            state = .replacedDevice
            previousCID = nil
            replacedCID = json["replaces_cid"] as? String
        }
        return .success(DeviceMigrationDecisionResponse(
            protocolVersion: 1,
            operationID: operationID,
            state: state,
            previousCID: previousCID,
            cid: MigrationOwnerFixture.newCID,
            replacedCID: replacedCID,
            displayLabel: "device"
        ))
    }

    func fetchClients(localPort: Int) async -> DeviceMigrationJournalResult<ReplacementClientList> {
        if self.pauseNextClientFetch {
            self.pauseNextClientFetch = false
            self.clientFetchStarted = true
            return await withCheckedContinuation { self.clientFetchContinuation = $0 }
        }
        return self.clientsResults.isEmpty ? .success(ReplacementClientList(clients: [])) : self.clientsResults.removeFirst()
    }

    func recordedBodies() -> [Data] { self.requestBodies }

    func recordedStateFetchCount() -> Int { self.stateFetchCount }

    func pauseNextClientsResponse() { self.pauseNextClientFetch = true }

    func pauseNextStateResponse() { self.pauseNextStateFetch = true }

    func waitForStateRequest() async {
        while !self.stateFetchStarted { await Task.yield() }
    }

    func resumeStateRequest(_ result: DeviceMigrationJournalResult<DeviceMigrationServerSnapshot>) {
        self.stateFetchStarted = false
        self.stateFetchContinuation?.resume(returning: result)
        self.stateFetchContinuation = nil
    }

    func pauseNextPutResponse() { self.pauseNextPut = true }

    func waitForPutRequest() async {
        while !self.putStarted { await Task.yield() }
    }

    func resumePutRequest(_ result: DeviceMigrationJournalResult<DeviceMigrationDecisionResponse>) {
        self.putStarted = false
        self.putContinuation?.resume(returning: result)
        self.putContinuation = nil
    }

    func waitForClientsRequest() async {
        while !self.clientFetchStarted { await Task.yield() }
    }

    func resumeClientsRequest(_ result: DeviceMigrationJournalResult<ReplacementClientList>) {
        self.clientFetchStarted = false
        self.clientFetchContinuation?.resume(returning: result)
        self.clientFetchContinuation = nil
    }
}

private enum MigrationOwnerFixture {
    static let oldCID = "sha256:" + String(repeating: "a", count: 64)
    static let newCID = "sha256:" + String(repeating: "b", count: 64)
    static let targetCID = "sha256:" + String(repeating: "c", count: 64)
    static let thirdCID = "sha256:" + String(repeating: "d", count: 64)
    static let operationID = UUID()

    static let oldPairing = Self.pairing(cid: Self.oldCID, key: "old key")
    static let newPairing = Self.pairing(cid: Self.newCID, key: "new key")
    static let thirdPairing = Self.pairing(cid: Self.thirdCID, key: "third key")

    static func pairing(cid: String, key: String) -> StoredPairing {
        StoredPairing(
            instanceID: "owner-test-instance",
            homeLabel: "test journal",
            relayEndpoint: "https://relay.example.invalid",
            fingerprint: cid,
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: key,
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func client(_ cid: String, _ label: String) -> ReplacementClient {
        ReplacementClient(cid: cid, displayLabel: label)
    }

    static func pendingState() -> DeviceMigrationServerSnapshot {
        DeviceMigrationServerSnapshot(
            protocolVersion: 1,
            rekeyOperationID: Self.operationID,
            previousCID: Self.oldCID,
            state: .pending,
            replacedCID: nil
        )
    }

    static func emptyState() -> DeviceMigrationServerSnapshot {
        DeviceMigrationServerSnapshot(
            protocolVersion: 1,
            rekeyOperationID: nil,
            previousCID: nil,
            state: .none,
            replacedCID: nil
        )
    }
}

@MainActor
final class DeviceMigrationOwnerModelTests: XCTestCase {
    func testMigrationOwnerRequiresCurrentTunnelPortAndAttempt() async throws {
        let (_, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        owner.bindActiveConnection { port, epoch in port == 7111 && epoch == 9 }

        await owner.connected(localPort: 7111, connectionEpoch: 8)
        let staleFetchCount = await journal.recordedStateFetchCount()
        XCTAssertEqual(staleFetchCount, 0)
        XCTAssertNil(owner.serverState)

        await owner.connected(localPort: 7111, connectionEpoch: 9)
        let activeFetchCount = await journal.recordedStateFetchCount()
        XCTAssertEqual(activeFetchCount, 1)
        XCTAssertEqual(owner.serverState, .pending)
    }

    func testUnknownMigrationChoiceReplaysExactBytesAndSameDeviceNeedsExactPreviousCID() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()), putBehaviors: [.unavailable, .success])
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        XCTAssertTrue(owner.migrationChoicePending)
        XCTAssertTrue(owner.canChooseMigration)

        await owner.submitMigrationChoice(
            .sameDevice,
            presentedContext: try XCTUnwrap(owner.migrationChoicePresentation())
        )
        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        let unknown = try XCTUnwrap(migration.loadPortable(for: identity).transaction)
        XCTAssertEqual(unknown.decisionState, .unknown)
        XCTAssertTrue(confirmation.allowsSend(pairing: MigrationOwnerFixture.newPairing))
        XCTAssertTrue(owner.migrationChoicePending)

        await owner.connected(localPort: 7111)
        let bodies = await journal.recordedBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        let completed = try XCTUnwrap(migration.loadPortable(for: identity).transaction)
        XCTAssertEqual(completed.terminalState, .sameDevice)
        XCTAssertFalse(owner.migrationChoicePending)
    }

    func testSameDeviceWrongReplacedCIDDoesNotCompleteChoice() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()), putBehaviors: [.wrongSameDeviceTarget])
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.submitMigrationChoice(
            .sameDevice,
            presentedContext: try XCTUnwrap(owner.migrationChoicePresentation())
        )

        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        let transaction = try XCTUnwrap(migration.loadPortable(for: identity).transaction)
        XCTAssertEqual(transaction.decisionState, .unknown)
        XCTAssertNil(transaction.terminalState)
        XCTAssertTrue(owner.migrationChoicePending)
    }

    func testFreshReplacementListFiltersSelfKeepsDuplicateLabelsAndStartsUnselected() async throws {
        let (_, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let otherCID = "sha256:" + String(repeating: "e", count: 64)
        let clients = ReplacementClientList(clients: [
            MigrationOwnerFixture.client(MigrationOwnerFixture.newCID, "this phone"),
            MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "tablet"),
            MigrationOwnerFixture.client(otherCID, "tablet"),
            MigrationOwnerFixture.client("invalid", "ignored"),
        ])
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.emptyState()), clientsResults: [.success(clients)])
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        XCTAssertEqual(owner.freshPairOffer?.state, .available)
        await owner.loadReplacementClients()
        XCTAssertEqual(owner.replacementListState, .available)
        XCTAssertEqual(owner.replacementRows.count, 2)
        XCTAssertTrue(owner.replacementRows.allSatisfy { $0.label.contains("·") })
        XCTAssertNil(owner.selectedCID)
        let bodies = await journal.recordedBodies()
        XCTAssertTrue(bodies.isEmpty)
    }

    func testFreshReplacementUnknownResultReplaysExactPutForSavedTarget() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let clients = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "old phone")])
        let journal = MigrationJournalStub(
            state: .success(DeviceMigrationServerSnapshot(
                protocolVersion: 1,
                rekeyOperationID: nil,
                previousCID: nil,
                state: .replacedDevice,
                replacedCID: MigrationOwnerFixture.targetCID
            )),
            clientsResults: [.success(clients), .success(clients)],
            putBehaviors: [.unavailable, .success]
        )
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        let presentation = try XCTUnwrap(owner.freshReplacementPresentation(targetCID: MigrationOwnerFixture.targetCID))
        await owner.confirmFreshPairReplacement(presentedContext: presentation)
        XCTAssertEqual(owner.freshPairOffer?.state, .unknown)

        await owner.connected(localPort: 7111)
        let bodies = await journal.recordedBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(Set(request.keys), Set(["protocol_version", "operation_id", "choice", "replaces_cid"]))
        XCTAssertEqual(request["protocol_version"] as? Int, 1)
        XCTAssertEqual(request["choice"] as? String, "replace_device")
        XCTAssertEqual(request["replaces_cid"] as? String, MigrationOwnerFixture.targetCID)
        XCTAssertEqual(owner.freshPairOffer?.state, .complete)
        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        let saved = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertEqual(saved.targetCID, MigrationOwnerFixture.targetCID)
        XCTAssertEqual(saved.requestBytes, bodies[0])
    }

    func testFreshReplacementRejectsMalformedAuthoritativeStateBeforeExactReplay() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let clients = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "old phone")])
        let invalidState = DeviceMigrationServerSnapshot(
            protocolVersion: 2,
            rekeyOperationID: nil,
            previousCID: nil,
            state: .replacedDevice,
            replacedCID: MigrationOwnerFixture.targetCID
        )
        let journal = MigrationJournalStub(
            state: .success(invalidState),
            clientsResults: [.success(clients), .success(clients)],
            putBehaviors: [.unavailable]
        )
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        let presentation = try XCTUnwrap(owner.freshReplacementPresentation(targetCID: MigrationOwnerFixture.targetCID))
        await owner.confirmFreshPairReplacement(presentedContext: presentation)
        XCTAssertEqual(owner.freshPairOffer?.state, .unknown)

        await owner.connected(localPort: 7111)

        let bodies = await journal.recordedBodies()
        XCTAssertEqual(bodies.count, 1)
        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer?.state, .unknown)
    }

    func testRefreshedMissingTargetRemainsRemovedAndDoesNotSelectAnotherCID() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let target = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "old phone")])
        let replacement = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.thirdCID, "other phone")])
        let journal = MigrationJournalStub(
            state: .success(MigrationOwnerFixture.emptyState()),
            clientsResults: [.success(target), .success(replacement)],
            putBehaviors: [.success]
        )
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        let presentation = try XCTUnwrap(owner.freshReplacementPresentation(targetCID: MigrationOwnerFixture.targetCID))
        await owner.confirmFreshPairReplacement(presentedContext: presentation)
        XCTAssertEqual(owner.replacementListState, .targetRemoved)
        XCTAssertEqual(owner.freshPairOffer?.state, .targetRemoved)
        let bodies = await journal.recordedBodies()
        XCTAssertTrue(bodies.isEmpty)
        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer?.targetCID, nil)
    }

    func testOldListContinuationCannotMutateSameJournalReplacementOffer() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.emptyState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        XCTAssertFalse(owner.shouldPresentFreshPairOffer)
        await owner.connected(localPort: 7111)
        XCTAssertTrue(owner.shouldPresentFreshPairOffer)
        let offerID = try XCTUnwrap(owner.freshPairOffer?.operationID)
        XCTAssertTrue(owner.markFreshPairOfferPresented(operationID: offerID))
        XCTAssertFalse(owner.shouldPresentFreshPairOffer)
        await journal.pauseNextClientsResponse()
        let listTask = Task { await owner.loadReplacementClients() }
        await journal.waitForClientsRequest()

        try credentials.applyPairing(MigrationOwnerFixture.thirdPairing)
        let thirdIdentity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.thirdPairing)
        let replacementOwner = credentials.snapshot().deviceOwnerID
        XCTAssertNotNil(replacementOwner)
        let beforeRelease = try XCTUnwrap(migration.loadPortable(for: thirdIdentity).replacementOffer)
        XCTAssertEqual(beforeRelease.state, .awaitingMarkConfirmation)

        await journal.resumeClientsRequest(.success(ReplacementClientList(clients: [
            MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "stale result")
        ])))
        await listTask.value
        let afterRelease = try XCTUnwrap(migration.loadPortable(for: thirdIdentity).replacementOffer)
        XCTAssertEqual(afterRelease, beforeRelease)
        let bodies = await journal.recordedBodies()
        XCTAssertTrue(bodies.isEmpty)
    }

    func testOldMigrationGetCannotPublishAfterSameJournalReplacement() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await journal.pauseNextStateResponse()
        let connectionTask = Task { await owner.connected(localPort: 7111) }
        await journal.waitForStateRequest()

        try credentials.applyPairing(MigrationOwnerFixture.thirdPairing)
        let newIdentity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.thirdPairing)
        let newOffer = try XCTUnwrap(migration.loadPortable(for: newIdentity).replacementOffer)
        await journal.resumeStateRequest(.success(MigrationOwnerFixture.pendingState()))
        await connectionTask.value

        XCTAssertNil(owner.serverState)
        XCTAssertEqual(try migration.loadPortable(for: newIdentity).replacementOffer, newOffer)
        XCTAssertTrue(credentials.hasActiveOwner)
    }

    func testMigrationGetCannotPublishAfterPersistedRekeyOperationChanges() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await journal.pauseNextStateResponse()
        let connectionTask = Task { await owner.connected(localPort: 7111) }
        await journal.waitForStateRequest()

        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        var portable = try migration.loadPortable(for: identity)
        var transaction = try XCTUnwrap(portable.transaction)
        transaction.rekeyOperationID = UUID()
        portable.transaction = transaction
        try migration.savePortable(portable, for: identity)

        await journal.resumeStateRequest(.success(MigrationOwnerFixture.pendingState()))
        await connectionTask.value

        XCTAssertNil(owner.serverState)
        XCTAssertEqual(try migration.loadPortable(for: identity).transaction?.rekeyOperationID, transaction.rekeyOperationID)
    }

    func testListResponseCannotReopenDismissedReplacementOffer() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.emptyState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await journal.pauseNextClientsResponse()
        let listTask = Task { await owner.loadReplacementClients() }
        await journal.waitForClientsRequest()

        owner.dismissReplacementOffer()
        await journal.resumeClientsRequest(.success(ReplacementClientList(clients: [
            MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "stale result")
        ])))
        await listTask.value

        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer?.state, .available)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer?.presentationShown, true)
        XCTAssertEqual(owner.freshPairOffer?.state, .available)
        XCTAssertFalse(owner.shouldPresentFreshPairOffer)
        XCTAssertTrue(owner.replacementClients.isEmpty)
        XCTAssertEqual(owner.replacementListState, .unavailable)
    }

    func testMigrationDeferralMarksOnlyPresentationAndKeepsChoicePending() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        XCTAssertFalse(owner.shouldPresentMigrationChoice)
        await owner.connected(localPort: 7111)

        XCTAssertTrue(owner.shouldPresentMigrationChoice)
        owner.deferMigrationChoice()

        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        let transaction = try XCTUnwrap(migration.loadPortable(for: identity).transaction)
        XCTAssertTrue(transaction.presentationShown == true)
        XCTAssertNil(transaction.decisionID)
        XCTAssertNil(transaction.choice)
        XCTAssertNil(transaction.decisionBytes)
        XCTAssertTrue(owner.migrationChoicePending)
        XCTAssertTrue(owner.canChooseMigration)
        XCTAssertFalse(owner.shouldPresentMigrationChoice)
    }

    func testPresentedMigrationChoiceCannotApplyAfterSameJournalPairingReplacement() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()))
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        let presentation = try XCTUnwrap(owner.migrationChoicePresentation())

        try credentials.applyPairing(MigrationOwnerFixture.thirdPairing)
        await owner.submitMigrationChoice(.sameDevice, presentedContext: presentation)

        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.thirdPairing)
        let portable = try migration.loadPortable(for: identity)
        XCTAssertNil(portable.transaction)
        XCTAssertEqual(portable.replacementOffer?.state, .awaitingMarkConfirmation)
        XCTAssertNotEqual(portable.replacementOffer?.operationID, presentation.operationID)
    }

    func testOldMigrationPutCannotSettleAfterSameJournalReplacement() async throws {
        let (migration, confirmation, credentials) = try Self.makeCommittedOwnerState()
        let journal = MigrationJournalStub(state: .success(MigrationOwnerFixture.pendingState()), putBehaviors: [.success])
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await journal.pauseNextPutResponse()
        let presentation = try XCTUnwrap(owner.migrationChoicePresentation())
        let choiceTask = Task { await owner.submitMigrationChoice(.sameDevice, presentedContext: presentation) }
        await journal.waitForPutRequest()
        let oldIdentity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        let oldTransaction = try XCTUnwrap(migration.loadPortable(for: oldIdentity).transaction)
        let decisionID = try XCTUnwrap(oldTransaction.decisionID)

        try credentials.applyPairing(MigrationOwnerFixture.thirdPairing)
        let replacementIdentity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.thirdPairing)
        let offerBeforeResponse = try XCTUnwrap(migration.loadPortable(for: replacementIdentity).replacementOffer)
        await journal.resumePutRequest(.success(DeviceMigrationDecisionResponse(
            protocolVersion: 1,
            operationID: decisionID,
            state: .sameDevice,
            previousCID: MigrationOwnerFixture.oldCID,
            cid: MigrationOwnerFixture.newCID,
            replacedCID: MigrationOwnerFixture.oldCID,
            displayLabel: "device"
        )))
        await choiceTask.value

        XCTAssertEqual(try migration.loadPortable(for: replacementIdentity).replacementOffer, offerBeforeResponse)
        XCTAssertTrue(credentials.hasActiveOwner)
        XCTAssertEqual(credentials.snapshot().pairing, MigrationOwnerFixture.thirdPairing)
    }

    func testPresentedFreshReplacementCannotApplyToSameJournalReplacementOffer() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let clients = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "old phone")])
        let journal = MigrationJournalStub(
            state: .success(MigrationOwnerFixture.emptyState()),
            clientsResults: [.success(clients), .success(clients)],
            putBehaviors: [.success]
        )
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        let presented = try XCTUnwrap(owner.freshReplacementPresentation(targetCID: MigrationOwnerFixture.targetCID))

        try credentials.applyPairing(MigrationOwnerFixture.thirdPairing)
        try confirmation.writeRecord(for: MigrationOwnerFixture.thirdPairing)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.thirdPairing)
        let before = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertNotEqual(before.operationID, presented.operationID)
        await owner.confirmFreshPairReplacement(presentedContext: presented)

        let bodies = await journal.recordedBodies()
        XCTAssertTrue(bodies.isEmpty)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer, before)
        XCTAssertEqual(credentials.snapshot().pairing, MigrationOwnerFixture.thirdPairing)
    }

    func testOldFreshReplacementPutCannotCompleteNewPairOffer() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let clients = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "old phone")])
        let journal = MigrationJournalStub(
            state: .success(MigrationOwnerFixture.emptyState()),
            clientsResults: [.success(clients), .success(clients)],
            putBehaviors: [.success]
        )
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        await journal.pauseNextPutResponse()
        let presentation = try XCTUnwrap(owner.freshReplacementPresentation(targetCID: MigrationOwnerFixture.targetCID))
        let submitTask = Task { await owner.confirmFreshPairReplacement(presentedContext: presentation) }
        await journal.waitForPutRequest()
        let oldIdentity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        let oldOfferID = try XCTUnwrap(migration.loadPortable(for: oldIdentity).replacementOffer?.operationID)

        try credentials.applyPairing(MigrationOwnerFixture.thirdPairing)
        let replacementIdentity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.thirdPairing)
        let offerBeforeResponse = try XCTUnwrap(migration.loadPortable(for: replacementIdentity).replacementOffer)
        await journal.resumePutRequest(.success(DeviceMigrationDecisionResponse(
            protocolVersion: 1,
            operationID: oldOfferID,
            state: .replacedDevice,
            previousCID: nil,
            cid: MigrationOwnerFixture.newCID,
            replacedCID: MigrationOwnerFixture.targetCID,
            displayLabel: "device"
        )))
        await submitTask.value

        XCTAssertEqual(try migration.loadPortable(for: replacementIdentity).replacementOffer, offerBeforeResponse)
        XCTAssertEqual(offerBeforeResponse.state, .awaitingMarkConfirmation)
        XCTAssertEqual(credentials.snapshot().pairing, MigrationOwnerFixture.thirdPairing)
    }

    func testFreshReplacementResponseIsIgnoredAfterMarkConfirmationIsRevoked() async throws {
        let (migration, confirmation, credentials) = try Self.makeFreshPairOwnerState()
        let clients = ReplacementClientList(clients: [MigrationOwnerFixture.client(MigrationOwnerFixture.targetCID, "old phone")])
        let journal = MigrationJournalStub(
            state: .success(MigrationOwnerFixture.emptyState()),
            clientsResults: [.success(clients), .success(clients)],
            putBehaviors: [.success]
        )
        let owner = DeviceMigrationOwnerModel(credentials: credentials, confirmation: confirmation, client: journal)
        await owner.connected(localPort: 7111)
        await owner.loadReplacementClients()
        owner.selectedCID = MigrationOwnerFixture.targetCID
        await journal.pauseNextPutResponse()
        let presentation = try XCTUnwrap(owner.freshReplacementPresentation(targetCID: MigrationOwnerFixture.targetCID))
        let submitTask = Task { await owner.confirmFreshPairReplacement(presentedContext: presentation) }
        await journal.waitForPutRequest()

        try confirmation.clearRecord()
        await journal.resumePutRequest(.success(DeviceMigrationDecisionResponse(
            protocolVersion: 1,
            operationID: try XCTUnwrap(migration.loadPortable(
                for: DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
            ).replacementOffer?.operationID),
            state: .replacedDevice,
            previousCID: nil,
            cid: MigrationOwnerFixture.newCID,
            replacedCID: MigrationOwnerFixture.targetCID,
            displayLabel: "device"
        )))
        await submitTask.value

        let identity = try DevicePairingIdentity.make(for: MigrationOwnerFixture.newPairing)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer?.state, .submitting)
        XCTAssertNil(owner.freshPairOffer)
    }

    private static func makeCommittedOwnerState() throws -> (DeviceMigrationStore, JournalSendConfirmationStore, PairingCredentialStore) {
        let migration = DeviceMigrationStore.memory()
        let old = MigrationOwnerFixture.oldPairing
        let new = MigrationOwnerFixture.newPairing
        let marker = try migration.adopt(pairing: old, includeFreshPairOffer: false)
        let ownerID = try migration.claimExistingPairing(old)
        let migrationMarker = try migration.beginMigrationMarker(for: DevicePairingIdentity.make(for: old))
        try migration.savePendingRekey(PendingDeviceRekey(
            operationID: MigrationOwnerFixture.operationID,
            pairingOwnerID: ownerID,
            previousCID: old.fingerprint,
            csrPEM: "csr",
            privateKeyPEM: "private key",
            requestBytes: Data("exact rekey request".utf8),
            responseBytes: nil
        ), ownerID: ownerID)
        try migration.stageMigration(
            from: old,
            to: new,
            marker: migrationMarker,
            priorSendWasConfirmed: true,
            pairingOwnerID: ownerID
        )
        let confirmation = JournalSendConfirmationStore.memory()
        try confirmation.writeRecord(for: old)
        let holder = PairingSnapshotHolder(old)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.commitMigratedPairing(new) {
            try migration.finishMigration(pairing: new, marker: migrationMarker)
        }
        try confirmation.writeRecord(for: new)
        _ = marker
        return (migration, confirmation, credentials)
    }

    private static func makeFreshPairOwnerState() throws -> (DeviceMigrationStore, JournalSendConfirmationStore, PairingCredentialStore) {
        let migration = DeviceMigrationStore.memory()
        let pairing = MigrationOwnerFixture.newPairing
        _ = try migration.adopt(pairing: pairing, includeFreshPairOffer: true)
        _ = try migration.claimExistingPairing(pairing)
        let confirmation = JournalSendConfirmationStore.memory()
        try confirmation.writeRecord(for: pairing)
        let holder = PairingSnapshotHolder(pairing)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        return (migration, confirmation, credentials)
    }
}

private final class PairingSnapshotHolder: @unchecked Sendable {
    var pairing: StoredPairing?

    init(_ pairing: StoredPairing?) { self.pairing = pairing }
}
