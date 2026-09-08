// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class SourceFaultTests: XCTestCase {
    func testActionTable() {
        XCTAssertEqual(sourceFaultAction(.watchUnsupported), .none)
        XCTAssertEqual(sourceFaultAction(.watchChecking), .none)
        XCTAssertEqual(sourceFaultAction(.watchActivationFailed), .none)
        XCTAssertEqual(sourceFaultAction(.watchNoWatchPaired), .none)
        XCTAssertEqual(sourceFaultAction(.watchReadyToInstall), .routeToInstallOrOpen)
        XCTAssertEqual(sourceFaultAction(.watchInstalledNeverOpened), .routeToInstallOrOpen)
        XCTAssertEqual(sourceFaultAction(.watchStuck), .none)
        XCTAssertEqual(sourceFaultAction(.locationRestricted), .none)
        XCTAssertEqual(sourceFaultAction(.locationDenied), .openSettings)
        XCTAssertEqual(sourceFaultAction(.locationServicesDisabled), .openSettings)
        XCTAssertEqual(sourceFaultAction(.locationNotDetermined), .openSettings)
        XCTAssertEqual(sourceFaultAction(.locationGrantBelowTier), .matchToAllowed)
        XCTAssertEqual(sourceFaultAction(.microphoneDenied), .openSettings)
        XCTAssertEqual(sourceFaultAction(.screencastNeedsAttention), .none)
        XCTAssertEqual(sourceFaultAction(.screencastUnavailable), .none)
    }

    func testWatchReachabilityLanesAreTheOnlyNonNoneActions() throws {
        let reachability: [PhoneWatchSourceLane] = [
            .readyToSetUp(.installApp),
            .installedNeverOpened,
        ]
        for lane in reachability {
            XCTAssertEqual(sourceFaultAction(try XCTUnwrap(watchSourceFault(lane))), .routeToInstallOrOpen, "\(lane)")
        }

        let noneLanes: [PhoneWatchSourceLane] = [
            .unsupported,
            .checking,
            .activationFailed,
            .noWatchPaired,
            .installedActive(.stuck(.handoff)),
            .installedActive(.stuck(.relay)),
            .installedActive(.stuck(.orphan)),
            .installedActive(.stuck(.none)),
            .installedActive(.stoppedItself(.audioStoppedItself)),
            .installedActive(.observing),
            .installedActive(.receiving),
            .installedActive(.waiting(Self.waiting)),
            .installedActive(.idle(.unknown)),
        ]
        for lane in noneLanes {
            if let fault = watchSourceFault(lane) {
                XCTAssertEqual(sourceFaultAction(fault), .none, "\(lane)")
            }
        }
    }

    func testWatchNotInstalledRoutesToInstallOrOpen() throws {
        XCTAssertEqual(
            sourceFaultAction(try XCTUnwrap(watchSourceFault(.readyToSetUp(.installApp)))),
            .routeToInstallOrOpen
        )
    }

    func testLocationNotDeterminedIsOpenSettingsNotMatchToAllowed() throws {
        let fault = locationSourceFault(effective: .notDetermined, tier: .balanced, paused: false)
        XCTAssertEqual(fault, .locationNotDetermined)
        XCTAssertEqual(sourceFaultAction(try XCTUnwrap(fault)), .openSettings)
        XCTAssertNotEqual(sourceFaultAction(try XCTUnwrap(fault)), .matchToAllowed)
    }

    func testLocationRestrictedIsNone() throws {
        XCTAssertEqual(
            sourceFaultAction(
                try XCTUnwrap(locationSourceFault(effective: .restricted, tier: .balanced, paused: false))
            ),
            .none
        )
    }

    func testLocationDeniedAndServicesDisabledOpenSettings() throws {
        XCTAssertEqual(
            sourceFaultAction(try XCTUnwrap(locationSourceFault(effective: .denied, tier: .balanced, paused: false))),
            .openSettings
        )
        XCTAssertEqual(
            sourceFaultAction(
                try XCTUnwrap(locationSourceFault(effective: .servicesDisabled, tier: .balanced, paused: false))
            ),
            .openSettings
        )
    }

    func testLocationGrantBelowTierIsMatchToAllowedOnly() throws {
        XCTAssertEqual(
            sourceFaultAction(
                try XCTUnwrap(locationSourceFault(effective: .whenInUse(accuracy: .full), tier: .balanced, paused: false))
            ),
            .matchToAllowed
        )
        XCTAssertEqual(
            sourceFaultAction(
                try XCTUnwrap(locationSourceFault(effective: .always(accuracy: .reduced), tier: .full, paused: false))
            ),
            .matchToAllowed
        )
    }

    func testLocationPausedAndSatisfiedHaveNoFault() {
        XCTAssertNil(locationSourceFault(effective: .denied, tier: .balanced, paused: true))
        XCTAssertNil(locationSourceFault(effective: .always(accuracy: .full), tier: .full, paused: false))
    }

    func testObserverPermissionDeniedOpensSettings() {
        XCTAssertEqual(observerSourceFault(.error(.permissionDenied)), .microphoneDenied)
        XCTAssertEqual(sourceFaultAction(.microphoneDenied), .openSettings)
        XCTAssertNil(observerSourceFault(.idle))
        XCTAssertNil(observerSourceFault(.error(.diskFull)))
    }

    func testScreencastAttentionIsNone() throws {
        XCTAssertEqual(
            sourceFaultAction(try XCTUnwrap(screencastSourceFault(.needsAttention(.noVideo)))),
            .none
        )
        XCTAssertNil(screencastSourceFault(.off))
    }

    func testUnderivableFaultsAreNone() {
        XCTAssertEqual(sourceFaultAction(.watchStuck), .none)
    }
}

private extension SourceFaultTests {
    static var waiting: WatchWaitingBreakdown {
        WatchWaitingBreakdown(
            watch: .unknown,
            phone: PhoneSideWaiting(count: 0),
            leading: nil
        )
    }
}
