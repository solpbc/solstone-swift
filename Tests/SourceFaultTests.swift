// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class SourceFaultTests: XCTestCase {
    func testActionTable() {
        XCTAssertEqual(sourceFaultAction(.bluetoothOff), .none)
        XCTAssertEqual(sourceFaultAction(.unauthorized), .openSettings)
        XCTAssertEqual(sourceFaultAction(.unsupported), .none)
        XCTAssertEqual(sourceFaultAction(.pendantOutOfRange), .none)
        XCTAssertEqual(sourceFaultAction(.pendantConnectFailed), .none)
        XCTAssertEqual(sourceFaultAction(.pendantCodecUnsupported), .none)
        XCTAssertEqual(sourceFaultAction(.pendantAudioUnavailable), .none)
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

    func testOutOfRangePendantNeverRetries() {
        XCTAssertEqual(omiSourceFault(.pendantNotFound), .pendantOutOfRange)
        XCTAssertEqual(sourceFaultAction(omiSourceFault(.pendantNotFound)), .none)
        XCTAssertNotEqual(sourceFaultAction(omiSourceFault(.pendantNotFound)), .retry)
    }

    func testNoOmiAttentionYieldsRetry() {
        let attentions: [OmiAttention] = [
            .bluetoothOff,
            .unauthorized,
            .unsupported,
            .pendantNotFound,
            .connectFailed("timeout"),
            .codecNotOpus,
            .audioUnavailable,
        ]
        for attention in attentions {
            XCTAssertNotEqual(sourceFaultAction(omiSourceFault(attention)), .retry, "\(attention)")
        }
    }

    func testBluetoothOffIsNoneUnauthorizedIsOpenSettings() {
        XCTAssertEqual(sourceFaultAction(omiSourceFault(.bluetoothOff)), .none)
        XCTAssertEqual(sourceFaultAction(omiSourceFault(.unauthorized)), .openSettings)
    }

    func testDisabledPendantHasNoFault() {
        XCTAssertNil(omiSourceFault(state: .needsAttention(.pendantNotFound), enabled: false))
        XCTAssertEqual(omiSourceFault(state: .needsAttention(.unauthorized), enabled: true), .unauthorized)
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
            .installedActive(.idle),
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
        XCTAssertEqual(sourceFaultAction(.pendantConnectFailed), .none)
        XCTAssertEqual(sourceFaultAction(.unsupported), .none)
    }
}

private extension SourceFaultTests {
    static var waiting: WatchWaitingBreakdown {
        WatchWaitingBreakdown(
            watch: WatchSideWaiting(count: 0, freshness: .unknown),
            phone: PhoneSideWaiting(count: 0),
            leading: nil
        )
    }
}
