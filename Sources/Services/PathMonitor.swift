// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network

public struct NetworkPathStatus: Equatable, Sendable {
    public let isSatisfied: Bool
    public let isWiFi: Bool
    public let isCellular: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool

    public nonisolated init(
        isSatisfied: Bool,
        isWiFi: Bool,
        isCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.isSatisfied = isSatisfied
        self.isWiFi = isWiFi
        self.isCellular = isCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

nonisolated func networkStatusText(_ status: NetworkPathStatus?) -> String {
    guard let status else { return "unknown" }
    let iface: String
    if status.isWiFi {
        iface = "wifi"
    } else if status.isCellular {
        iface = "cellular"
    } else {
        iface = "other"
    }
    if status.isSatisfied {
        return iface
    }
    if status.isWiFi {
        return "wifi · offline"
    }
    if status.isCellular {
        return "cellular · offline"
    }
    return "offline"
}

private extension NetworkPathStatus {
    nonisolated init(path: NWPath) {
        self.init(
            isSatisfied: path.status == .satisfied,
            isWiFi: path.usesInterfaceType(.wifi),
            isCellular: path.usesInterfaceType(.cellular),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

protocol PathMonitoringSource: AnyObject, Sendable {
    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void)
    func stop()
}

private final class NWPathMonitoringSource: PathMonitoringSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.solstone.swift.path-monitor")
    private var monitor: NWPathMonitor?

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            onPathChange(NetworkPathStatus(path: path))
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

    public func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        stop()
        source.start { [weak self] status in
            Task { @MainActor in
                self?.schedulePathChange(status, onPathChange)
            }
        }
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source.stop()
    }

    private func schedulePathChange(
        _ status: NetworkPathStatus,
        _ onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void
    ) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            onPathChange(status)
        }
    }
}
