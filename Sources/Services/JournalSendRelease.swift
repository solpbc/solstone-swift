// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import UIKit
import os

private let releaseLog = Logger(subsystem: "app.solstone.swift", category: "journal-send")

@MainActor
@Observable
final class JournalSendRelease {
    private let credentialStore: PairingCredentialStore
    private let confirmationStore: JournalSendConfirmationStore
    private let transferEngine: TransferEngine
    private let foregroundDrainGate: ForegroundDrainGate
    private let homeJobs: HomeAuthenticatedJobs?
    private let pushManagerProvider: @MainActor () -> PushNotificationManager?

    init(
        credentialStore: PairingCredentialStore,
        confirmationStore: JournalSendConfirmationStore,
        transferEngine: TransferEngine,
        foregroundDrainGate: ForegroundDrainGate,
        homeJobs: HomeAuthenticatedJobs? = nil,
        pushManager: PushNotificationManager? = nil,
        pushManagerProvider: (@MainActor () -> PushNotificationManager?)? = nil
    ) {
        self.credentialStore = credentialStore
        self.confirmationStore = confirmationStore
        self.transferEngine = transferEngine
        self.foregroundDrainGate = foregroundDrainGate
        self.homeJobs = homeJobs
        if let pushManager {
            self.pushManagerProvider = { pushManager }
        } else if let pushManagerProvider {
            self.pushManagerProvider = pushManagerProvider
        } else {
            self.pushManagerProvider = { (UIApplication.shared.delegate as? AppDelegate)?.pushManager }
        }
    }

    func authorize(_ appConfig: AppConfig, writeMarker: Bool = false) throws {
        let snapshot = self.credentialStore.snapshot()
        guard let pairing = snapshot.pairing,
              snapshot.deviceOwnerID != nil,
              self.credentialStore.hasActiveOwner,
              let key = journalSendConfirmationKey(for: pairing)
        else {
            releaseLog.error("\(JournalSendConfirmationStore.confirmFailedCode, privacy: .public)")
            throw JournalSendConfirmationStoreError.confirmFailed
        }

        do {
            try self.credentialStore.performOnKeychainQueue {
                if writeMarker {
                    try self.confirmationStore.grandfather(key: key)
                } else {
                    try self.confirmationStore.writeRecord(for: pairing)
                }
            }
        } catch {
            releaseLog.error("\(JournalSendConfirmationStore.confirmFailedCode, privacy: .public)")
            throw JournalSendConfirmationStoreError.confirmFailed
        }

        appConfig.journalSendConfirmed = true
        self.homeJobs?.confirmationDidChange()
        self.kickConfirmedSend()
    }

    func kickConfirmedSend() {
        Task { @MainActor in
            await self.transferEngine.endpointAvailabilityChanged()
            await self.foregroundDrainGate.requestDrain()
            if let pushManager = self.pushManagerProvider() {
                await pushManager.kickAfterConfirmation()
            }
        }
    }
}
