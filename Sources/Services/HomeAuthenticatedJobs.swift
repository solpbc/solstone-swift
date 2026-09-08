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
    private var activePairingGeneration: UInt64?
    private var metadataPermit: PairingMutationPermit?
    private var accessPermit: PairingMutationPermit?

    private var inFlightSnapshot: DeviceDescriptionSnapshot?
    private var pendingFollowUpSnapshot: DeviceDescriptionSnapshot?

    private var isAccessInFlight = false
    private var pendingAccessFollowUp = false

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
        let pairingGeneration = self.store.snapshot().pairingGeneration
        if self.activePort != localPort || self.activePairingGeneration != pairingGeneration {
            self.disconnected()
        }
        self.activePort = localPort
        self.activePairingGeneration = pairingGeneration
        self.journalVersion.noteConnected(localPort: localPort)

        let snapshot = self.snapshotProvider()

        // Metadata publication lane: single in-flight + at most one pending follow-up
        if self.metadataTask == nil {
            self.metadataGeneration &+= 1
            let gen = self.metadataGeneration
            self.inFlightSnapshot = snapshot
            self.pendingFollowUpSnapshot = nil
            self.startMetadataLane(localPort: localPort, generation: gen)
        } else {
            self.pendingFollowUpSnapshot = snapshot
        }

        // Relay access lane: single in-flight + at most one pending follow-up
        if self.accessTask == nil {
            self.accessGeneration &+= 1
            let gen = self.accessGeneration
            self.isAccessInFlight = true
            self.pendingAccessFollowUp = false
            self.startAccessLane(localPort: localPort, generation: gen)
        } else {
            self.pendingAccessFollowUp = true
        }
    }

    func disconnected() {
        self.metadataGeneration &+= 1
        self.accessGeneration &+= 1
        self.activePort = nil
        self.activePairingGeneration = nil
        self.metadataPermit?.cancel()
        self.accessPermit?.cancel()
        self.metadataPermit = nil
        self.accessPermit = nil
        self.inFlightSnapshot = nil
        self.pendingFollowUpSnapshot = nil
        self.isAccessInFlight = false
        self.pendingAccessFollowUp = false
        self.metadataTask?.cancel()
        self.metadataTask = nil
        self.accessTask?.cancel()
        self.accessTask = nil
    }

    private func raceWorkAgainstDeadline(
        until deadlineClock: ContinuousClock.Instant,
        work: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let workTask = Task { @MainActor in
            await work()
        }
        let finishedBeforeDeadline = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            Task {
                await workTask.value
                resumeOnce(true)
            }
            Task {
                try? await Task.sleep(until: deadlineClock, clock: ContinuousClock())
                resumeOnce(false)
            }
        }
        if !finishedBeforeDeadline {
            workTask.cancel()
            // do not await workTask
        }
        return finishedBeforeDeadline
    }

    private func startMetadataLane(localPort: Int, generation: UInt64) {
        let deadlineClock = ContinuousClock.now + self.deadline
        let permit = PairingMutationPermit(deadline: deadlineClock)
        self.metadataPermit = permit
        self.metadataTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for pass in 0..<2 {
                guard permit.isValid, !Task.isCancelled, self.metadataGeneration == generation, self.activePort == localPort else { break }
                let currentSnapshot: DeviceDescriptionSnapshot
                if pass == 0 {
                    guard let snap = self.inFlightSnapshot else { break }
                    currentSnapshot = snap
                } else {
                    guard let followUp = self.pendingFollowUpSnapshot else { break }
                    self.inFlightSnapshot = followUp
                    self.pendingFollowUpSnapshot = nil
                    currentSnapshot = followUp
                }

                let finishedBeforeDeadline = await self.raceWorkAgainstDeadline(until: deadlineClock) { [weak self] in
                    guard let self else { return }
                    await self.executeMetadataPublication(
                        snapshot: currentSnapshot,
                        localPort: localPort,
                        generation: generation,
                        deadlineClock: deadlineClock,
                        permit: permit
                    )
                }

                if !finishedBeforeDeadline {
                    break
                }
            }

            guard self.metadataGeneration == generation, self.activePort == localPort else { return }
            permit.cancel()
            self.metadataPermit = nil
            self.metadataTask = nil
            self.inFlightSnapshot = nil
            self.pendingFollowUpSnapshot = nil
        }
    }

    private func executeMetadataPublication(
        snapshot: DeviceDescriptionSnapshot,
        localPort: Int,
        generation: UInt64,
        deadlineClock: ContinuousClock.Instant,
        permit: PairingMutationPermit
    ) async {
        let snap = self.store.snapshot()
        guard permit.isValid, snap.pairingGeneration == self.activePairingGeneration,
              let pairingIdentity = snap.pairingIdentity else { return }
        let preFetchPairingGen = snap.pairingGeneration

        var remaining = deadlineClock - ContinuousClock.now
        guard remaining > .zero else { return }

        let client = self.client
        let fetchResult = await client.fetchClientsSelf(localPort: localPort, timeout: remaining)
        guard permit.isValid, !Task.isCancelled, self.metadataGeneration == generation, self.activePort == localPort else { return }
        let postFetchSnap = self.store.snapshot()
        guard postFetchSnap.pairingIdentity == pairingIdentity, postFetchSnap.pairingGeneration == preFetchPairingGen else { return }

        switch fetchResult {
        case .success(let resource):
            self.journalVersion.applyValidated(
                name: resource.journal.name,
                version: resource.journal.version,
                pairingIdentity: pairingIdentity,
                isClientsSelfUpdate: true
            )

            let localReported = snapshot.asReported()
            if resource.reported == localReported {
                return
            }

            remaining = deadlineClock - ContinuousClock.now
            guard remaining > .zero else { return }

            let payload = ClientsSelfPutPayload(expectedRevision: resource.revision, reported: localReported)
            let putResult = await client.putClientsSelf(localPort: localPort, payload: payload, timeout: remaining)
            guard permit.isValid, !Task.isCancelled, self.metadataGeneration == generation, self.activePort == localPort else { return }
            let postPutSnap = self.store.snapshot()
            guard postPutSnap.pairingIdentity == pairingIdentity, postPutSnap.pairingGeneration == preFetchPairingGen else { return }

            switch putResult {
            case .success(let putResource):
                self.journalVersion.applyValidated(
                    name: putResource.journal.name,
                    version: putResource.journal.version,
                    pairingIdentity: pairingIdentity,
                    isClientsSelfUpdate: true
                )

            case .conflict:
                remaining = deadlineClock - ContinuousClock.now
                guard remaining > .zero else { return }

                let refetchResult = await client.fetchClientsSelf(localPort: localPort, timeout: remaining)
                guard permit.isValid, !Task.isCancelled, self.metadataGeneration == generation, self.activePort == localPort else { return }
                let postRefetchSnap = self.store.snapshot()
                guard postRefetchSnap.pairingIdentity == pairingIdentity, postRefetchSnap.pairingGeneration == preFetchPairingGen else { return }

                if case .success(let newResource) = refetchResult {
                    self.journalVersion.applyValidated(
                        name: newResource.journal.name,
                        version: newResource.journal.version,
                        pairingIdentity: pairingIdentity,
                        isClientsSelfUpdate: true
                    )

                    let latestSnapshot = self.pendingFollowUpSnapshot ?? snapshot
                    self.pendingFollowUpSnapshot = nil
                    let retryPayload = ClientsSelfPutPayload(expectedRevision: newResource.revision, reported: latestSnapshot.asReported())

                    remaining = deadlineClock - ContinuousClock.now
                    guard remaining > .zero else { return }

                    let retryPutResult = await client.putClientsSelf(localPort: localPort, payload: retryPayload, timeout: remaining)
                    guard permit.isValid, !Task.isCancelled, self.metadataGeneration == generation, self.activePort == localPort else { return }
                    let current = self.store.snapshot()
                    guard current.pairingIdentity == pairingIdentity,
                          current.pairingGeneration == preFetchPairingGen else { return }

                    if case .success(let finalResource) = retryPutResult {
                        self.journalVersion.applyValidated(
                            name: finalResource.journal.name,
                            version: finalResource.journal.version,
                            pairingIdentity: pairingIdentity,
                            isClientsSelfUpdate: true
                        )
                    }
                }

            case .notFound, .failed:
                break
            }

        case .notFound:
            remaining = deadlineClock - ContinuousClock.now
            guard remaining > .zero else { return }

            let statusVersion = await client.fetchStatus(localPort: localPort, timeout: remaining)
            guard permit.isValid, !Task.isCancelled, self.metadataGeneration == generation, self.activePort == localPort else { return }
            let current = self.store.snapshot()
            guard current.pairingIdentity == pairingIdentity,
                  current.pairingGeneration == preFetchPairingGen else { return }

            if let statusVersion {
                self.journalVersion.applyValidated(
                    name: nil,
                    version: statusVersion,
                    pairingIdentity: pairingIdentity,
                    isClientsSelfUpdate: false
                )
            }

        case .unsupported, .conflict, .malformedOrFailed:
            break
        }
    }

    private func startAccessLane(localPort: Int, generation: UInt64) {
        let deadlineClock = ContinuousClock.now + self.deadline
        let permit = PairingMutationPermit(deadline: deadlineClock)
        self.accessPermit = permit
        self.accessTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for pass in 0..<2 {
                guard permit.isValid, !Task.isCancelled, self.accessGeneration == generation, self.activePort == localPort else { break }
                if pass == 0 {
                    guard self.isAccessInFlight else { break }
                } else {
                    guard self.pendingAccessFollowUp else { break }
                    self.pendingAccessFollowUp = false
                }

                let finishedBeforeDeadline = await self.raceWorkAgainstDeadline(until: deadlineClock) { [weak self] in
                    guard let self else { return }
                    await self.executeRelayAccess(
                        localPort: localPort,
                        generation: generation,
                        deadlineClock: deadlineClock,
                        permit: permit
                    )
                }

                if !finishedBeforeDeadline {
                    break
                }
            }

            guard self.accessGeneration == generation, self.activePort == localPort else { return }
            permit.cancel()
            self.accessPermit = nil
            self.accessTask = nil
            self.isAccessInFlight = false
            self.pendingAccessFollowUp = false
        }
    }

    private func executeRelayAccess(
        localPort: Int,
        generation: UInt64,
        deadlineClock: ContinuousClock.Instant,
        permit: PairingMutationPermit
    ) async {
        let initialSnap = self.store.snapshot()
        guard permit.isValid, initialSnap.pairingGeneration == self.activePairingGeneration else { return }
        if case .uncommittedClear(let pGen, let mGen) = initialSnap.failedDurableClear {
            _ = try? await self.store.retryDurableClear(pairingGen: pGen, mutationGen: mGen, mayPublish: { permit.isValid })
        }
        guard permit.isValid, !Task.isCancelled, self.accessGeneration == generation, self.activePort == localPort else { return }

        let snap = self.store.snapshot()
        guard let pairing = snap.pairing else { return }
        let preFetchPairingGen = snap.pairingGeneration
        let preFetchMutationGen = snap.accessMutationGeneration

        let remaining = deadlineClock - ContinuousClock.now
        guard remaining > .zero else { return }

        let client = self.client
        let fetchResult = await client.fetchRelayAccess(
            localPort: localPort,
            expectedInstanceID: pairing.instanceID,
            now: Date(),
            timeout: remaining
        )

        guard permit.isValid, !Task.isCancelled, self.accessGeneration == generation, self.activePort == localPort else { return }

        let currentSnap = self.store.snapshot()
        guard currentSnap.pairingGeneration == preFetchPairingGen,
              currentSnap.accessMutationGeneration == preFetchMutationGen,
              currentSnap.pairing?.instanceID == pairing.instanceID
        else { return }

        switch fetchResult {
        case .ready(let ready):
            _ = try? await self.store.commitReadyAccess(
                relayOrigin: ready.relayOrigin.absoluteString,
                deviceToken: ready.deviceToken,
                expiresAt: ready.expiresAt,
                pairingGen: preFetchPairingGen,
                mutationGen: preFetchMutationGen,
                mayPublish: { permit.isValid }
            )

        case .notConfigured:
            _ = try? await self.store.disableRelayAccess(
                pairingGen: preFetchPairingGen,
                mutationGen: preFetchMutationGen,
                mayPublish: { permit.isValid }
            )

        case .unavailable, .notFound, .malformedOrFailed:
            break
        }
    }
}

