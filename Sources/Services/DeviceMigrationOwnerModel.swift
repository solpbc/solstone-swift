// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import os

private let migrationOwnerLog = Logger(subsystem: "app.solstone.swift", category: "device-migration-owner")

nonisolated enum DeviceMigrationReplacementListState: Sendable, Equatable {
    case unavailable
    case empty
    case available
    case targetRemoved
}

nonisolated struct DeviceMigrationChoicePresentation: Equatable, Sendable {
    let ownerID: UUID
    let operationID: UUID
}

nonisolated struct DeviceMigrationReplacementPresentation: Equatable, Sendable {
    let ownerID: UUID
    let operationID: UUID
    let targetCID: String
}

@MainActor
@Observable
final class DeviceMigrationOwnerModel {
    private(set) var serverState: DeviceMigrationServerState?
    private(set) var replacementClients: [ReplacementClient] = []
    private(set) var replacementListState: DeviceMigrationReplacementListState = .unavailable
    private(set) var ownerSurfaceRevision: UInt64 = 0
    var selectedCID: String?

    @ObservationIgnored private let credentials: PairingCredentialStore
    @ObservationIgnored private let confirmation: JournalSendConfirmationStore
    @ObservationIgnored private let migrationStore: DeviceMigrationStore
    @ObservationIgnored private let client: any DeviceMigrationJournalAccess
    @ObservationIgnored private var activePort: Int?
    @ObservationIgnored private var activePairingGeneration: UInt64?
    @ObservationIgnored private var activePairingIdentity: DevicePairingIdentity?
    @ObservationIgnored private var activeCredentialCID: String?
    @ObservationIgnored private var activeOwnerID: UUID?
    @ObservationIgnored private var connectionToken: UUID?
    @ObservationIgnored private var replacementListGeneration: UInt64 = 0
    @ObservationIgnored private var activeConnectionEpoch: UInt64?
    @ObservationIgnored private var isActiveConnection: @MainActor @Sendable (Int, UInt64) -> Bool = { _, _ in true }
    @ObservationIgnored private var hasActiveConnectionBinding = false

    private struct Connection: Sendable {
        let token: UUID
        let port: Int
        let pairing: StoredPairing
        let identity: DevicePairingIdentity
        let ownerID: UUID
        let pairingGeneration: UInt64
        let connectionEpoch: UInt64?
    }

    init(
        credentials: PairingCredentialStore,
        confirmation: JournalSendConfirmationStore,
        client: any DeviceMigrationJournalAccess = DeviceMigrationJournalClient()
    ) {
        self.credentials = credentials
        self.confirmation = confirmation
        self.migrationStore = credentials.migrationStore
        self.client = client
    }

    func bindActiveConnection(_ isActive: @escaping @MainActor @Sendable (Int, UInt64) -> Bool) {
        self.isActiveConnection = isActive
        self.hasActiveConnectionBinding = true
    }

    var migrationChoicePending: Bool {
        guard let connection = self.currentStoredPairing(),
              self.hasCurrentOwner(connection.pairing),
              let transaction = try? self.migrationStore.loadPortable(for: connection.identity).transaction else { return false }
        return transaction.phase == .credentialCommitted && transaction.terminalState == nil
    }

    var canChooseMigration: Bool {
        guard self.serverState == .pending,
              let connection = self.currentStoredPairing(),
              self.hasCurrentOwner(connection.pairing),
              let transaction = try? self.migrationStore.loadPortable(for: connection.identity).transaction else { return false }
        return transaction.phase == .credentialCommitted && transaction.decisionID == nil
    }

    var shouldPresentMigrationChoice: Bool {
        guard self.serverState == .pending,
              let context = self.currentConnection(),
              let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction else { return false }
        return transaction.phase == .credentialCommitted
            && transaction.decisionID == nil
            && transaction.presentationShown != true
    }

    var shouldPresentFreshPairOffer: Bool {
        guard let context = self.currentConnection(),
              self.isCurrent(context),
              let offer = self.freshPairOffer else { return false }
        return offer.state == .available && offer.presentationShown != true
    }

    func migrationChoicePresentation() -> DeviceMigrationChoicePresentation? {
        guard let context = self.currentConnection(),
              self.serverState == .pending,
              let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction,
              transaction.phase == .credentialCommitted,
              transaction.decisionID == nil,
              let operationID = transaction.rekeyOperationID else { return nil }
        return DeviceMigrationChoicePresentation(ownerID: context.ownerID, operationID: operationID)
    }

    @discardableResult
    func markMigrationChoicePresented(_ presentation: DeviceMigrationChoicePresentation) -> Bool {
        guard let context = self.currentConnection(),
              context.ownerID == presentation.ownerID,
              self.serverState == .pending,
              let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction,
              transaction.phase == .credentialCommitted,
              transaction.decisionID == nil,
              transaction.rekeyOperationID == presentation.operationID,
              self.isCurrent(context) else { return false }
        do {
            try self.migrationStore.markMigrationChoicePresented(
                identity: context.identity,
                ownerID: context.ownerID,
                rekeyOperationID: presentation.operationID
            )
            self.ownerSurfaceRevision &+= 1
            return self.isCurrent(context) && self.persistedMigration(context, matching: transaction)
        } catch {
            migrationOwnerLog.error("migration choice presentation was not persisted")
            return false
        }
    }

    func deferMigrationChoice() {
        guard let presentation = self.migrationChoicePresentation() else { return }
        _ = self.markMigrationChoicePresented(presentation)
    }

    var migrationDecisionState: DeviceMigrationDecisionState? {
        guard let current = self.currentStoredPairing() else { return nil }
        return try? self.migrationStore.loadPortable(for: current.identity).transaction?.decisionState
    }

    var freshPairOffer: FreshPairReplacementOffer? {
        guard let current = self.currentStoredPairing(),
              self.hasCurrentOwner(current.pairing),
              self.confirmation.allowsSend(pairing: current.pairing),
              let offer = try? self.migrationStore.loadPortable(for: current.identity).replacementOffer,
              offer.pairingOwnerID == self.credentials.snapshot().deviceOwnerID,
              offer.pairingFingerprint == current.pairing.fingerprint else { return nil }
        return offer
    }

    var isFreshPairPendingVisible: Bool {
        guard let offer = self.freshPairOffer else { return false }
        switch offer.state {
        case .available, .submitting, .unknown, .targetRemoved, .refused:
            return true
        case .awaitingMarkConfirmation, .dismissed, .complete, .keptBoth, .retired:
            return false
        }
    }

    var replacementRows: [(client: ReplacementClient, label: String)] {
        let counts = Dictionary(grouping: self.replacementClients, by: \.displayLabel).mapValues(\.count)
        return self.replacementClients.map { client in
            let label = counts[client.displayLabel, default: 0] > 1
                ? "\(client.displayLabel) · \(client.cid)"
                : client.displayLabel
            return (client, label)
        }
    }

    func connected(localPort: Int, connectionEpoch: UInt64? = nil) async {
        guard let context = self.makeConnection(port: localPort, connectionEpoch: connectionEpoch) else {
            self.disconnected()
            return
        }
        self.activate(context)
        await self.reconcileMigration(context)
        guard self.isCurrent(context) else { return }
        await self.reconcileFreshPairOffer(context)
        guard self.isCurrent(context) else { return }
        if self.freshPairOffer?.state == .unknown || self.freshPairOffer?.state == .submitting {
            await self.reconcileFreshPairReplacement(context)
        }
        guard self.isCurrent(context) else { return }
        self.ownerSurfaceRevision &+= 1
    }

    func disconnected() {
        self.replacementListGeneration &+= 1
        self.ownerSurfaceRevision &+= 1
        self.activePort = nil
        self.activePairingGeneration = nil
        self.activePairingIdentity = nil
        self.activeCredentialCID = nil
        self.activeOwnerID = nil
        self.connectionToken = nil
        self.activeConnectionEpoch = nil
        self.serverState = nil
        self.replacementClients = []
        self.selectedCID = nil
        self.replacementListState = .unavailable
    }

    func refresh() async {
        if let port = self.activePort {
            await self.connected(localPort: port, connectionEpoch: self.activeConnectionEpoch)
        }
    }

    func dismissReplacementOffer() {
        guard let context = self.currentConnection(),
              self.confirmation.allowsSend(pairing: context.pairing),
              let offer = self.freshPairOffer,
              offer.state == .available || offer.state == .refused || offer.state == .targetRemoved else { return }
        self.replacementListGeneration &+= 1
        self.updateFreshOffer(context, operationID: offer.operationID) { $0.presentationShown = true }
    }

    func keepBothFromFreshPairOffer(presentedContext: DeviceMigrationChoicePresentation? = nil) {
        guard let context = self.currentConnection(),
              self.confirmation.allowsSend(pairing: context.pairing),
              let offer = self.freshPairOffer,
              offer.state == .available || offer.state == .refused || offer.state == .targetRemoved else { return }
        if let presentedContext {
            guard presentedContext.ownerID == context.ownerID,
                  presentedContext.operationID == offer.operationID else { return }
        }
        self.updateFreshOffer(context, operationID: offer.operationID) {
            $0.state = .keptBoth
            $0.presentationShown = true
        }
    }

    @discardableResult
    func markFreshPairOfferPresented(operationID: UUID) -> Bool {
        guard let context = self.currentConnection(),
              self.confirmation.allowsSend(pairing: context.pairing),
              let offer = self.freshPairOffer,
              offer.operationID == operationID,
              offer.state == .available,
              self.persistedOffer(context, offerID: operationID, allowedStates: [.available]) else { return false }
        do {
            try self.migrationStore.updateReplacementOffer(
                identity: context.identity,
                ownerID: context.ownerID,
                operationID: operationID
            ) { $0.presentationShown = true }
            self.ownerSurfaceRevision &+= 1
            guard self.isCurrent(context),
                  let persisted = try? self.migrationStore.loadPortable(for: context.identity).replacementOffer else {
                return false
            }
            return persisted.operationID == operationID
                && persisted.pairingOwnerID == context.ownerID
                && persisted.pairingFingerprint == context.pairing.fingerprint
                && persisted.state == .available
                && persisted.presentationShown == true
        } catch {
            migrationOwnerLog.error("fresh-pair offer presentation was not persisted")
            return false
        }
    }

    func prepareReplacementSelection() {
        self.replacementListGeneration &+= 1
        guard let context = self.currentConnection(),
              let offer = self.freshPairOffer,
              offer.state == .available || offer.state == .targetRemoved || offer.state == .refused else { return }
        self.selectedCID = nil
        self.replacementListState = .unavailable
        if offer.state == .targetRemoved || offer.state == .refused {
            self.updateFreshOffer(context, operationID: offer.operationID) {
                $0.operationID = UUID()
                $0.state = .available
                $0.targetCID = nil
                $0.requestBytes = nil
            }
        }
    }

    func loadReplacementClients() async {
        guard let context = self.currentConnection(),
              let offer = self.freshPairOffer else {
            self.replacementListState = .unavailable
            return
        }
        self.replacementListGeneration &+= 1
        let listGeneration = self.replacementListGeneration
        switch await self.client.fetchClients(localPort: context.port) {
        case .success(let list):
            guard listGeneration == self.replacementListGeneration,
                  self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(context, offerID: offer.operationID, allowedStates: [.available]) else { return }
            self.replacementClients = Self.filteredClients(list.clients, currentCID: context.pairing.fingerprint)
            self.replacementListState = self.replacementClients.isEmpty ? .empty : .available
            if let selectedCID = self.selectedCID,
               !self.replacementClients.contains(where: { $0.cid == selectedCID }) {
                self.selectedCID = nil
                self.replacementListState = .targetRemoved
                self.updateFreshOffer(context, operationID: offer.operationID) { $0.state = .targetRemoved }
            } else if self.freshPairOffer?.state == .targetRemoved,
                      let offer = self.freshPairOffer {
                self.updateFreshOffer(context, operationID: offer.operationID) {
                    $0.state = .available
                    $0.targetCID = nil
                    $0.requestBytes = nil
                }
            }
        case .unavailable, .invalidResponse, .refused:
            guard listGeneration == self.replacementListGeneration,
                  self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(context, offerID: offer.operationID, allowedStates: [.available]) else { return }
            self.replacementListState = .unavailable
            self.replacementClients = []
            self.selectedCID = nil
        }
    }

    func submitMigrationChoice(
        _ choice: DeviceMigrationChoice,
        presentedContext: DeviceMigrationChoicePresentation? = nil
    ) async {
        guard choice == .newDevice || choice == .sameDevice,
              let context = self.currentConnection(),
              self.migrationChoicePending,
              self.canChooseMigration else { return }
        let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction
        if choice == .sameDevice && presentedContext == nil { return }
        if let presentedContext {
            guard presentedContext.ownerID == context.ownerID,
                  transaction?.rekeyOperationID == presentedContext.operationID else { return }
        }
        do {
            let decisionID = UUID()
            var encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(DeviceMigrationDecisionRequest(
                operationID: decisionID,
                choice: choice,
                replacesCID: nil
            ))
            try self.migrationStore.saveDecision(
                identity: context.identity,
                ownerID: context.ownerID,
                decisionID: decisionID,
                choice: choice,
                targetCID: nil,
                requestBytes: bytes
            )
            self.ownerSurfaceRevision &+= 1
            guard self.isCurrent(context) else { return }
            await self.sendPersistedMigrationDecision(context)
        } catch {
            migrationOwnerLog.error("migration choice was not durably saved")
        }
    }

    func freshPairOfferPresentation() -> DeviceMigrationChoicePresentation? {
        guard let context = self.currentConnection(),
              let offer = self.freshPairOffer,
              offer.state == .available else { return nil }
        return DeviceMigrationChoicePresentation(ownerID: context.ownerID, operationID: offer.operationID)
    }

    func freshReplacementPresentation(targetCID: String) -> DeviceMigrationReplacementPresentation? {
        guard let presentation = self.freshPairOfferPresentation(),
              self.selectedCID == targetCID,
              self.replacementClients.contains(where: { $0.cid == targetCID }) else { return nil }
        return DeviceMigrationReplacementPresentation(
            ownerID: presentation.ownerID,
            operationID: presentation.operationID,
            targetCID: targetCID
        )
    }

    func confirmFreshPairReplacement(presentedContext: DeviceMigrationReplacementPresentation) async {
        let targetCID = presentedContext.targetCID
        guard let context = self.currentConnection(),
              context.ownerID == presentedContext.ownerID,
              self.confirmation.allowsSend(pairing: context.pairing),
              let offer = self.freshPairOffer,
              offer.operationID == presentedContext.operationID,
              offer.state == .available,
              self.selectedCID == targetCID,
              self.replacementClients.contains(where: { $0.cid == targetCID }) else { return }

        switch await self.client.fetchClients(localPort: context.port) {
        case .success(let list):
            guard self.isCurrent(context),
                  let latestOffer = self.freshPairOffer,
                  latestOffer.operationID == offer.operationID,
                  latestOffer.state == .available,
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.selectedCID == targetCID,
                  self.persistedOffer(context, offerID: offer.operationID, allowedStates: [.available]) else { return }
            self.replacementClients = Self.filteredClients(list.clients, currentCID: context.pairing.fingerprint)
            guard self.replacementClients.contains(where: { $0.cid == targetCID }) else {
                self.selectedCID = nil
                self.replacementListState = .targetRemoved
                self.updateFreshOffer(context, operationID: offer.operationID) { $0.state = .targetRemoved }
                return
            }
        case .unavailable, .invalidResponse, .refused:
            guard self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(context, offerID: offer.operationID, allowedStates: [.available]),
                  self.freshPairOffer?.state == .available else { return }
            self.replacementListState = .unavailable
            return
        }

        guard self.isCurrent(context),
              self.confirmation.allowsSend(pairing: context.pairing),
              let currentOffer = self.freshPairOffer,
              currentOffer.operationID == offer.operationID,
              currentOffer.state == .available else { return }
        do {
            var encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(DeviceMigrationDecisionRequest(
                operationID: offer.operationID,
                choice: .replaceDevice,
                replacesCID: targetCID
            ))
            try self.migrationStore.saveFreshPairDecision(
                identity: context.identity,
                ownerID: context.ownerID,
                offerID: offer.operationID,
                targetCID: targetCID,
                requestBytes: bytes
            )
            self.ownerSurfaceRevision &+= 1
            guard self.isCurrent(context) else { return }
            await self.sendFreshPairDecision(context, offerID: offer.operationID)
        } catch {
            migrationOwnerLog.error("replacement decision was not durably saved")
        }
    }

    private func reconcileMigration(_ context: Connection) async {
        guard self.migrationChoicePending, self.isCurrent(context),
              let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction,
              transaction.phase == .credentialCommitted,
              let rekeyOperationID = transaction.rekeyOperationID else { return }
        switch await self.client.fetchState(localPort: context.port) {
        case .success(let state):
            guard self.isCurrent(context),
                  self.persistedMigration(context, matching: transaction) else { return }
            guard state.protocolVersion == 1,
                  state.rekeyOperationID == rekeyOperationID,
                  state.previousCID == transaction.previousCID,
                  transaction.currentCID == context.pairing.fingerprint else { return }
            switch state.state {
            case .pending:
                guard state.replacedCID == nil else { return }
                self.serverState = .pending
                if transaction.decisionBytes != nil {
                    await self.sendPersistedMigrationDecision(context)
                } else if let decisionID = transaction.decisionID {
                    do {
                        try self.migrationStore.updateDecision(
                            identity: context.identity,
                            state: .waiting,
                            ownerID: context.ownerID,
                            decisionID: decisionID
                        )
                        self.ownerSurfaceRevision &+= 1
                    } catch {
                        migrationOwnerLog.error("migration decision state was not persisted")
                    }
                }
            case .newDevice, .sameDevice:
                guard let choice = transaction.choice,
                      Self.validTerminalSnapshot(state, choice: choice, transaction: transaction) else { return }
                if let decisionID = transaction.decisionID {
                    do {
                        try self.migrationStore.updateDecision(
                            identity: context.identity,
                            state: .complete,
                            terminalState: state.state,
                            ownerID: context.ownerID,
                            decisionID: decisionID
                        )
                        self.serverState = state.state
                        self.ownerSurfaceRevision &+= 1
                    } catch {
                        self.serverState = nil
                        migrationOwnerLog.error("migration terminal state was not persisted")
                    }
                } else {
                    return
                }
            case .none, .replacedDevice:
                return
            }
        case .unavailable, .invalidResponse, .refused:
            guard self.isCurrent(context),
                  self.persistedMigration(context, matching: transaction) else { return }
            self.serverState = nil
            if let decisionID = transaction.decisionID {
                do {
                    try self.migrationStore.updateDecision(
                        identity: context.identity,
                        state: .unknown,
                        ownerID: context.ownerID,
                        decisionID: decisionID
                    )
                    self.ownerSurfaceRevision &+= 1
                } catch {
                    migrationOwnerLog.error("unknown migration result was not persisted")
                }
            }
        }
    }

    private func sendPersistedMigrationDecision(_ context: Connection) async {
        guard self.isCurrent(context),
              let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction,
              let decisionID = transaction.decisionID,
              let choice = transaction.choice,
              let bytes = transaction.decisionBytes,
              self.persistedMigration(context, matching: transaction) else { return }
        switch await self.client.putDecision(localPort: context.port, exactBody: bytes) {
        case .success(let response):
            guard self.isCurrent(context),
                  self.persistedMigration(context, matching: transaction) else { return }
            guard Self.validDecisionResponse(
                response,
                decisionID: decisionID,
                choice: choice,
                transaction: transaction,
                currentCID: context.pairing.fingerprint
            ) else {
                do {
                try self.migrationStore.updateDecision(
                    identity: context.identity,
                    state: .unknown,
                    ownerID: context.ownerID,
                    decisionID: decisionID
                )
                self.ownerSurfaceRevision &+= 1
                } catch {
                    migrationOwnerLog.error("unknown migration result was not persisted")
                }
                self.serverState = nil
                return
            }
            do {
                try self.migrationStore.updateDecision(
                    identity: context.identity,
                    state: .complete,
                    terminalState: response.state,
                    ownerID: context.ownerID,
                    decisionID: decisionID
                )
                self.serverState = response.state
                self.ownerSurfaceRevision &+= 1
            } catch {
                self.serverState = nil
                migrationOwnerLog.error("migration terminal state was not persisted")
            }
        case .refused:
            guard self.isCurrent(context), self.persistedMigration(context, matching: transaction) else { return }
            do {
                try self.migrationStore.updateDecision(
                    identity: context.identity, state: .refused, ownerID: context.ownerID, decisionID: decisionID
                )
                self.ownerSurfaceRevision &+= 1
            } catch {
                migrationOwnerLog.error("refused migration result was not persisted")
            }
        case .unavailable, .invalidResponse:
            guard self.isCurrent(context), self.persistedMigration(context, matching: transaction) else { return }
            do {
                try self.migrationStore.updateDecision(
                    identity: context.identity, state: .unknown, ownerID: context.ownerID, decisionID: decisionID
                )
                self.ownerSurfaceRevision &+= 1
            } catch {
                migrationOwnerLog.error("unknown migration result was not persisted")
            }
        }
    }

    private func reconcileFreshPairOffer(_ context: Connection) async {
        guard self.isCurrent(context),
              self.confirmation.allowsSend(pairing: context.pairing),
              let offer = self.freshPairOffer,
              offer.pairingOwnerID == context.ownerID,
              offer.pairingFingerprint == context.pairing.fingerprint,
              offer.state == .awaitingMarkConfirmation,
              offer.targetCID == nil,
              offer.requestBytes == nil else { return }
        let operationID = offer.operationID
        let result = await self.client.fetchClients(localPort: context.port)
        guard self.isCurrent(context),
              self.confirmation.allowsSend(pairing: context.pairing),
              let currentOffer = self.freshPairOffer,
              currentOffer.operationID == operationID,
              currentOffer.pairingOwnerID == context.ownerID,
              currentOffer.pairingFingerprint == context.pairing.fingerprint,
              currentOffer.state == .awaitingMarkConfirmation,
              currentOffer.targetCID == nil,
              currentOffer.requestBytes == nil else { return }

        let nextState: FreshPairReplacementState
        switch result {
        case .success(let list):
            let otherClients = list.clients.filter { $0.cid != context.pairing.fingerprint }
            if otherClients.isEmpty {
                nextState = .retired
            } else if otherClients.allSatisfy({ DeviceMigrationJournalClient.validCID($0.cid) }) {
                nextState = .available
            } else {
                nextState = .available
            }
        case .unavailable, .invalidResponse, .refused:
            nextState = .available
        }

        self.updateFreshOffer(context, operationID: operationID) { offer in
            offer.state = nextState
        }
    }

    private func reconcileFreshPairReplacement(_ context: Connection) async {
        guard self.isCurrent(context),
              let offer = self.freshPairOffer,
              (offer.state == .unknown || offer.state == .submitting),
              offer.targetCID != nil,
              let bytes = offer.requestBytes else { return }
        switch await self.client.fetchState(localPort: context.port) {
        case .success(let state):
            guard self.isCurrent(context), self.persistedOffer(
                context,
                offerID: offer.operationID,
                targetCID: offer.targetCID,
                requestBytes: bytes,
                allowedStates: [.unknown, .submitting]
            ), self.confirmation.allowsSend(pairing: context.pairing) else { return }
            guard Self.validFreshPairReconciliationSnapshot(state) else {
                self.updateFreshOffer(context, operationID: offer.operationID) { $0.state = .unknown }
                return
            }
            // GET exposes no replacement decision UUID. Even a matching replaced_cid
            // cannot identify this offer, so replay its exact persisted PUT to bind the
            // terminal response to the saved operation ID and selected target.
            await self.sendFreshPairDecision(context, offerID: offer.operationID, body: bytes)
        case .unavailable, .invalidResponse, .refused:
            guard self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(
                    context,
                    offerID: offer.operationID,
                    targetCID: offer.targetCID,
                    requestBytes: bytes,
                    allowedStates: [.unknown, .submitting]
                  ) else { return }
            self.updateFreshOffer(context, operationID: offer.operationID) { $0.state = .unknown }
        }
    }

    private func sendFreshPairDecision(_ context: Connection, offerID: UUID, body explicitBody: Data? = nil) async {
        guard self.isCurrent(context), self.confirmation.allowsSend(pairing: context.pairing),
              let offer = self.freshPairOffer,
              offer.operationID == offerID,
              offer.state == .submitting || offer.state == .unknown,
              let targetCID = offer.targetCID,
              let body = explicitBody ?? offer.requestBytes else { return }
        guard let savedBody = offer.requestBytes, savedBody == body else { return }
        switch await self.client.putDecision(localPort: context.port, exactBody: body) {
        case .success(let response):
            guard self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(
                context,
                offerID: offerID,
                targetCID: targetCID,
                requestBytes: body,
                allowedStates: [.unknown, .submitting]
            ) else { return }
            guard Self.validFreshReplacementResponse(
                response, operationID: offerID, targetCID: targetCID, currentCID: context.pairing.fingerprint
            ) else {
                self.updateFreshOffer(context, operationID: offerID) { $0.state = .unknown }
                return
            }
            self.updateFreshOffer(context, operationID: offerID) { $0.state = .complete }
        case .refused:
            guard self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(
                context,
                offerID: offerID,
                targetCID: targetCID,
                requestBytes: body,
                allowedStates: [.unknown, .submitting]
            ) else { return }
            self.updateFreshOffer(context, operationID: offerID) { $0.state = .refused }
        case .unavailable, .invalidResponse:
            guard self.isCurrent(context),
                  self.confirmation.allowsSend(pairing: context.pairing),
                  self.persistedOffer(
                context,
                offerID: offerID,
                targetCID: targetCID,
                requestBytes: body,
                allowedStates: [.unknown, .submitting]
            ) else { return }
            self.updateFreshOffer(context, operationID: offerID) { $0.state = .unknown }
        }
    }

    private func updateFreshOffer(
        _ context: Connection,
        operationID: UUID?,
        _ update: (inout FreshPairReplacementOffer) -> Void
    ) {
        guard self.isCurrent(context), let operationID else { return }
        do {
            try self.migrationStore.updateReplacementOffer(
                identity: context.identity,
                ownerID: context.ownerID,
                operationID: operationID,
                update
            )
            self.ownerSurfaceRevision &+= 1
        } catch {
            migrationOwnerLog.error("fresh-pair offer state was not persisted")
        }
    }

    private func currentStoredPairing() -> (pairing: StoredPairing, identity: DevicePairingIdentity)? {
        guard let pairing = self.credentials.snapshot().pairing,
              let identity = try? DevicePairingIdentity.make(for: pairing) else { return nil }
        return (pairing, identity)
    }

    private func hasCurrentOwner(_ pairing: StoredPairing) -> Bool {
        guard let ownerID = self.credentials.snapshot().deviceOwnerID else { return false }
        return (try? self.migrationStore.owns(ownerID: ownerID, pairing: pairing)) == true
    }

    private func currentConnection() -> Connection? {
        guard let token = self.connectionToken,
              let port = self.activePort,
              let generation = self.activePairingGeneration,
              let ownerID = self.activeOwnerID,
              let pairing = self.credentials.snapshot().pairing,
              let identity = try? DevicePairingIdentity.make(for: pairing),
              self.activePairingIdentity == identity,
              self.activeCredentialCID == pairing.fingerprint,
              self.connectionIsActive(port: port, epoch: self.activeConnectionEpoch) else { return nil }
        return Connection(
            token: token,
            port: port,
            pairing: pairing,
            identity: identity,
            ownerID: ownerID,
            pairingGeneration: generation,
            connectionEpoch: self.activeConnectionEpoch
        )
    }

    private func makeConnection(port: Int, connectionEpoch: UInt64?) -> Connection? {
        let snapshot = self.credentials.snapshot()
        guard let pairing = snapshot.pairing,
              let identity = try? DevicePairingIdentity.make(for: pairing),
              let ownerID = snapshot.deviceOwnerID,
              self.connectionIsActive(port: port, epoch: connectionEpoch),
              (try? self.migrationStore.owns(ownerID: ownerID, pairing: pairing)) == true else { return nil }
        return Connection(
            token: UUID(),
            port: port,
            pairing: pairing,
            identity: identity,
            ownerID: ownerID,
            pairingGeneration: snapshot.pairingGeneration,
            connectionEpoch: connectionEpoch
        )
    }

    private func activate(_ context: Connection) {
        self.connectionToken = context.token
        self.activePort = context.port
        self.activePairingGeneration = context.pairingGeneration
        self.activePairingIdentity = context.identity
        self.activeCredentialCID = context.pairing.fingerprint
        self.activeOwnerID = context.ownerID
        self.activeConnectionEpoch = context.connectionEpoch
        self.serverState = nil
        self.replacementClients = []
        self.selectedCID = nil
        self.replacementListState = .unavailable
    }

    private func isCurrent(_ context: Connection) -> Bool {
        guard self.connectionToken == context.token,
              self.activePort == context.port,
              self.activePairingGeneration == context.pairingGeneration,
              self.activeOwnerID == context.ownerID,
              self.activePairingIdentity == context.identity,
              self.activeCredentialCID == context.pairing.fingerprint,
              self.activeConnectionEpoch == context.connectionEpoch,
              self.connectionIsActive(port: context.port, epoch: context.connectionEpoch) else { return false }
        let snapshot = self.credentials.snapshot()
        guard snapshot.pairingGeneration == context.pairingGeneration,
              snapshot.deviceOwnerID == context.ownerID,
              snapshot.pairing?.fingerprint == context.pairing.fingerprint,
              (try? self.migrationStore.owns(ownerID: context.ownerID, pairing: context.pairing)) == true else { return false }
        return true
    }

    private func connectionIsActive(port: Int, epoch: UInt64?) -> Bool {
        guard let epoch else { return !self.hasActiveConnectionBinding }
        return self.isActiveConnection(port, epoch)
    }

    private func persistedMigration(_ context: Connection, matching expected: DeviceMigrationTransaction) -> Bool {
        guard self.isCurrent(context),
              let transaction = try? self.migrationStore.loadPortable(for: context.identity).transaction,
              expected.rekeyOperationID != nil else { return false }
        return transaction.pairingOwnerID == context.ownerID
            && transaction.rekeyOperationID == expected.rekeyOperationID
            && transaction.previousCID == expected.previousCID
            && transaction.currentCID == context.pairing.fingerprint
            && transaction.currentCID == expected.currentCID
            && transaction.decisionID == expected.decisionID
            && transaction.choice == expected.choice
            && transaction.targetCID == expected.targetCID
            && transaction.decisionBytes == expected.decisionBytes
            && transaction.terminalState == expected.terminalState
    }

    private func persistedOffer(
        _ context: Connection,
        offerID: UUID,
        targetCID: String? = nil,
        requestBytes: Data? = nil,
        allowedStates: [FreshPairReplacementState]? = nil
    ) -> Bool {
        guard self.isCurrent(context),
              let offer = try? self.migrationStore.loadPortable(for: context.identity).replacementOffer else { return false }
        return offer.operationID == offerID
            && offer.pairingOwnerID == context.ownerID
            && offer.pairingFingerprint == context.pairing.fingerprint
            && (targetCID == nil || offer.targetCID == targetCID)
            && (requestBytes == nil || offer.requestBytes == requestBytes)
            && (allowedStates?.contains(offer.state) ?? true)
    }

    nonisolated private static func validTerminalSnapshot(
        _ state: DeviceMigrationServerSnapshot,
        choice: DeviceMigrationChoice,
        transaction: DeviceMigrationTransaction
    ) -> Bool {
        guard state.rekeyOperationID == transaction.rekeyOperationID,
              state.previousCID == transaction.previousCID else { return false }
        switch choice {
        case .newDevice:
            return state.state == .newDevice && state.replacedCID == nil
        case .sameDevice:
            return state.state == .sameDevice && state.replacedCID == transaction.previousCID
        case .replaceDevice:
            return false
        }
    }

    nonisolated private static func validDecisionResponse(
        _ response: DeviceMigrationDecisionResponse,
        decisionID: UUID,
        choice: DeviceMigrationChoice,
        transaction: DeviceMigrationTransaction,
        currentCID: String
    ) -> Bool {
        guard response.protocolVersion == 1,
              response.operationID == decisionID,
              response.cid == currentCID,
              response.previousCID == transaction.previousCID else { return false }
        switch choice {
        case .newDevice:
            return response.state == .newDevice && response.replacedCID == nil
        case .sameDevice:
            return response.state == .sameDevice && response.replacedCID == transaction.previousCID
        case .replaceDevice:
            return false
        }
    }

    nonisolated private static func validFreshReplacementResponse(
        _ response: DeviceMigrationDecisionResponse,
        operationID: UUID,
        targetCID: String,
        currentCID: String
    ) -> Bool {
        response.protocolVersion == 1
            && response.operationID == operationID
            && response.state == .replacedDevice
            && response.previousCID == nil
            && response.cid == currentCID
            && response.replacedCID == targetCID
            && targetCID != currentCID
    }

    nonisolated private static func validFreshPairReconciliationSnapshot(
        _ state: DeviceMigrationServerSnapshot
    ) -> Bool {
        guard state.protocolVersion == 1 else { return false }
        switch state.state {
        case .none:
            return state.rekeyOperationID == nil
                && state.previousCID == nil
                && state.replacedCID == nil
        case .pending:
            return state.rekeyOperationID != nil
                && state.previousCID.map { DeviceMigrationJournalClient.validCID($0) } == true
                && state.replacedCID == nil
        case .newDevice:
            return state.rekeyOperationID != nil
                && state.previousCID.map { DeviceMigrationJournalClient.validCID($0) } == true
                && state.replacedCID == nil
        case .sameDevice:
            guard let previousCID = state.previousCID else { return false }
            return state.rekeyOperationID != nil
                && DeviceMigrationJournalClient.validCID(previousCID)
                && state.replacedCID == previousCID
        case .replacedDevice:
            guard let replacedCID = state.replacedCID,
                  DeviceMigrationJournalClient.validCID(replacedCID) else { return false }
            if state.rekeyOperationID == nil {
                return state.previousCID == nil
            }
            return state.previousCID.map { DeviceMigrationJournalClient.validCID($0) } == true
        }
    }

    nonisolated private static func filteredClients(_ clients: [ReplacementClient], currentCID: String) -> [ReplacementClient] {
        var seen = Set<String>()
        return clients.filter { client in
            DeviceMigrationJournalClient.validCID(client.cid)
                && client.cid != currentCID
                && !client.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(client.cid).inserted
        }
    }
}
