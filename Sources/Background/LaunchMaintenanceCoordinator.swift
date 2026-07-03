// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let launchMaintenanceLog = Logger(subsystem: "app.solstone.swift", category: "launch-maintenance")

@MainActor
final class LaunchMaintenanceCoordinator {
    struct Operations {
        var migrateIngestKeyAccessibility: @MainActor () -> Void
        var startScreencastObserving: @MainActor () -> Void
        var reconcileScreencast: @MainActor (ScreencastReconcileReason) async -> Void
        var resumeImportQueue: @MainActor () async throws -> Void
        var migrateLegacyMobileItems: @MainActor () async throws -> Void
        var resumeMobileSegments: @MainActor () async throws -> Void
        var migrateLegacyAudioKeys: @MainActor () async throws -> Void
        var drainWatch: @MainActor () async throws -> Void
        var endStaleObserverActivitiesIfIdle: @MainActor () async throws -> Void
    }

    private static let mobileMigrationKey = "didMigrateLegacyMobileSegmentsV1"
    private static let audioMigrationKey = "didMigrateLegacyAudioSegmentKeysV1"

    private let operations: Operations
    private let defaults: UserDefaults
    private var isRunning = false
    private var hasCompleted = false
    private var runTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, operations: Operations) {
        self.defaults = defaults
        self.operations = operations
    }

    func runForegroundMaintenance() async {
        guard !Task.isCancelled else { return }
        guard !self.hasCompleted else { return }
        if self.isRunning {
            let task = self.runTask
            await task?.value
            guard !Task.isCancelled else { return }
            guard task?.isCancelled == true else { return }
            while self.isRunning {
                await Task.yield()
            }
            guard !self.hasCompleted else { return }
            await self.runForegroundMaintenance()
            return
        }

        self.isRunning = true
        let task = Task { @MainActor in
            await self.runPass()
        }
        self.runTask = task
        await task.value
        self.isRunning = false
        self.runTask = nil
    }

    func cancel() {
        self.runTask?.cancel()
    }

    private func runPass() async {
        guard !Task.isCancelled else { return }
        var passSucceeded = true

        self.operations.migrateIngestKeyAccessibility()
        guard !Task.isCancelled else { return }

        self.operations.startScreencastObserving()
        await self.operations.reconcileScreencast(.launch)
        guard !Task.isCancelled else { return }

        passSucceeded = await self.run("resumeImportQueue", passSucceeded: passSucceeded) {
            try await self.operations.resumeImportQueue()
        }
        guard !Task.isCancelled else { return }

        if self.defaults.bool(forKey: Self.mobileMigrationKey) {
            passSucceeded = await self.run("resumeMobileSegments", passSucceeded: passSucceeded) {
                try await self.operations.resumeMobileSegments()
            }
        } else {
            let migrated = await self.run("migrateLegacyMobileItems", passSucceeded: true) {
                try await self.operations.migrateLegacyMobileItems()
            }
            passSucceeded = passSucceeded && migrated
            if migrated && !Task.isCancelled {
                self.defaults.set(true, forKey: Self.mobileMigrationKey)
            }
        }
        guard !Task.isCancelled else { return }

        await self.operations.reconcileScreencast(.mobileSegmentResume)
        guard !Task.isCancelled else { return }

        if !self.defaults.bool(forKey: Self.audioMigrationKey) {
            let migrated = await self.run("migrateLegacyAudioKeys", passSucceeded: true) {
                try await self.operations.migrateLegacyAudioKeys()
            }
            passSucceeded = passSucceeded && migrated
            if migrated && !Task.isCancelled {
                self.defaults.set(true, forKey: Self.audioMigrationKey)
            }
        }
        guard !Task.isCancelled else { return }

        passSucceeded = await self.run("drainWatch", passSucceeded: passSucceeded) {
            try await self.operations.drainWatch()
        }
        guard !Task.isCancelled else { return }

        passSucceeded = await self.run("endStaleObserverActivitiesIfIdle", passSucceeded: passSucceeded) {
            try await self.operations.endStaleObserverActivitiesIfIdle()
        }

        if !Task.isCancelled && passSucceeded {
            self.hasCompleted = true
        }
    }

    private func run(
        _ operationName: String,
        passSucceeded: Bool,
        operation: @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await operation()
            return passSucceeded
        } catch {
            launchMaintenanceLog.error("launch maintenance failed operation=\(operationName, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
