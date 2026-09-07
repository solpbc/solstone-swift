// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let jobsLog = Logger(subsystem: "app.solstone.swift", category: "home-jobs")

/// Manages asynchronous post-connection jobs: device description publication and relay access acquisition.
/// Note: UIDevice provides no system notification for device name mutations. Device descriptions are
/// resampled on the next connection lifecycle event.
@MainActor
final class HomeAuthenticatedJobs {
    private let store: PairingCredentialStore
    private let journalVersion: JournalVersionMetadata
    private let client: AuthenticatedHomeClient
    private let deadline: Duration
    private let snapshotProvider: @MainActor () -> DeviceDescriptionSnapshot

    private var metadataGeneration: UInt64 = 0
    private var accessGeneration: UInt64 = 0
    private var activePort: Int?

    private var pendingSnapshot: DeviceDescriptionSnapshot?
    private var pendingAccessTrigger = false
    private var pendingDurableClear: (pairingGen: UInt64, mutationGen: UInt64)?

    private var metadataTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?

    init(
        store: PairingCredentialStore,
        journalVersion: JournalVersionMetadata,
        client: AuthenticatedHomeClient = AuthenticatedHomeClient(),
        deadline: Duration = .seconds(15),
        snapshotProvider: @escaping @MainActor () -> DeviceDescriptionSnapshot = { DeviceDescriptionSnapshot.current() }
    ) {
        self.store = store
        self.journalVersion = journalVersion
        self.client = client
        self.deadline = deadline
        self.snapshotProvider = snapshotProvider
    }

    func connected(localPort: Int) {
        self.activePort = localPort
        self.journalVersion.noteConnected(localPort: localPort)

        let snapshot = self.snapshotProvider()
        self.pendingSnapshot = snapshot

        // Start or coalesce Metadata Publication Job
        if self.metadataTask == nil {
            self.metadataGeneration &+= 1
            let gen = self.metadataGeneration
            self.startMetadataJob(localPort: localPort, generation: gen)
        }

        // Start or coalesce Relay Access Job
        if self.accessTask == nil {
            self.accessGeneration &+= 1
            let gen = self.accessGeneration
            self.startAccessJob(localPort: localPort, generation: gen)
        } else {
            self.pendingAccessTrigger = true
        }
    }

    func disconnected() {
        self.metadataGeneration &+= 1
        self.accessGeneration &+= 1
        self.activePort = nil
        self.pendingSnapshot = nil
        self.pendingAccessTrigger = false
        self.metadataTask?.cancel()
        self.metadataTask = nil
        self.accessTask?.cancel()
        self.accessTask = nil
    }

    private func startMetadataJob(localPort: Int, generation: UInt64) {
        self.metadataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = self.deadline

            let workTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled,
                      self.metadataGeneration == generation && self.activePort == localPort,
                      let snapshot = self.pendingSnapshot {
                    self.pendingSnapshot = nil
                    await self.executeMetadataPublication(snapshot: snapshot, localPort: localPort, generation: generation)
                }
            }

            let completedNaturally = await withTaskCancellationHandler {
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        _ = await workTask.result
                        return true
                    }
                    group.addTask {
                        try? await Task.sleep(for: deadline)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
            } onCancel: {
                workTask.cancel()
            }

            guard self.metadataGeneration == generation, self.activePort == localPort else {
                return
            }

            self.metadataTask = nil
            if !completedNaturally {
                workTask.cancel()
                self.metadataGeneration &+= 1
            }
            if self.pendingSnapshot != nil, let currentPort = self.activePort {
                if completedNaturally {
                    self.metadataGeneration &+= 1
                }
                let currentGen = self.metadataGeneration
                self.startMetadataJob(localPort: currentPort, generation: currentGen)
            }
        }
    }

    private func executeMetadataPublication(
        snapshot: DeviceDescriptionSnapshot,
        localPort: Int,
        generation: UInt64
    ) async {
        let client = self.client
        let deadline = self.deadline

        let fetchResult = await client.fetchClientsSelf(localPort: localPort, timeout: deadline)
        guard self.metadataGeneration == generation, self.activePort == localPort else {
            return
        }

        switch fetchResult {
        case .success(let resource):
            if let journal = resource.journal {
                self.journalVersion.applyValidated(name: journal.name, version: journal.version)
            }

            let localReported = snapshot.asReported()
            if resource.reported == localReported {
                // Unchanged snapshot; skip PUT
                return
            }

            let payload = ClientsSelfPutPayload(expectedRevision: resource.revision, reported: localReported)
            let putResult = await client.putClientsSelf(localPort: localPort, payload: payload, timeout: deadline)
            guard self.metadataGeneration == generation, self.activePort == localPort else {
                return
            }

            if case .conflict = putResult {
                // Stale revision: reread GET and retry PUT at most once with newest local snapshot
                let refetchResult = await client.fetchClientsSelf(localPort: localPort, timeout: deadline)
                guard self.metadataGeneration == generation, self.activePort == localPort else {
                    return
                }
                if case .success(let newResource) = refetchResult {
                    if let journal = newResource.journal {
                        self.journalVersion.applyValidated(name: journal.name, version: journal.version)
                    }
                    let latestSnapshot = self.pendingSnapshot ?? snapshot
                    self.pendingSnapshot = nil
                    let retryPayload = ClientsSelfPutPayload(expectedRevision: newResource.revision, reported: latestSnapshot.asReported())
                    _ = await client.putClientsSelf(localPort: localPort, payload: retryPayload, timeout: deadline)
                }
            }

        case .notFound, .unsupported:
            // Fallback for older home versions
            let statusVersion = await client.fetchStatus(localPort: localPort, timeout: deadline)
            guard self.metadataGeneration == generation, self.activePort == localPort else {
                return
            }
            if let statusVersion {
                self.journalVersion.applyValidated(name: nil, version: statusVersion)
            }

        case .conflict, .malformedOrFailed:
            // Optional failure: keep last known metadata
            break
        }
    }

    private func startAccessJob(localPort: Int, generation: UInt64) {
        self.accessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = self.deadline

            let workTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeRelayAccess(localPort: localPort, generation: generation)
            }

            let completedNaturally = await withTaskCancellationHandler {
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        _ = await workTask.result
                        return true
                    }
                    group.addTask {
                        try? await Task.sleep(for: deadline)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
            } onCancel: {
                workTask.cancel()
            }

            guard self.accessGeneration == generation, self.activePort == localPort else {
                return
            }

            self.accessTask = nil
            if !completedNaturally {
                workTask.cancel()
                self.accessGeneration &+= 1
            }
            if self.pendingAccessTrigger {
                self.pendingAccessTrigger = false
                if let currentPort = self.activePort {
                    if completedNaturally {
                        self.accessGeneration &+= 1
                    }
                    let currentGen = self.accessGeneration
                    self.startAccessJob(localPort: currentPort, generation: currentGen)
                }
            }
        }
    }

    private func executeRelayAccess(localPort: Int, generation: UInt64) async {
        // Retry any pending durable clear if generation and mutationGen still match
        if let pending = self.pendingDurableClear,
           pending.pairingGen == self.store.pairingGeneration,
           pending.mutationGen == self.store.accessMutationGeneration {
            do {
                if try self.store.disableRelayAccess(pairingGen: pending.pairingGen, mutationGen: pending.mutationGen) {
                    self.pendingDurableClear = nil
                }
            } catch {
                // Keep pending clear
            }
        }

        let client = self.client
        let deadline = self.deadline
        let fetchResult = await client.fetchRelayAccess(localPort: localPort, timeout: deadline)

        guard self.accessGeneration == generation, self.activePort == localPort else {
            return
        }

        let store = self.store
        guard let pairing = try? store.load() else {
            return
        }

        switch fetchResult {
        case .ready(let payload):
            guard RelayAccessClaims.validateReadyPayload(payload, pairedInstanceID: pairing.instanceID) else {
                return
            }
            let pairingGen = store.pairingGeneration
            let mutationGen = store.accessMutationGeneration
            if (try? store.commitReadyAccess(
                relayOrigin: payload.relayOrigin,
                deviceToken: payload.deviceToken,
                expiresAt: payload.expiresAt,
                pairingGen: pairingGen,
                mutationGen: mutationGen
            )) == true {
                self.pendingDurableClear = nil
            }

        case .notConfigured:
            let pairingGen = store.pairingGeneration
            let mutationGen = store.accessMutationGeneration
            do {
                if try store.disableRelayAccess(
                    pairingGen: pairingGen,
                    mutationGen: mutationGen
                ) {
                    self.pendingDurableClear = nil
                }
            } catch {
                self.pendingDurableClear = (pairingGen: pairingGen, mutationGen: mutationGen)
            }

        case .unavailable, .notFound, .malformedOrFailed:
            // Optional failure: retain existing access
            break
        }
    }
}
