// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network

@MainActor
public final class PathMonitor: Sendable {
    private let queue = DispatchQueue(label: "app.solstone.swift.path-monitor")
    private var monitor: NWPathMonitor?
    private var debounceTask: Task<Void, Never>?

    public init() {}

    public func start(onPathChange: @Sendable @escaping () -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.schedulePathChange(onPathChange)
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        monitor?.cancel()
        monitor = nil
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
