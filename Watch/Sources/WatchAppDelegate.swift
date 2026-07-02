// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(WatchKit)
import Foundation
import WatchConnectivity
import WatchKit

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    weak var session: (any WatchConnectivitySession)?
    weak var backgroundTaskCoordinator: WatchBackgroundTaskCoordinator?

    func applicationDidFinishLaunching() {
        self.session?.activate()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let task as WKWatchConnectivityRefreshBackgroundTask:
                guard let backgroundTaskCoordinator else {
                    task.setTaskCompletedWithSnapshot(false)
                    continue
                }
                backgroundTaskCoordinator.handle(WatchConnectivityBackgroundRefreshTask(task: task))
            case let task as WKSnapshotRefreshBackgroundTask:
                task.setTaskCompleted(
                    restoredDefaultState: false,
                    estimatedSnapshotExpiration: .distantFuture,
                    userInfo: nil
                )
            default:
                // W2 only holds watch-connectivity refreshes; all other task types are acknowledged promptly.
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

private final class WatchConnectivityBackgroundRefreshTask: WatchBackgroundRefreshTask {
    let id: ObjectIdentifier
    private let task: WKWatchConnectivityRefreshBackgroundTask

    init(task: WKWatchConnectivityRefreshBackgroundTask) {
        self.task = task
        self.id = ObjectIdentifier(task)
    }

    func complete() {
        self.task.setTaskCompletedWithSnapshot(false)
    }
}
#endif
