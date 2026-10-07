// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security
import SPLTunnel
import os

private nonisolated let migrationStoreLog = Logger(subsystem: "app.solstone.swift", category: "device-migration")

private nonisolated final class DeviceMigrationMutationLock: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return try operation()
    }
}

private nonisolated let deviceMigrationMutationLock = DeviceMigrationMutationLock()

nonisolated enum DeviceMigrationStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corruptRecord
    case invalidPairing
    case ownershipUnavailable
}

nonisolated protocol DeviceMigrationPersistence: Sendable {
    func readDeviceRecord(account: String) throws -> Data?
    func writeDeviceRecord(_ data: Data, account: String) throws
    func deleteDeviceRecord(account: String) throws
    func readPortableRecord(account: String) throws -> Data?
    func writePortableRecord(_ data: Data, account: String) throws
    func deletePortableRecord(account: String) throws
}

nonisolated private final class MemoryDeviceMigrationPersistence: DeviceMigrationPersistence, @unchecked Sendable {
    private struct State {
        var device: [String: Data] = [:]
        var portable: [String: Data] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func readDeviceRecord(account: String) throws -> Data? { self.state.withLock { $0.device[account] } }
    func writeDeviceRecord(_ data: Data, account: String) throws { self.state.withLock { $0.device[account] = data } }
    func deleteDeviceRecord(account: String) throws { _ = self.state.withLock { $0.device.removeValue(forKey: account) } }
    func readPortableRecord(account: String) throws -> Data? { self.state.withLock { $0.portable[account] } }
    func writePortableRecord(_ data: Data, account: String) throws { self.state.withLock { $0.portable[account] = data } }
    func deletePortableRecord(account: String) throws { _ = self.state.withLock { $0.portable.removeValue(forKey: account) } }
}

nonisolated struct KeychainDeviceMigrationPersistence: DeviceMigrationPersistence {
    private static let service = "app.solstone.swift.device-migration"

    func readDeviceRecord(account: String) throws -> Data? {
        try Self.read(account: account, deviceOnly: true)
    }

    func writeDeviceRecord(_ data: Data, account: String) throws {
        try Self.write(data, account: account, deviceOnly: true)
    }

    func deleteDeviceRecord(account: String) throws {
        try Self.delete(account: account, deviceOnly: true)
    }

    func readPortableRecord(account: String) throws -> Data? {
        try Self.read(account: account, deviceOnly: false)
    }

    func writePortableRecord(_ data: Data, account: String) throws {
        try Self.write(data, account: account, deviceOnly: false)
    }

    func deletePortableRecord(account: String) throws {
        try Self.delete(account: account, deviceOnly: false)
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    private static func accessibility(deviceOnly: Bool) -> CFString {
        deviceOnly ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlock
    }

    private static func read(account: String, deviceOnly: Bool) throws -> Data? {
        var query = Self.query(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DeviceMigrationStoreError.keychain(status)
        }
        return data
    }

    private static func write(_ data: Data, account: String, deviceOnly: Bool) throws {
        let query = Self.query(account: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility(deviceOnly: deviceOnly),
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw DeviceMigrationStoreError.keychain(updateStatus)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.accessibility(deviceOnly: deviceOnly)
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DeviceMigrationStoreError.keychain(addStatus)
        }
    }

    private static func delete(account: String, deviceOnly: Bool) throws {
        let status = SecItemDelete(Self.query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceMigrationStoreError.keychain(status)
        }
    }
}

nonisolated enum DeviceMigrationChoice: String, Codable, Equatable, Sendable {
    case newDevice = "new_device"
    case sameDevice = "same_device"
    case replaceDevice = "replace_device"
}

nonisolated enum DeviceMigrationServerState: String, Codable, Equatable, Sendable {
    case none
    case pending
    case newDevice = "new_device"
    case sameDevice = "same_device"
    case replacedDevice = "replaced_device"
}

nonisolated enum DeviceMigrationDecisionState: String, Codable, Equatable, Sendable {
    case waiting
    case submitting
    case unknown
    case refused
    case complete
}

nonisolated enum FreshPairReplacementState: String, Codable, Equatable, Sendable {
    case awaitingMarkConfirmation
    case available
    case submitting
    case unknown
    case targetRemoved
    case refused
    case dismissed
    case complete
    case keptBoth
    case retired = "retired"
}

nonisolated struct DevicePairingIdentity: Codable, Equatable, Sendable {
    let instanceID: String
    let caFingerprint: String

    var account: String {
        let bytes = Data("\(self.instanceID)\u{0}\(self.caFingerprint)".utf8)
        return "pairing-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func make(for pairing: StoredPairing) throws -> DevicePairingIdentity {
        guard !pairing.instanceID.isEmpty,
              let certificates = try? CertChain.certificates(fromPEM: pairing.caChainPEM),
              !certificates.isEmpty else {
            throw DeviceMigrationStoreError.invalidPairing
        }
        let fingerprints = certificates.map { CertChain.sha256Fingerprint(of: $0) }.joined(separator: ",")
        return DevicePairingIdentity(instanceID: pairing.instanceID, caFingerprint: fingerprints)
    }
}

nonisolated struct DeviceMigrationBaseline: Codable, Equatable, Sendable {
    let identity: DevicePairingIdentity
    let cid: String
    let deviceMarkerFingerprint: String
}

nonisolated enum DeviceMigrationTransactionPhase: String, Codable, Equatable, Sendable {
    case rekeyPending
    case credentialPrepared
    case credentialCommitted
}

nonisolated struct DeviceMigrationTransaction: Codable, Equatable, Sendable {
    let previousCID: String
    let currentCID: String
    /// The expected baseline may precede the credential used for this rekey when
    /// a restored candidate is privately rekeyed again on its new hardware.
    var expectedBaselineCID: String? = nil
    /// Kept after the device-only candidate is erased so terminal GETs remain bound
    /// to the committed server operation. It is written only at credential commit.
    var rekeyOperationID: UUID?
    var pairingOwnerID: UUID?
    var phase: DeviceMigrationTransactionPhase
    var priorSendWasConfirmed: Bool
    var sameInstanceAndCA: Bool
    var decisionState: DeviceMigrationDecisionState
    var decisionBytes: Data?
    var decisionID: UUID?
    var choice: DeviceMigrationChoice?
    var targetCID: String?
    var terminalState: DeviceMigrationServerState?
    var presentationShown: Bool? = nil
}

nonisolated struct FreshPairReplacementOffer: Codable, Equatable, Sendable {
    var operationID: UUID
    var pairingOwnerID: UUID?
    let pairingFingerprint: String
    var state: FreshPairReplacementState
    var targetCID: String?
    var requestBytes: Data?
    var presentationShown: Bool? = nil
}

nonisolated struct DeviceMigrationPortableRecord: Codable, Equatable, Sendable {
    let version: Int
    var baseline: DeviceMigrationBaseline?
    var stagedBaseline: DeviceMigrationBaseline?
    var transaction: DeviceMigrationTransaction?
    var replacementOffer: FreshPairReplacementOffer?

    static let empty = DeviceMigrationPortableRecord(
        version: 1,
        baseline: nil,
        stagedBaseline: nil,
        transaction: nil,
        replacementOffer: nil
    )
}

nonisolated struct DeviceMigrationMarker: Codable, Equatable, Sendable {
    enum Adoption: Codable, Equatable, Sendable {
        case pending(DevicePairingIdentity)
        case migrating(DevicePairingIdentity)
        case adopted(DevicePairingIdentity)
    }

    let version: Int
    let value: UUID
    var adoption: Adoption?

    static func fresh() -> DeviceMigrationMarker {
        DeviceMigrationMarker(version: 1, value: UUID(), adoption: nil)
    }

    var fingerprint: String {
        SHA256.hash(data: Data(self.value.uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct PendingDeviceRekey: Codable, Equatable, Sendable {
    let operationID: UUID
    let pairingOwnerID: UUID
    let previousCID: String
    let csrPEM: String
    let privateKeyPEM: String
    let requestBytes: Data
    var responseBytes: Data?
}

nonisolated struct DeviceMigrationReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let pairingOwnerID: UUID
    let previousCID: String
    let currentCID: String
}

nonisolated struct DeviceMigrationServerSnapshot: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let rekeyOperationID: UUID?
    let previousCID: String?
    let state: DeviceMigrationServerState
    let replacedCID: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case rekeyOperationID = "rekey_operation_id"
        case previousCID = "previous_cid"
        case state
        case replacedCID = "replaced_cid"
    }
}

nonisolated struct DeviceMigrationDecisionRequest: Codable, Sendable {
    let protocolVersion: Int
    let operationID: UUID
    let choice: DeviceMigrationChoice
    let replacesCID: String?

    init(operationID: UUID, choice: DeviceMigrationChoice, replacesCID: String?) {
        self.protocolVersion = 1
        self.operationID = operationID
        self.choice = choice
        self.replacesCID = replacesCID
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case choice
        case replacesCID = "replaces_cid"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.protocolVersion, forKey: .protocolVersion)
        try container.encode(self.operationID, forKey: .operationID)
        try container.encode(self.choice, forKey: .choice)
        try container.encodeIfPresent(self.replacesCID, forKey: .replacesCID)
    }
}

nonisolated struct DeviceMigrationDecisionResponse: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let operationID: UUID
    let state: DeviceMigrationServerState
    let previousCID: String?
    let cid: String
    let replacedCID: String?
    let displayLabel: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case state
        case previousCID = "previous_cid"
        case cid
        case replacedCID = "replaced_cid"
        case displayLabel = "display_label"
    }
}

nonisolated struct ReplacementClientList: Decodable, Equatable, Sendable {
    let clients: [ReplacementClient]
}

nonisolated struct ReplacementClient: Decodable, Equatable, Sendable, Identifiable {
    let cid: String
    let displayLabel: String
    var id: String { self.cid }

    enum CodingKeys: String, CodingKey {
        case cid
        case displayLabel = "display_label"
    }
}

nonisolated enum DeviceMigrationClassification: Equatable, Sendable {
    case noPairing
    case firstAdoption
    case interruptedAdoption
    case sameDevice
    case movedDevice
    case journalChanged
    case migrationRecovery
}

nonisolated struct DeviceMigrationCredentialOwner: Codable, Equatable, Sendable {
    let id: UUID
    let identity: DevicePairingIdentity
    var credentialCID: String
}

nonisolated struct DeviceMigrationOwnershipRecord: Codable, Equatable, Sendable {
    var active: DeviceMigrationCredentialOwner?
    var invalidatedOwnerIDs: Set<UUID>
    var retiredOwners: [DeviceMigrationCredentialOwner]
    var invalidationID: UUID?
    var invalidatedOwner: DeviceMigrationCredentialOwner?
    var pendingReplacement: DeviceMigrationOwnershipTransition?

    static let empty = DeviceMigrationOwnershipRecord(
        active: nil,
        invalidatedOwnerIDs: [],
        retiredOwners: [],
        invalidationID: nil,
        invalidatedOwner: nil,
        pendingReplacement: nil
    )

    private enum CodingKeys: String, CodingKey {
        case active
        case invalidatedOwnerIDs
        case retiredOwners
        case invalidationID
        case invalidatedOwner
        case pendingReplacement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try container.decodeIfPresent(DeviceMigrationCredentialOwner.self, forKey: .active)
        self.invalidatedOwnerIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .invalidatedOwnerIDs) ?? []
        self.retiredOwners = try container.decodeIfPresent([DeviceMigrationCredentialOwner].self, forKey: .retiredOwners) ?? []
        self.invalidationID = try container.decodeIfPresent(UUID.self, forKey: .invalidationID)
        self.invalidatedOwner = try container.decodeIfPresent(DeviceMigrationCredentialOwner.self, forKey: .invalidatedOwner)
        self.pendingReplacement = try container.decodeIfPresent(DeviceMigrationOwnershipTransition.self, forKey: .pendingReplacement)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.active, forKey: .active)
        try container.encode(self.invalidatedOwnerIDs, forKey: .invalidatedOwnerIDs)
        try container.encode(self.retiredOwners, forKey: .retiredOwners)
        try container.encodeIfPresent(self.invalidationID, forKey: .invalidationID)
        try container.encodeIfPresent(self.invalidatedOwner, forKey: .invalidatedOwner)
        try container.encodeIfPresent(self.pendingReplacement, forKey: .pendingReplacement)
    }

    init(
        active: DeviceMigrationCredentialOwner?,
        invalidatedOwnerIDs: Set<UUID>,
        retiredOwners: [DeviceMigrationCredentialOwner],
        invalidationID: UUID?,
        invalidatedOwner: DeviceMigrationCredentialOwner?,
        pendingReplacement: DeviceMigrationOwnershipTransition?
    ) {
        self.active = active
        self.invalidatedOwnerIDs = invalidatedOwnerIDs
        self.retiredOwners = retiredOwners
        self.invalidationID = invalidationID
        self.invalidatedOwner = invalidatedOwner
        self.pendingReplacement = pendingReplacement
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.active == rhs.active
            && lhs.invalidatedOwnerIDs == rhs.invalidatedOwnerIDs
            && lhs.retiredOwners == rhs.retiredOwners
            && lhs.invalidationID == rhs.invalidationID
            && lhs.invalidatedOwner == rhs.invalidatedOwner
            && lhs.pendingReplacement == rhs.pendingReplacement
    }
}

nonisolated struct DeviceMigrationOwnershipTransition: Codable, Equatable, Sendable {
    let id: UUID
    let fromOwnerID: UUID?
    let invalidationID: UUID?
    let owner: DeviceMigrationCredentialOwner
    let includeFreshPairOffer: Bool
    let pairingFlowLeaseID: UUID?
}

nonisolated struct DeviceMigrationInvalidationLease: Equatable, Sendable {
    let id: UUID
    let owner: DeviceMigrationCredentialOwner
}

nonisolated struct DeviceMigrationPairingFlowLease: Codable, Equatable, Sendable {
    let id: UUID
    let ownerID: UUID?
    let credentialCID: String?
}

nonisolated struct DeviceMigrationPairingRecovery: Sendable {
    let ownerID: UUID
    let resetPairingState: Bool
}

nonisolated struct DeviceMigrationStore: Sendable {
    func withMigrationMutation<T>(_ operation: () throws -> T) rethrows -> T {
        try deviceMigrationMutationLock.withLock(operation)
    }
    static let deviceMarkerAccount = "device-marker-v1"
    static let pendingRekeyAccount = "pending-rekey-v1"
    static let receiptAccount = "migration-receipt-v1"
    static let ownershipAccount = "pairing-ownership-v1"
    static let pairingFlowLeaseAccount = "pairing-flow-lease-v1"

    private let persistence: any DeviceMigrationPersistence
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(persistence: any DeviceMigrationPersistence = KeychainDeviceMigrationPersistence()) {
        self.persistence = persistence
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    static func memory() -> DeviceMigrationStore {
        DeviceMigrationStore(persistence: MemoryDeviceMigrationPersistence())
    }

    func loadMarker() throws -> DeviceMigrationMarker? {
        try self.decode(DeviceMigrationMarker.self, from: self.persistence.readDeviceRecord(account: Self.deviceMarkerAccount))
    }

    func ownershipRecord() throws -> DeviceMigrationOwnershipRecord {
        try self.decode(
            DeviceMigrationOwnershipRecord.self,
            from: self.persistence.readDeviceRecord(account: Self.ownershipAccount)
        ) ?? .empty
    }

    func saveOwnershipRecord(_ record: DeviceMigrationOwnershipRecord) throws {
        try self.persistence.writeDeviceRecord(self.encoder.encode(record), account: Self.ownershipAccount)
    }

    func beginPairingFlowLease(ownerID: UUID?, credentialCID: String?) throws -> DeviceMigrationPairingFlowLease {
        try deviceMigrationMutationLock.withLock {
            let ownership = try self.ownershipRecord()
            guard ownership.invalidationID == nil, ownership.pendingReplacement == nil else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            if let ownerID {
                guard ownership.active?.id == ownerID,
                      ownership.active?.credentialCID == credentialCID else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
            } else {
                guard ownership.active == nil, credentialCID == nil else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
            }
            let lease = DeviceMigrationPairingFlowLease(
                id: UUID(),
                ownerID: ownerID,
                credentialCID: credentialCID
            )
            try self.persistence.writeDeviceRecord(
                self.encoder.encode(lease),
                account: Self.pairingFlowLeaseAccount
            )
            return lease
        }
    }

    func ownsPairingFlowLease(_ lease: DeviceMigrationPairingFlowLease) throws -> Bool {
        try deviceMigrationMutationLock.withLock {
            guard let storedLease = try self.decode(
                DeviceMigrationPairingFlowLease.self,
                from: self.persistence.readDeviceRecord(account: Self.pairingFlowLeaseAccount)
            ), storedLease.id == lease.id else { return false }
            let ownership = try self.ownershipRecord()
            guard ownership.invalidationID == nil, ownership.pendingReplacement == nil else { return false }
            if storedLease == lease, let ownerID = lease.ownerID {
                return ownership.active?.id == ownerID
                    && ownership.active?.credentialCID == lease.credentialCID
            }
            if storedLease == lease {
                return ownership.active == nil && lease.credentialCID == nil
            }
            return storedLease.ownerID == ownership.active?.id
                && storedLease.credentialCID == ownership.active?.credentialCID
                && ownership.active != nil
        }
    }

    func withPairingFlowLease<T>(
        _ lease: DeviceMigrationPairingFlowLease,
        shouldCommit: @Sendable () -> Bool,
        operation: () throws -> T
    ) throws -> T {
        try deviceMigrationMutationLock.withLock {
            guard shouldCommit(), try self.ownsPairingFlowLease(lease) else {
                throw CancellationError()
            }
            return try operation()
        }
    }

    /// A device with a restored migratable pairing has no copied device-only owner.
    /// It gets a fresh local owner; an unfinished local transition is recovered by
    /// comparing the actual keychain pairing with its durable next owner.
    func recoverPairingReplacement(_ pairing: StoredPairing) throws -> DeviceMigrationPairingRecovery? {
        try deviceMigrationMutationLock.withLock {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var record = try self.ownershipRecord()
        guard let transition = record.pendingReplacement else { return nil }
        let transitionIsCurrent = transition.invalidationID.map {
            record.active == nil && record.invalidationID == $0 && record.invalidatedOwner != nil
        } ?? (record.active?.id == transition.fromOwnerID && record.invalidationID == nil)
        guard transitionIsCurrent else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        guard transition.owner.identity == identity,
              transition.owner.credentialCID == pairing.fingerprint else {
            record.pendingReplacement = nil
            try self.saveOwnershipRecord(record)
            return nil
        }
        try self.finishFreshPairing(pairing: pairing, includeFreshPairOffer: transition.includeFreshPairOffer)
        return DeviceMigrationPairingRecovery(
            ownerID: transition.owner.id,
            resetPairingState: record.active?.credentialCID != pairing.fingerprint
        )
        }
    }

    func claimExistingPairing(_ pairing: StoredPairing) throws -> UUID {
        try deviceMigrationMutationLock.withLock {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var record = try self.ownershipRecord()
        guard record.pendingReplacement == nil else { throw DeviceMigrationStoreError.ownershipUnavailable }
        if let active = record.active {
            guard active.identity == identity, !record.invalidatedOwnerIDs.contains(active.id) else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            if active.credentialCID != pairing.fingerprint {
                let portable = try self.loadPortable(for: identity)
                guard let transaction = portable.transaction,
                      transaction.pairingOwnerID == active.id,
                      transaction.previousCID == active.credentialCID,
                      transaction.currentCID == pairing.fingerprint else {
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
                switch transaction.phase {
                case .credentialPrepared:
                    guard portable.baseline?.identity == identity,
                          (portable.baseline?.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
                            || portable.baseline?.cid == transaction.previousCID),
                          portable.stagedBaseline?.identity == identity,
                          portable.stagedBaseline?.cid == pairing.fingerprint else {
                        throw DeviceMigrationStoreError.ownershipUnavailable
                    }
                case .credentialCommitted:
                    let baselineIsPrevious = portable.baseline?.identity == identity
                        && portable.baseline?.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
                    let baselineIsCurrent = portable.baseline?.identity == identity
                        && portable.baseline?.cid == pairing.fingerprint
                    let stagedIsCurrent = portable.stagedBaseline?.identity == identity
                        && portable.stagedBaseline?.cid == pairing.fingerprint
                    guard (baselineIsPrevious && stagedIsCurrent)
                        || (baselineIsCurrent && (portable.stagedBaseline == nil || stagedIsCurrent)) else {
                        throw DeviceMigrationStoreError.ownershipUnavailable
                    }
                case .rekeyPending:
                    throw DeviceMigrationStoreError.ownershipUnavailable
                }
                // Keep the old CID as the durable owner until migration finalization
                // commits the new credential and its baseline together.
                return active.id
            }
            try self.bindPortableOwner(identity: identity, ownerID: active.id, credentialCID: pairing.fingerprint)
            do {
                try self.cleanupRetiredOwners()
            } catch {
                migrationStoreLog.error("retired pairing cleanup deferred")
            }
            return active.id
        }
        guard record.invalidationID == nil else { throw DeviceMigrationStoreError.ownershipUnavailable }

        let portable = try self.loadPortable(for: identity)
        if let transaction = portable.transaction,
           transaction.currentCID == pairing.fingerprint,
           let transactionOwnerID = transaction.pairingOwnerID,
           !record.invalidatedOwnerIDs.contains(transactionOwnerID),
           try self.hasLocalCandidateProof(transaction: transaction, portable: portable, marker: self.loadMarker()) {
            let ownerCID = portable.baseline?.cid == pairing.fingerprint
                ? pairing.fingerprint
                : transaction.previousCID
            let owner = DeviceMigrationCredentialOwner(
                id: transactionOwnerID,
                identity: identity,
                credentialCID: ownerCID
            )
            record.active = owner
            try self.saveOwnershipRecord(record)
            return owner.id
        }

        let owner = DeviceMigrationCredentialOwner(id: UUID(), identity: identity, credentialCID: pairing.fingerprint)
        try self.bindPortableOwner(identity: identity, ownerID: owner.id, credentialCID: pairing.fingerprint)
        record.active = owner
        try self.saveOwnershipRecord(record)
        do {
            try self.cleanupRetiredOwners()
        } catch {
            migrationStoreLog.error("retired pairing cleanup deferred")
        }
        return owner.id
        }
    }

    private func bindPortableOwner(identity: DevicePairingIdentity, ownerID: UUID, credentialCID: String) throws {
        var portable = try self.loadPortable(for: identity)
        var changed = false
        if var offer = portable.replacementOffer,
           offer.pairingFingerprint == credentialCID,
           offer.pairingOwnerID != ownerID {
            offer.pairingOwnerID = ownerID
            portable.replacementOffer = offer
            changed = true
        }
        if changed { try self.savePortable(portable, for: identity) }
    }

    private func hasLocalCandidateProof(
        transaction: DeviceMigrationTransaction,
        portable: DeviceMigrationPortableRecord,
        marker: DeviceMigrationMarker?
    ) throws -> Bool {
        guard transaction.phase != .rekeyPending,
              let ownerID = transaction.pairingOwnerID,
              let operationID = transaction.rekeyOperationID,
              let marker,
              let baseline = portable.baseline,
              baseline.deviceMarkerFingerprint == marker.fingerprint,
              (baseline.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
                || baseline.cid == transaction.currentCID) else { return false }
        let markerIdentityMatches: Bool
        switch marker.adoption {
        case .migrating(let identity), .adopted(let identity):
            markerIdentityMatches = identity == baseline.identity
        case .pending, .none:
            markerIdentityMatches = false
        }
        guard markerIdentityMatches else { return false }
        let pending = try self.loadPendingRekey(ownerID: ownerID)
        let receipt = try self.loadReceipt(ownerID: ownerID)
        return pending.map {
            $0.operationID == operationID
                && $0.pairingOwnerID == ownerID
                && $0.previousCID == transaction.previousCID
        } == true || receipt.map {
            $0.operationID == operationID
                && $0.pairingOwnerID == ownerID
                && $0.previousCID == transaction.previousCID
                && $0.currentCID == transaction.currentCID
        } == true
    }

    func beginPairingReplacement(
        from ownerID: UUID?,
        pairing: StoredPairing,
        includeFreshPairOffer: Bool,
        pairingFlowLeaseID: UUID? = nil
    ) throws -> UUID {
        try deviceMigrationMutationLock.withLock {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var record = try self.ownershipRecord()
        let owner = DeviceMigrationCredentialOwner(id: UUID(), identity: identity, credentialCID: pairing.fingerprint)
        let invalidationID: UUID?
        if let active = record.active {
            guard record.invalidationID == nil, active.id == ownerID else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            invalidationID = nil
        } else if let activeInvalidationID = record.invalidationID,
                  record.invalidatedOwner != nil,
                  ownerID == nil {
            invalidationID = activeInvalidationID
        } else {
            guard record.invalidationID == nil, ownerID == nil else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            invalidationID = nil
        }
        guard record.pendingReplacement == nil else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        if let pairingFlowLeaseID {
            guard let lease = try self.decode(
                DeviceMigrationPairingFlowLease.self,
                from: self.persistence.readDeviceRecord(account: Self.pairingFlowLeaseAccount)
            ), lease.id == pairingFlowLeaseID,
                 lease.ownerID == ownerID,
                 lease.credentialCID == record.active?.credentialCID else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
        } else {
            try self.persistence.deleteDeviceRecord(account: Self.pairingFlowLeaseAccount)
        }
        record.pendingReplacement = DeviceMigrationOwnershipTransition(
            id: UUID(), fromOwnerID: ownerID, invalidationID: invalidationID,
            owner: owner, includeFreshPairOffer: includeFreshPairOffer,
            pairingFlowLeaseID: pairingFlowLeaseID
        )
        try self.saveOwnershipRecord(record)
        return owner.id
        }
    }

    func commitPairingReplacement(ownerID: UUID) throws {
        try deviceMigrationMutationLock.withLock {
        var record = try self.ownershipRecord()
        guard let transition = record.pendingReplacement, transition.owner.id == ownerID else {
            if record.active?.id == ownerID { return }
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        let transitionIsCurrent = transition.invalidationID.map {
            record.active == nil && record.invalidationID == $0 && record.invalidatedOwner != nil
        } ?? (record.active?.id == transition.fromOwnerID && record.invalidationID == nil)
        guard transitionIsCurrent else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        try self.bindPortableOwner(
            identity: transition.owner.identity,
            ownerID: transition.owner.id,
            credentialCID: transition.owner.credentialCID
        )
        if let prior = record.active {
            record.invalidatedOwnerIDs.insert(prior.id)
            if !record.retiredOwners.contains(where: { $0.id == prior.id }) {
                record.retiredOwners.append(prior)
            }
        } else if let invalidated = record.invalidatedOwner,
                  transition.invalidationID == record.invalidationID {
            record.invalidatedOwnerIDs.insert(invalidated.id)
            if !record.retiredOwners.contains(where: { $0.id == invalidated.id }) {
                record.retiredOwners.append(invalidated)
            }
        }
        record.active = transition.owner
        record.pendingReplacement = nil
        record.invalidationID = nil
        record.invalidatedOwner = nil
        if let pairingFlowLeaseID = transition.pairingFlowLeaseID {
            let committedLease = DeviceMigrationPairingFlowLease(
                id: pairingFlowLeaseID,
                ownerID: transition.owner.id,
                credentialCID: transition.owner.credentialCID
            )
            try self.persistence.writeDeviceRecord(
                self.encoder.encode(committedLease),
                account: Self.pairingFlowLeaseAccount
            )
        }
        try self.saveOwnershipRecord(record)
        do {
            try self.cleanupRetiredOwners()
        } catch {
            migrationStoreLog.error("retired pairing cleanup deferred")
        }
        }
    }

    func rollbackPairingReplacement(ownerID: UUID) throws {
        try deviceMigrationMutationLock.withLock {
        var record = try self.ownershipRecord()
        guard let transition = record.pendingReplacement,
              transition.owner.id == ownerID else { return }
        let transitionIsCurrent = transition.invalidationID.map {
            record.active == nil && record.invalidationID == $0 && record.invalidatedOwner != nil
        } ?? (record.active?.id == transition.fromOwnerID && record.invalidationID == nil)
        guard transitionIsCurrent else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        record.pendingReplacement = nil
        try self.saveOwnershipRecord(record)
        }
    }

    func updateCredential(ownerID: UUID, pairing: StoredPairing) throws {
        try deviceMigrationMutationLock.withLock {
        var record = try self.ownershipRecord()
        guard var owner = record.active, owner.id == ownerID,
              owner.identity == (try DevicePairingIdentity.make(for: pairing)) else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        let canAdvance: Bool
        if owner.credentialCID == pairing.fingerprint {
            canAdvance = true
        } else if let transaction = try self.loadPortable(for: owner.identity).transaction {
            canAdvance = transaction.pairingOwnerID == ownerID
                && transaction.previousCID == owner.credentialCID
                && transaction.currentCID == pairing.fingerprint
                && transaction.phase == .credentialCommitted
        } else {
            canAdvance = false
        }
        guard canAdvance else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        guard owner.credentialCID != pairing.fingerprint else { return }
        owner.credentialCID = pairing.fingerprint
        record.active = owner
        try self.saveOwnershipRecord(record)
        }
    }

    func owns(ownerID: UUID) throws -> Bool {
        let record = try self.ownershipRecord()
        return record.active?.id == ownerID
            && record.pendingReplacement?.fromOwnerID != ownerID
            && record.invalidationID == nil
            && !record.invalidatedOwnerIDs.contains(ownerID)
    }

    func owns(ownerID: UUID, pairing: StoredPairing) throws -> Bool {
        let identity = try DevicePairingIdentity.make(for: pairing)
        guard try self.owns(ownerID: ownerID),
              let owner = try self.ownershipRecord().active else { return false }
        return owner.id == ownerID
            && owner.identity == identity
            && owner.credentialCID == pairing.fingerprint
    }

    func withCurrentCredentialAdmission<T: Sendable>(
        ownerID: UUID,
        pairing: StoredPairing,
        operation: @Sendable () -> T?
    ) -> T? {
        deviceMigrationMutationLock.withLock {
            guard (try? self.owns(ownerID: ownerID, pairing: pairing)) == true else { return nil }
            return operation()
        }
    }

    func beginInvalidation(ownerID: UUID) throws -> DeviceMigrationInvalidationLease {
        try deviceMigrationMutationLock.withLock {
        var record = try self.ownershipRecord()
        guard record.pendingReplacement == nil,
              record.invalidationID == nil,
              let owner = record.active,
              owner.id == ownerID,
              !record.invalidatedOwnerIDs.contains(ownerID) else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        let lease = DeviceMigrationInvalidationLease(id: UUID(), owner: owner)
        record.active = nil
        record.invalidatedOwnerIDs.insert(owner.id)
        record.invalidationID = lease.id
        record.invalidatedOwner = owner
        try self.saveOwnershipRecord(record)
        return lease
        }
    }

    func resumeInvalidation() throws -> DeviceMigrationInvalidationLease? {
        let record = try self.ownershipRecord()
        guard let id = record.invalidationID, let owner = record.invalidatedOwner else { return nil }
        return DeviceMigrationInvalidationLease(id: id, owner: owner)
    }

    func ownsInvalidation(_ lease: DeviceMigrationInvalidationLease) throws -> Bool {
        let record = try self.ownershipRecord()
        return record.active == nil && record.pendingReplacement == nil && record.invalidationID == lease.id
            && record.invalidatedOwner == lease.owner
            && record.invalidatedOwnerIDs.contains(lease.owner.id)
    }

    func finishInvalidation(_ lease: DeviceMigrationInvalidationLease) throws {
        try deviceMigrationMutationLock.withLock {
        var record = try self.ownershipRecord()
        guard record.active == nil,
              record.pendingReplacement == nil,
              record.invalidationID == lease.id,
              record.invalidatedOwner == lease.owner,
              record.invalidatedOwnerIDs.contains(lease.owner.id) else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        try self.deletePendingRekey(ownerID: lease.owner.id)
        try self.deleteReceipt(ownerID: lease.owner.id)
        var portable = try self.loadPortable(for: lease.owner.identity)
        if portable.transaction?.pairingOwnerID == lease.owner.id {
            portable.transaction = nil
            portable.stagedBaseline = nil
            if portable.replacementOffer?.pairingOwnerID == lease.owner.id {
                portable.replacementOffer = nil
            }
            try self.savePortable(portable, for: lease.owner.identity)
        }
        record.invalidationID = nil
        record.invalidatedOwner = nil
        try self.saveOwnershipRecord(record)
        }
    }

    private func cleanupRetiredOwners() throws {
        var record = try self.ownershipRecord()
        for owner in record.retiredOwners {
            try self.deletePendingRekey(ownerID: owner.id)
            try self.deleteReceipt(ownerID: owner.id)
            var portable = try self.loadPortable(for: owner.identity)
            if portable.transaction?.pairingOwnerID == owner.id {
                portable.transaction = nil
                portable.stagedBaseline = nil
            }
            if portable.replacementOffer?.pairingOwnerID == owner.id {
                portable.replacementOffer = nil
            }
            try self.savePortable(portable, for: owner.identity)
            record.retiredOwners.removeAll { $0.id == owner.id }
            try self.saveOwnershipRecord(record)
            record = try self.ownershipRecord()
        }
    }

    private static func account(_ base: String, ownerID: UUID?) -> String {
        guard let ownerID else { return base }
        return "\(base)-\(ownerID.uuidString.lowercased())"
    }

    func saveMarker(_ marker: DeviceMigrationMarker) throws {
        try self.persistence.writeDeviceRecord(self.encoder.encode(marker), account: Self.deviceMarkerAccount)
    }

    func loadPendingRekey(ownerID: UUID) throws -> PendingDeviceRekey? {
        try self.decode(PendingDeviceRekey.self, from: self.persistence.readDeviceRecord(account: Self.account(Self.pendingRekeyAccount, ownerID: ownerID)))
    }

    func savePendingRekey(_ operation: PendingDeviceRekey, ownerID: UUID) throws {
        try deviceMigrationMutationLock.withLock {
            guard operation.pairingOwnerID == ownerID,
                  try self.owns(ownerID: ownerID) else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            try self.persistence.writeDeviceRecord(
                self.encoder.encode(operation),
                account: Self.account(Self.pendingRekeyAccount, ownerID: ownerID)
            )
        }
    }

    func deletePendingRekey(ownerID: UUID, operationID: UUID? = nil) throws {
        let account = Self.account(Self.pendingRekeyAccount, ownerID: ownerID)
        if let current = try self.decode(PendingDeviceRekey.self, from: self.persistence.readDeviceRecord(account: account)),
           let operationID, current.operationID != operationID {
            return
        }
        try self.persistence.deleteDeviceRecord(account: account)
    }

    func loadReceipt(ownerID: UUID) throws -> DeviceMigrationReceipt? {
        try self.decode(DeviceMigrationReceipt.self, from: self.persistence.readDeviceRecord(account: Self.account(Self.receiptAccount, ownerID: ownerID)))
    }

    func saveReceipt(_ receipt: DeviceMigrationReceipt, ownerID: UUID) throws {
        guard receipt.pairingOwnerID == ownerID else { throw DeviceMigrationStoreError.ownershipUnavailable }
        try self.persistence.writeDeviceRecord(self.encoder.encode(receipt), account: Self.account(Self.receiptAccount, ownerID: ownerID))
    }

    func deleteReceipt(ownerID: UUID, operationID: UUID? = nil) throws {
        let account = Self.account(Self.receiptAccount, ownerID: ownerID)
        if let current = try self.decode(DeviceMigrationReceipt.self, from: self.persistence.readDeviceRecord(account: account)),
           let operationID, current.operationID != operationID {
            return
        }
        try self.persistence.deleteDeviceRecord(account: account)
    }

    func loadPortable(for identity: DevicePairingIdentity) throws -> DeviceMigrationPortableRecord {
        guard let data = try self.persistence.readPortableRecord(account: identity.account) else {
            return .empty
        }
        guard let value = try? self.decoder.decode(DeviceMigrationPortableRecord.self, from: data), value.version == 1 else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        return value
    }

    func savePortable(_ record: DeviceMigrationPortableRecord, for identity: DevicePairingIdentity) throws {
        guard record.version == 1 else { throw DeviceMigrationStoreError.corruptRecord }
        try self.persistence.writePortableRecord(self.encoder.encode(record), account: identity.account)
    }

    func classify(pairing: StoredPairing?, ownerID suppliedOwnerID: UUID? = nil) throws -> DeviceMigrationClassification {
        guard let pairing else { return .noPairing }
        let identity = try DevicePairingIdentity.make(for: pairing)
        let marker = try self.loadMarker()
        let portable = try self.loadPortable(for: identity)
        let ownerID: UUID?
        if let suppliedOwnerID {
            ownerID = suppliedOwnerID
        } else {
            ownerID = try self.ownershipRecord().active?.id
        }

        if portable.stagedBaseline != nil,
           case .pending(let pendingIdentity)? = marker?.adoption,
           pendingIdentity == identity {
            return .interruptedAdoption
        }

        if let transaction = portable.transaction {
            if transaction.phase != .credentialCommitted {
                guard transaction.previousCID == pairing.fingerprint
                    || transaction.currentCID == pairing.fingerprint else {
                    throw DeviceMigrationStoreError.corruptRecord
                }
                if let baseline = portable.baseline {
                    guard baseline.identity == identity,
                          baseline.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
                            || baseline.cid == transaction.previousCID
                            || baseline.cid == transaction.currentCID else {
                        throw DeviceMigrationStoreError.corruptRecord
                    }
                }
                if let stagedBaseline = portable.stagedBaseline {
                    guard stagedBaseline.identity == identity,
                          stagedBaseline.cid == transaction.currentCID else {
                        throw DeviceMigrationStoreError.corruptRecord
                    }
                }
                if transaction.currentCID == pairing.fingerprint,
                   transaction.rekeyOperationID != nil,
                   transaction.pairingOwnerID == ownerID,
                   (portable.baseline?.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
                    || portable.baseline?.cid == transaction.previousCID),
                   portable.stagedBaseline?.cid == pairing.fingerprint {
                    return .migrationRecovery
                }
                guard transaction.pairingOwnerID == ownerID,
                      let marker,
                      Self.isMigrationMarker(marker, identity: identity),
                      Self.migrationBaselineMatchesMarker(portable, transaction: transaction, marker: marker) else {
                    return .movedDevice
                }
                return .migrationRecovery
            }
            if transaction.currentCID != pairing.fingerprint {
                guard transaction.previousCID == pairing.fingerprint else {
                    throw DeviceMigrationStoreError.corruptRecord
                }
                guard transaction.pairingOwnerID == ownerID,
                      let marker,
                      Self.isMigrationMarker(marker, identity: identity),
                      Self.migrationBaselineMatchesMarker(portable, transaction: transaction, marker: marker) else {
                    return .movedDevice
                }
                return .migrationRecovery
            }

            let hasMatchingMarkerAndBaseline = marker.map {
                Self.isMigrationMarker($0, identity: identity)
                    && Self.migrationBaselineMatchesMarker(portable, transaction: transaction, marker: $0)
            } ?? false
            guard transaction.phase == .credentialCommitted,
                  let transactionOwnerID = transaction.pairingOwnerID,
                  transactionOwnerID == ownerID else { return .movedDevice }
            if !hasMatchingMarkerAndBaseline {
                guard transaction.rekeyOperationID != nil,
                      (portable.baseline?.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
                        && portable.stagedBaseline?.cid == transaction.currentCID)
                        || (portable.baseline?.cid == transaction.currentCID && portable.stagedBaseline == nil) else {
                    return .movedDevice
                }
                return .migrationRecovery
            }
            let baselineIsPrevious = portable.baseline?.identity == identity
                && portable.baseline?.cid == (transaction.expectedBaselineCID ?? transaction.previousCID)
            let baselineIsCurrent = portable.baseline?.identity == identity
                && portable.baseline?.cid == transaction.currentCID
            let stagedIsCurrent = portable.stagedBaseline?.identity == identity
                && portable.stagedBaseline?.cid == transaction.currentCID
            guard (baselineIsPrevious && stagedIsCurrent)
                || (baselineIsCurrent && (portable.stagedBaseline == nil || stagedIsCurrent)) else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            guard transaction.rekeyOperationID != nil else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            let markerIsAdopted: Bool
            if case .adopted(let markerIdentity)? = marker?.adoption {
                markerIsAdopted = markerIdentity == identity
            } else {
                markerIsAdopted = false
            }
            if !baselineIsCurrent || portable.stagedBaseline != nil || !markerIsAdopted {
                return .migrationRecovery
            }
        } else if let baseline = portable.baseline {
            guard baseline.identity == identity,
                  baseline.cid == pairing.fingerprint else {
                throw DeviceMigrationStoreError.corruptRecord
            }
        }

        if let marker,
           Self.isMigrationMarker(marker, identity: identity),
           let ownerID,
           let pending = try self.loadPendingRekey(ownerID: ownerID),
           pending.previousCID == pairing.fingerprint {
            return .migrationRecovery
        }

        guard let marker else {
            return portable.baseline == nil ? .firstAdoption : .movedDevice
        }

        guard let adoption = marker.adoption else {
            return portable.baseline == nil ? .firstAdoption : .movedDevice
        }

        switch adoption {
        case .pending(let markerIdentity) where markerIdentity == identity:
            return .interruptedAdoption
        case .adopted(let markerIdentity) where markerIdentity == identity && portable.baseline == nil:
            throw DeviceMigrationStoreError.corruptRecord
        case .pending(let markerIdentity) where markerIdentity != identity:
            return .journalChanged
        case .pending:
            return .journalChanged
        case .migrating(let markerIdentity) where markerIdentity == identity:
            guard let baseline = portable.baseline,
                  baseline.cid == pairing.fingerprint else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            return baseline.deviceMarkerFingerprint == marker.fingerprint ? .sameDevice : .movedDevice
        case .migrating:
            return .journalChanged
        case .adopted(let markerIdentity) where markerIdentity != identity:
            return .journalChanged
        case .adopted:
            guard let baseline = portable.baseline,
                  baseline.cid == pairing.fingerprint else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            return baseline.deviceMarkerFingerprint == marker.fingerprint ? .sameDevice : .movedDevice
        }
    }

    func adopt(
        pairing: StoredPairing,
        includeFreshPairOffer: Bool,
        marker: DeviceMigrationMarker? = nil
    ) throws -> DeviceMigrationMarker {
        let localMarker = try self.prepareAdoption(
            pairing: pairing,
            includeFreshPairOffer: includeFreshPairOffer,
            marker: marker
        )
        try self.finishAdoption(pairing: pairing, marker: localMarker)
        return localMarker
    }

    func prepareAdoption(
        pairing: StoredPairing,
        includeFreshPairOffer: Bool,
        marker: DeviceMigrationMarker? = nil
    ) throws -> DeviceMigrationMarker {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var localMarker = try self.loadMarker() ?? marker ?? .fresh()
        if case .adopted(let adoptedIdentity) = localMarker.adoption,
           adoptedIdentity == identity {
            var existing = try self.loadPortable(for: identity)
            let baseline = DeviceMigrationBaseline(
                identity: identity,
                cid: pairing.fingerprint,
                deviceMarkerFingerprint: localMarker.fingerprint
            )
            if existing.baseline != baseline {
                localMarker.adoption = .pending(identity)
                try self.saveMarker(localMarker)
                existing.stagedBaseline = baseline
            }
            if includeFreshPairOffer,
               existing.replacementOffer?.pairingFingerprint != pairing.fingerprint {
                existing.replacementOffer = FreshPairReplacementOffer(
                    operationID: UUID(),
                    pairingOwnerID: nil,
                    pairingFingerprint: pairing.fingerprint,
                    state: .awaitingMarkConfirmation,
                    targetCID: nil,
                    requestBytes: nil
                )
            }
            try self.savePortable(existing, for: identity)
            return localMarker
        }
        if case .adopted(let adoptedIdentity) = localMarker.adoption,
           adoptedIdentity != identity {
            // A deliberate pairing replacement starts a new baseline under the same
            // device marker. The old portable item is left intact under its own identity.
        }
        localMarker.adoption = .pending(identity)
        try self.saveMarker(localMarker)

        var portable = try self.loadPortable(for: identity)
        portable.stagedBaseline = DeviceMigrationBaseline(
            identity: identity,
            cid: pairing.fingerprint,
            deviceMarkerFingerprint: localMarker.fingerprint
        )
        if includeFreshPairOffer,
           portable.replacementOffer?.pairingFingerprint != pairing.fingerprint {
            portable.replacementOffer = FreshPairReplacementOffer(
                operationID: UUID(),
                pairingOwnerID: nil,
                pairingFingerprint: pairing.fingerprint,
                state: .awaitingMarkConfirmation,
                targetCID: nil,
                requestBytes: nil
            )
        }
        try self.savePortable(portable, for: identity)

        return localMarker
    }

    func finishAdoption(pairing: StoredPairing, marker: DeviceMigrationMarker? = nil) throws {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var localMarker = try self.loadMarker() ?? marker ?? .fresh()
        guard case .pending(let pendingIdentity) = localMarker.adoption,
              pendingIdentity == identity else {
            if case .adopted(let adoptedIdentity) = localMarker.adoption,
               adoptedIdentity == identity { return }
            throw DeviceMigrationStoreError.corruptRecord
        }
        var portable = try self.loadPortable(for: identity)
        guard let baseline = portable.stagedBaseline,
              baseline.identity == identity,
              baseline.cid == pairing.fingerprint else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        portable.baseline = baseline
        portable.stagedBaseline = nil
        try self.savePortable(portable, for: identity)
        localMarker.adoption = .adopted(identity)
        try self.saveMarker(localMarker)
    }

    /// Finishes a user initiated credential replacement after the new pairing is
    /// durable. The current offer always belongs to this pairing, including when an
    /// earlier same-journal offer was dismissed or completed.
    func finishFreshPairing(pairing: StoredPairing, includeFreshPairOffer: Bool) throws {
        try deviceMigrationMutationLock.withLock {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var marker = try self.loadMarker() ?? .fresh()
        marker.adoption = .pending(identity)
        try self.saveMarker(marker)

        var portable = try self.loadPortable(for: identity)
        let baseline = DeviceMigrationBaseline(
            identity: identity,
            cid: pairing.fingerprint,
            deviceMarkerFingerprint: marker.fingerprint
        )
        portable.stagedBaseline = baseline
        portable.transaction = nil
        if includeFreshPairOffer {
            portable.replacementOffer = FreshPairReplacementOffer(
                operationID: UUID(),
                pairingOwnerID: nil,
                pairingFingerprint: pairing.fingerprint,
                state: .awaitingMarkConfirmation,
                targetCID: nil,
                requestBytes: nil
            )
        } else {
            portable.replacementOffer = nil
        }
        try self.savePortable(portable, for: identity)
        portable.baseline = baseline
        portable.stagedBaseline = nil
        try self.savePortable(portable, for: identity)
        marker.adoption = .adopted(identity)
        try self.saveMarker(marker)
        }
    }

    func stageMigration(
        from oldPairing: StoredPairing,
        to newPairing: StoredPairing,
        marker: DeviceMigrationMarker,
        priorSendWasConfirmed: Bool,
        pairingOwnerID: UUID
    ) throws {
        try deviceMigrationMutationLock.withLock {
        guard try self.owns(ownerID: pairingOwnerID, pairing: oldPairing) else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        let identity = try DevicePairingIdentity.make(for: oldPairing)
        guard identity == (try DevicePairingIdentity.make(for: newPairing)) else {
            throw DeviceMigrationStoreError.invalidPairing
        }
        guard let pending = try self.loadPendingRekey(ownerID: pairingOwnerID),
              pending.previousCID == oldPairing.fingerprint else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        var portable = try self.loadPortable(for: identity)
        let expectedBaselineCID = portable.baseline?.cid ?? oldPairing.fingerprint
        portable.stagedBaseline = DeviceMigrationBaseline(
            identity: identity,
            cid: newPairing.fingerprint,
            deviceMarkerFingerprint: marker.fingerprint
        )
        portable.transaction = DeviceMigrationTransaction(
            previousCID: oldPairing.fingerprint,
            currentCID: newPairing.fingerprint,
            expectedBaselineCID: expectedBaselineCID,
            rekeyOperationID: nil,
            pairingOwnerID: pairingOwnerID,
            phase: .credentialPrepared,
            priorSendWasConfirmed: priorSendWasConfirmed,
            sameInstanceAndCA: true,
            decisionState: .waiting,
            decisionBytes: nil,
            decisionID: nil,
            choice: nil,
            targetCID: nil,
            terminalState: nil
        )
        try self.savePortable(portable, for: identity)
        }
    }

    func prepareMigrationCredentialCommit(pairing: StoredPairing, ownerID: UUID) throws {
        try deviceMigrationMutationLock.withLock {
            let identity = try DevicePairingIdentity.make(for: pairing)
            guard try self.owns(ownerID: ownerID) else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            var portable = try self.loadPortable(for: identity)
            guard var transaction = portable.transaction,
                  transaction.pairingOwnerID == ownerID,
                  transaction.currentCID == pairing.fingerprint,
                  transaction.phase == .credentialPrepared || transaction.phase == .credentialCommitted else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            let operationID: UUID
            if let pending = try self.loadPendingRekey(ownerID: ownerID) {
                guard pending.previousCID == transaction.previousCID,
                      transaction.rekeyOperationID == nil || transaction.rekeyOperationID == pending.operationID else {
                    throw DeviceMigrationStoreError.corruptRecord
                }
                operationID = pending.operationID
            } else if let committedOperationID = transaction.rekeyOperationID {
                operationID = committedOperationID
            } else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            transaction.rekeyOperationID = operationID
            portable.transaction = transaction
            try self.savePortable(portable, for: identity)
            if let existing = try self.loadReceipt(ownerID: ownerID) {
                guard existing.operationID == operationID,
                      existing.previousCID == transaction.previousCID,
                      existing.currentCID == transaction.currentCID else {
                    throw DeviceMigrationStoreError.corruptRecord
                }
                return
            }
            let receipt = DeviceMigrationReceipt(
                operationID: operationID,
                pairingOwnerID: ownerID,
                previousCID: transaction.previousCID,
                currentCID: transaction.currentCID
            )
            try self.saveReceipt(receipt, ownerID: ownerID)
        }
    }

    func beginMigrationMarker(for identity: DevicePairingIdentity) throws -> DeviceMigrationMarker {
        var marker = try self.loadMarker() ?? .fresh()
        marker.adoption = .migrating(identity)
        try self.saveMarker(marker)
        return marker
    }

    func finishMigration(
        pairing: StoredPairing,
        marker: DeviceMigrationMarker
    ) throws {
        try deviceMigrationMutationLock.withLock {
        let identity = try DevicePairingIdentity.make(for: pairing)
        var portable = try self.loadPortable(for: identity)
        guard var transaction = portable.transaction,
              transaction.currentCID == pairing.fingerprint else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        guard let ownerID = transaction.pairingOwnerID else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        guard try self.owns(ownerID: ownerID) else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        let markerMatchesIdentity: Bool
        switch marker.adoption {
        case .migrating(let markerIdentity), .adopted(let markerIdentity):
            markerMatchesIdentity = markerIdentity == identity
        case .pending, .none:
            markerMatchesIdentity = false
        }
        guard markerMatchesIdentity else {
            throw DeviceMigrationStoreError.corruptRecord
        }

        let stagedBaseline = portable.stagedBaseline
        let baseline = portable.baseline
        let expectedBaselineCID = transaction.expectedBaselineCID ?? transaction.previousCID
        let baselineAndStageDescribeCandidate = baseline?.identity == identity
            && (baseline?.cid == expectedBaselineCID
                || baseline?.cid == transaction.previousCID
                || baseline?.cid == pairing.fingerprint)
            && (stagedBaseline == nil || (stagedBaseline?.identity == identity && stagedBaseline?.cid == pairing.fingerprint))
        let portableMarkerFingerprint = baseline?.deviceMarkerFingerprint
        let pending = try self.loadPendingRekey(ownerID: ownerID)
        let receipt = try self.loadReceipt(ownerID: ownerID)
        let localCommitProof = { (operationID: UUID?) -> Bool in
            guard let operationID else { return false }
            return pending.map {
                $0.operationID == operationID
                    && $0.pairingOwnerID == ownerID
                    && $0.previousCID == transaction.previousCID
            } == true || receipt.map {
                $0.operationID == operationID
                    && $0.pairingOwnerID == ownerID
                    && $0.previousCID == transaction.previousCID
                    && $0.currentCID == transaction.currentCID
            } == true
        }
        let markerIdentityMatches: Bool
        switch marker.adoption {
        case .migrating(let markerIdentity), .adopted(let markerIdentity):
            markerIdentityMatches = markerIdentity == identity
        case .pending, .none:
            markerIdentityMatches = false
        }
        let markerMismatchRecoverable = transaction.rekeyOperationID != nil
            && (transaction.phase == .credentialPrepared || transaction.phase == .credentialCommitted)
            && baselineAndStageDescribeCandidate
            && portableMarkerFingerprint != marker.fingerprint
            && localCommitProof(transaction.rekeyOperationID)
            && markerIdentityMatches
        let baselineIsPrevious = baseline?.identity == identity
            && (baseline?.cid == expectedBaselineCID || baseline?.cid == transaction.previousCID)
            && (baseline?.deviceMarkerFingerprint == marker.fingerprint || markerMismatchRecoverable)
        let baselineIsCurrent = baseline?.identity == identity
            && baseline?.cid == pairing.fingerprint
            && (baseline?.deviceMarkerFingerprint == marker.fingerprint || markerMismatchRecoverable)
        let stagedIsCurrent = stagedBaseline?.identity == identity
            && stagedBaseline?.cid == pairing.fingerprint
            && (stagedBaseline?.deviceMarkerFingerprint == marker.fingerprint || markerMismatchRecoverable)
        guard (baselineIsPrevious && stagedIsCurrent)
            || (baselineIsCurrent && (stagedBaseline == nil || stagedIsCurrent)) else {
            throw DeviceMigrationStoreError.corruptRecord
        }

        if let pending {
            guard pending.pairingOwnerID == ownerID,
                  pending.previousCID == transaction.previousCID else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            if let operationID = transaction.rekeyOperationID, operationID != pending.operationID {
                throw DeviceMigrationStoreError.corruptRecord
            }
            transaction.rekeyOperationID = pending.operationID
            let expectedReceipt = DeviceMigrationReceipt(
                operationID: pending.operationID,
                pairingOwnerID: ownerID,
                previousCID: transaction.previousCID,
                currentCID: transaction.currentCID
            )
            if let receipt, receipt != expectedReceipt {
                throw DeviceMigrationStoreError.corruptRecord
            }
        } else if transaction.rekeyOperationID == nil {
            guard let receipt else { throw DeviceMigrationStoreError.corruptRecord }
            transaction.rekeyOperationID = receipt.operationID
        }

        guard let operationID = transaction.rekeyOperationID else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        if pending == nil, transaction.terminalState == nil, receipt == nil {
            throw DeviceMigrationStoreError.corruptRecord
        }
        if let receipt {
            guard receipt.operationID == operationID,
                  receipt.pairingOwnerID == ownerID,
                  receipt.previousCID == transaction.previousCID,
                  receipt.currentCID == transaction.currentCID else {
                throw DeviceMigrationStoreError.corruptRecord
            }
        }

        if receipt == nil, let pending, transaction.terminalState == nil {
            let committedReceipt = DeviceMigrationReceipt(
                operationID: pending.operationID,
                pairingOwnerID: ownerID,
                previousCID: transaction.previousCID,
                currentCID: transaction.currentCID
            )
            try self.saveReceipt(committedReceipt, ownerID: ownerID)
        }

        if transaction.phase == .credentialPrepared {
            guard baselineIsPrevious, stagedIsCurrent, transaction.terminalState == nil else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            transaction.rekeyOperationID = operationID
            transaction.phase = .credentialCommitted
            portable.transaction = transaction
            try self.savePortable(portable, for: identity)
        } else {
            guard transaction.phase == .credentialCommitted else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            if portable.transaction?.rekeyOperationID != operationID {
                transaction.rekeyOperationID = operationID
                portable.transaction = transaction
                try self.savePortable(portable, for: identity)
            }
        }

        if transaction.terminalState != nil {
            guard baselineIsCurrent, stagedBaseline == nil else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            if pending != nil {
                try self.deletePendingRekey(ownerID: ownerID, operationID: operationID)
            }
            if receipt != nil {
                try self.deleteReceipt(ownerID: ownerID, operationID: operationID)
            }
            return
        }

        // The candidate credential and a committed operation receipt are durable
        // before ownership or the portable expected-CID baseline can advance.
        try self.updateCredential(ownerID: ownerID, pairing: pairing)

        if !baselineIsCurrent || stagedBaseline != nil {
            guard let stagedBaseline, stagedIsCurrent else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            portable.baseline = stagedBaseline
            portable.stagedBaseline = nil
            portable.transaction = transaction
            try self.savePortable(portable, for: identity)
        }

        if marker.adoption != .adopted(identity) {
            var completedMarker = marker
            completedMarker.adoption = .adopted(identity)
            try self.saveMarker(completedMarker)
        }

        if pending != nil {
            try self.deletePendingRekey(ownerID: ownerID, operationID: operationID)
        }
        }
    }

    func adoptRecoveredMigrationOnCurrentDevice(pairing: StoredPairing, marker: DeviceMigrationMarker) throws {
        try deviceMigrationMutationLock.withLock {
            let identity = try DevicePairingIdentity.make(for: pairing)
            let markerMatchesIdentity: Bool
            switch marker.adoption {
            case .migrating(let markerIdentity), .adopted(let markerIdentity):
                markerMatchesIdentity = markerIdentity == identity
            case .pending, .none:
                markerMatchesIdentity = false
            }
            var portable = try self.loadPortable(for: identity)
            guard let transaction = portable.transaction,
                  transaction.phase == .credentialCommitted,
                  transaction.currentCID == pairing.fingerprint,
                  transaction.rekeyOperationID != nil,
                  let ownerID = transaction.pairingOwnerID,
                  try self.owns(ownerID: ownerID, pairing: pairing),
                  markerMatchesIdentity,
                  portable.stagedBaseline == nil,
                  portable.baseline?.identity == identity,
                  portable.baseline?.cid == pairing.fingerprint else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            portable.baseline = DeviceMigrationBaseline(
                identity: identity,
                cid: pairing.fingerprint,
                deviceMarkerFingerprint: marker.fingerprint
            )
            try self.savePortable(portable, for: identity)
            var adoptedMarker = marker
            adoptedMarker.adoption = .adopted(identity)
            try self.saveMarker(adoptedMarker)
        }
    }

    func repairCommittedMigration(pairing: StoredPairing) throws {
        let identity = try DevicePairingIdentity.make(for: pairing)
        guard let marker = try self.loadMarker(),
              let portable = try? self.loadPortable(for: identity),
              let transaction = portable.transaction,
              transaction.phase == .credentialCommitted,
              transaction.currentCID == pairing.fingerprint else { return }
        try self.finishMigration(pairing: pairing, marker: marker)
    }

    func saveDecision(
        identity: DevicePairingIdentity,
        ownerID: UUID,
        decisionID: UUID,
        choice: DeviceMigrationChoice,
        targetCID: String?,
        requestBytes: Data
    ) throws {
        try deviceMigrationMutationLock.withLock {
        guard try self.owns(ownerID: ownerID),
              choice != .replaceDevice,
              targetCID == nil,
              let transaction = try self.loadPortable(for: identity).transaction,
              transaction.phase == .credentialCommitted,
              transaction.rekeyOperationID != nil,
              transaction.pairingOwnerID == ownerID else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        var portable = try self.loadPortable(for: identity)
        guard var transaction = portable.transaction,
              transaction.phase == .credentialCommitted else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        if let prior = transaction.decisionID {
            guard prior == decisionID,
                  transaction.choice == choice,
                  transaction.targetCID == targetCID,
                  transaction.decisionBytes == requestBytes else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            return
        }
        let request = try JSONDecoder().decode(DeviceMigrationDecisionRequest.self, from: requestBytes)
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard request.protocolVersion == 1,
              request.operationID == decisionID,
              request.choice == choice,
              request.replacesCID == nil,
              try encoder.encode(request) == requestBytes else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        transaction.decisionID = decisionID
        transaction.choice = choice
        transaction.targetCID = targetCID
        transaction.decisionBytes = requestBytes
        transaction.decisionState = .submitting
        portable.transaction = transaction
        try self.savePortable(portable, for: identity)
        }
    }

    func saveFreshPairDecision(
        identity: DevicePairingIdentity,
        ownerID: UUID,
        offerID: UUID,
        targetCID: String,
        requestBytes: Data
    ) throws {
        try deviceMigrationMutationLock.withLock {
        guard try self.owns(ownerID: ownerID),
              Self.validCID(targetCID),
              let owner = try self.ownershipRecord().active,
              owner.id == ownerID,
              let current = try self.loadPortable(for: identity).replacementOffer,
              current.operationID == offerID,
              current.pairingOwnerID == ownerID,
              current.pairingFingerprint == owner.credentialCID,
              current.state == .available || current.state == .unknown || current.state == .submitting else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        if current.state == .submitting || current.state == .unknown {
            guard current.targetCID == targetCID, current.requestBytes == requestBytes else {
                throw DeviceMigrationStoreError.corruptRecord
            }
            return
        }
        let decoder = JSONDecoder()
        let request = try decoder.decode(DeviceMigrationDecisionRequest.self, from: requestBytes)
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard request.protocolVersion == 1,
              request.operationID == offerID,
              request.choice == .replaceDevice,
              request.replacesCID == targetCID,
              try encoder.encode(request) == requestBytes else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        try self.updateReplacementOffer(identity: identity, ownerID: ownerID, operationID: offerID) {
            $0.state = .submitting
            $0.targetCID = targetCID
            $0.requestBytes = requestBytes
        }
        }
    }

    func updateDecision(
        identity: DevicePairingIdentity,
        state: DeviceMigrationDecisionState,
        terminalState: DeviceMigrationServerState? = nil,
        ownerID: UUID,
        decisionID: UUID
    ) throws {
        try deviceMigrationMutationLock.withLock {
        guard try self.owns(ownerID: ownerID) else { throw DeviceMigrationStoreError.ownershipUnavailable }
        var portable = try self.loadPortable(for: identity)
        guard var transaction = portable.transaction,
              transaction.pairingOwnerID == ownerID,
              transaction.decisionID == decisionID else { throw DeviceMigrationStoreError.ownershipUnavailable }
        transaction.decisionState = state
        if let terminalState {
            transaction.terminalState = terminalState
            transaction.decisionState = .complete
        }
        portable.transaction = transaction
        try self.savePortable(portable, for: identity)
        if terminalState != nil { try self.deleteReceipt(ownerID: ownerID, operationID: transaction.rekeyOperationID) }
        }
    }

    func markMigrationChoicePresented(
        identity: DevicePairingIdentity,
        ownerID: UUID,
        rekeyOperationID: UUID
    ) throws {
        try deviceMigrationMutationLock.withLock {
            guard try self.owns(ownerID: ownerID) else { throw DeviceMigrationStoreError.ownershipUnavailable }
            var portable = try self.loadPortable(for: identity)
            guard var transaction = portable.transaction,
                  transaction.pairingOwnerID == ownerID,
                  transaction.rekeyOperationID == rekeyOperationID,
                  transaction.phase == .credentialCommitted else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
            transaction.presentationShown = true
            portable.transaction = transaction
            try self.savePortable(portable, for: identity)
        }
    }

    func updateReplacementOffer(
        identity: DevicePairingIdentity,
        ownerID: UUID,
        operationID: UUID? = nil,
        _ update: (inout FreshPairReplacementOffer) -> Void
    ) throws {
        try deviceMigrationMutationLock.withLock {
        let currentOwner = try self.ownershipRecord().active
        guard try self.owns(ownerID: ownerID),
              currentOwner?.id == ownerID else { throw DeviceMigrationStoreError.ownershipUnavailable }
        var portable = try self.loadPortable(for: identity)
        guard var offer = portable.replacementOffer,
              offer.pairingOwnerID == ownerID,
              offer.pairingFingerprint == currentOwner?.credentialCID,
              operationID == nil || offer.operationID == operationID else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        update(&offer)
        portable.replacementOffer = offer
        try self.savePortable(portable, for: identity)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) throws -> Value? {
        guard let data else { return nil }
        guard let value = try? self.decoder.decode(type, from: data) else {
            migrationStoreLog.error("device migration keychain record was corrupt")
            throw DeviceMigrationStoreError.corruptRecord
        }
        return value
    }

    private static func validCID(_ cid: String) -> Bool {
        guard cid.hasPrefix("sha256:") else { return false }
        let hex = cid.dropFirst("sha256:".count)
        return hex.count == 64 && hex.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isMigrationMarker(_ marker: DeviceMigrationMarker, identity: DevicePairingIdentity) -> Bool {
        switch marker.adoption {
        case .migrating(let markerIdentity), .adopted(let markerIdentity):
            return markerIdentity == identity
        case .pending, .none:
            return false
        }
    }

    private static func migrationBaselineMatchesMarker(
        _ portable: DeviceMigrationPortableRecord,
        transaction: DeviceMigrationTransaction,
        marker: DeviceMigrationMarker
    ) -> Bool {
        let baselineMatches = portable.baseline?.cid == transaction.currentCID
            && portable.baseline?.deviceMarkerFingerprint == marker.fingerprint
        let stagedMatches = portable.stagedBaseline?.cid == transaction.currentCID
            && portable.stagedBaseline?.deviceMarkerFingerprint == marker.fingerprint
        return baselineMatches || stagedMatches
    }
}
