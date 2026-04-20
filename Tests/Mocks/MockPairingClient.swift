// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockPairingClient: PairingClient {
    var confirmResponse = PairConfirmResponse(
        sessionKey: "pair-session",
        deviceID: "device-123",
        journalRoot: "https://journal.example.com",
        ownerIdentity: "sol",
        serverVersion: "test",
        host: "journal.example.com",
        port: 22
    )
    var progressResponse = ProgressSnapshot(
        segmentsObserved: 12,
        meetingsDetected: 3,
        entitiesIdentified: 14,
        percent: 48,
        briefingReady: false
    )
    var confirmError: PairingClientError?
    var unpairError: PairingClientError?
    var briefingError: PairingClientError?
    var progressError: PairingClientError?

    private(set) var lastConfirmToken: String?
    private(set) var lastConfirmPublicKey: String?
    private(set) var lastDeviceName: String?
    private(set) var lastPlatform: String?
    private(set) var lastBundleID: String?
    private(set) var lastAppVersion: String?
    private(set) var lastUnpairDeviceID: String?
    private(set) var lastUnpairSessionKey: String?
    private(set) var lastBriefingHour: Int?
    private(set) var lastBriefingMinute: Int?
    private(set) var lastBriefingTZIdentifier: String?
    private(set) var lastBriefingSessionKey: String?
    private(set) var lastProgressSessionKey: String?

    func confirm(
        token: String,
        publicKey: String,
        deviceName: String,
        platform: String,
        bundleID: String,
        appVersion: String
    ) async throws -> PairConfirmResponse {
        self.lastConfirmToken = token
        self.lastConfirmPublicKey = publicKey
        self.lastDeviceName = deviceName
        self.lastPlatform = platform
        self.lastBundleID = bundleID
        self.lastAppVersion = appVersion
        if let confirmError {
            throw confirmError
        }
        return self.confirmResponse
    }

    func unpair(deviceID: String, sessionKey: String) async throws {
        self.lastUnpairDeviceID = deviceID
        self.lastUnpairSessionKey = sessionKey
        if let unpairError {
            throw unpairError
        }
    }

    func setBriefingTime(hour: Int, minute: Int, tzIdentifier: String, sessionKey: String) async throws {
        self.lastBriefingHour = hour
        self.lastBriefingMinute = minute
        self.lastBriefingTZIdentifier = tzIdentifier
        self.lastBriefingSessionKey = sessionKey
        if let briefingError {
            throw briefingError
        }
    }

    func progressToday(sessionKey: String) async throws -> ProgressSnapshot {
        self.lastProgressSessionKey = sessionKey
        if let progressError {
            throw progressError
        }
        return self.progressResponse
    }
}
