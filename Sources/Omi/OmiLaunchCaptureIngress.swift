// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum OmiLaunchCaptureIngressAction: Equatable {
    case none
    case fault(shouldCancelConnection: Bool)
}

@MainActor
final class OmiLaunchCaptureIngress {
    private let appGroupRoot: () throws -> URL
    private let generationID: UUID
    private let clock: any ObserverClock
    private let io: any OmiLaunchCaptureIO
    private var writer: OmiLaunchCaptureWriter?
    private var didRequestConnectionStop = false
    private var didConsumeResume = false
    private(set) var didAttemptInitialArm = false

    var isArmed: Bool { self.writer != nil }

    init(
        appGroupRoot: @escaping () throws -> URL,
        generationID: UUID = UUID(),
        clock: any ObserverClock = SystemObserverClock(),
        io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO()
    ) {
        self.appGroupRoot = appGroupRoot
        self.generationID = generationID
        self.clock = clock
        self.io = io
    }

    func arm() -> Bool {
        guard self.writer == nil else { return true }
        self.didAttemptInitialArm = true
        guard let rootURL = try? self.appGroupRoot() else { return false }
        let writer = OmiLaunchCaptureWriter(
            rootURL: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: self.generationID,
            clock: self.clock,
            io: self.io
        )
        guard writer.arm() else { return false }
        self.writer = writer
        return true
    }

    func armForFirstEnable() -> Bool {
        guard !self.didAttemptInitialArm else { return false }
        return self.arm()
    }

    func resumeOnce() -> Bool {
        guard !self.isArmed, !self.didConsumeResume else { return false }
        self.didConsumeResume = true
        return self.arm()
    }

    func ingest(_ payload: Data) -> OmiLaunchCaptureIngressAction {
        guard let writer else { return self.faultAction() }
        if self.didRequestConnectionStop {
            // Cancellation is asynchronous, so retain pending-first ordering until it takes effect.
            return self.route(writer.append(payload), writer: writer, shouldCancelConnection: false)
        }

        return self.route(writer.append(payload), writer: writer, shouldCancelConnection: true)
    }

    private func route(
        _ outcome: OmiLaunchCaptureAppendOutcome,
        writer: OmiLaunchCaptureWriter,
        shouldCancelConnection: Bool
    ) -> OmiLaunchCaptureIngressAction {
        switch outcome {
        case .retained:
            return self.didRequestConnectionStop ? .fault(shouldCancelConnection: false) : .none
        case .notRetained:
            _ = writer.reserveGap()
            return self.faultAction(shouldCancelConnection: shouldCancelConnection)
        case .visibleGap:
            return self.faultAction(shouldCancelConnection: shouldCancelConnection)
        case .rejected(let reason):
            if case .pendingSlotOccupied = reason {
                _ = writer.reserveGap()
            }
            return self.faultAction(shouldCancelConnection: shouldCancelConnection)
        }
    }

    private func faultAction(shouldCancelConnection: Bool = true) -> OmiLaunchCaptureIngressAction {
        guard !self.didRequestConnectionStop else {
            return .fault(shouldCancelConnection: false)
        }
        self.didRequestConnectionStop = true
        return .fault(shouldCancelConnection: shouldCancelConnection)
    }
}
