// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network

protocol PathMonitoringSource: AnyObject, Sendable {
    func start(onPathChange: @Sendable @escaping () -> Void)
    func stop()
}

private final class NWPathMonitoringSource: PathMonitoringSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.solstone.swift.path-monitor")
    private var monitor: NWPathMonitor?

    func start(onPathChange: @Sendable @escaping () -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            onPathChange()
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

@MainActor
public final class PathMonitor: Sendable {
    private let source: PathMonitoringSource
    private var debounceTask: Task<Void, Never>?

    public init() {
        self.source = NWPathMonitoringSource()
    }

    init(source: PathMonitoringSource) {
        self.source = source
    }

    public func start(onPathChange: @Sendable @escaping () -> Void) {
        stop()
        source.start { [weak self] in
            Task { @MainActor in
                self?.schedulePathChange(onPathChange)
            }
        }
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source.stop()
    }

    private func schedulePathChange(_ onPathChange: @Sendable @escaping () -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            onPathChange()
        }
    }
}
