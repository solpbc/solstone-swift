// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OmiSourceConnectionEdgeGrepTests: XCTestCase {
    func testAudioSuccessEdgesRecoverThroughHelperOnly() throws {
        let managerURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)

        XCTAssertTrue(text.contains("recoveredConnectionState"))

        let notificationBody = try Self.functionSlice(
            named: "handleUpdatedNotificationState",
            in: text
        )
        let audioBody = try Self.functionSlice(
            named: "handleAudioData",
            in: text
        )

        XCTAssertFalse(notificationBody.contains("connectionState = .connected"))
        XCTAssertFalse(audioBody.contains("connectionState = .connected"))
    }

    func testRestoreHandlerRoutesThroughCodecGatedAction() throws {
        let managerURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)
        let restoreBody = try Self.functionSlice(named: "handleRestoredPeripheral", in: text)
        let advanceBody = try Self.functionSlice(named: "advanceReadiness", in: text)

        XCTAssertTrue(restoreBody.contains("self.advanceReadiness(for: peripheral)"))
        XCTAssertTrue(advanceBody.contains("cacheRestoredCharacteristics"))
        XCTAssertTrue(advanceBody.contains("codec: self.codec"))
        XCTAssertTrue(advanceBody.contains("case .readCodec"))
    }

    func testWriterFaultEscalationIsWiredThroughDerivedState() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let appText = try String(
            contentsOf: root.appendingPathComponent("Sources/SolstoneSwiftApp.swift"),
            encoding: .utf8
        )
        let managerText = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiSourceManager.swift"),
            encoding: .utf8
        )
        let noteBody = try Self.functionSlice(named: "noteWriterFault", in: managerText)
        let audioBody = try Self.functionSlice(named: "handleAudioData", in: managerText)

        XCTAssertTrue(appText.contains("onWriterFault"))
        XCTAssertTrue(noteBody.contains("writerFaulted = true"))
        XCTAssertFalse(audioBody.contains("connectionState = .needsAttention(.audioUnavailable)"))
    }

    func testDisconnectRecordsReconnectStateBeforeStartingNonblockingFinalization() throws {
        let managerURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)
        let body = try Self.functionSlice(named: "handleDisconnected", in: text)

        let finalize = try XCTUnwrap(body.range(of: "self.omiSegmentWriter?.finalizeOpenChunkForDisconnect()"))
        let state = try XCTUnwrap(body.range(of: "self.connectionState = .reconnecting"))
        let beginConnect = try XCTUnwrap(body.range(of: "self.beginConnect("))
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: state.lowerBound),
            body.distance(from: body.startIndex, to: finalize.lowerBound)
        )
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: finalize.lowerBound),
            body.distance(from: body.startIndex, to: beginConnect.lowerBound)
        )
        XCTAssertFalse(body.contains("await self.omiSegmentWriter?.finalizeOpenChunk()"))
    }

    func testBackgroundFinalizesOmiBeforeDrainCoordinatorRuns() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)
        let backgroundStart = try XCTUnwrap(text.range(of: "case .background:"))
        let backgroundBody = text[backgroundStart.lowerBound...]

        let finalize = try XCTUnwrap(backgroundBody.range(of: "finalizeOpenChunkForBackground"))
        let coordinator = try XCTUnwrap(backgroundBody.range(of: "BackgroundDrainCoordinator("))
        let awaitFinalize = try XCTUnwrap(backgroundBody.range(of: "await omiFinalizeTask.value"))
        let runCoordinator = try XCTUnwrap(backgroundBody.range(of: "await coordinator.run()"))
        XCTAssertLessThan(
            backgroundBody.distance(from: backgroundBody.startIndex, to: finalize.lowerBound),
            backgroundBody.distance(from: backgroundBody.startIndex, to: coordinator.lowerBound)
        )
        XCTAssertLessThan(
            backgroundBody.distance(from: backgroundBody.startIndex, to: awaitFinalize.lowerBound),
            backgroundBody.distance(from: backgroundBody.startIndex, to: runCoordinator.lowerBound)
        )
    }

    func testOmiTransferConstructionAndMigrationUseCutoverPath() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)
        let transferEnqueuer = try XCTUnwrap(text.range(of: "let transferEnqueuer = ObserverAudioTransferEnqueuer"))
        let writer = try XCTUnwrap(text.range(of: "OmiSegmentWriter(transferEnqueuer: transferEnqueuer"))
        XCTAssertLessThan(
            text.distance(from: text.startIndex, to: transferEnqueuer.lowerBound),
            text.distance(from: text.startIndex, to: writer.lowerBound)
        )
        let migration = try XCTUnwrap(text.range(of: "OmiTransferSpoolMigrator.migrate"))
        let recovery = try XCTUnwrap(text.range(of: "recoverOmiInProgress"))
        XCTAssertLessThan(text.distance(from: text.startIndex, to: migration.lowerBound), text.distance(from: text.startIndex, to: recovery.lowerBound))
        XCTAssertFalse(text.contains("didMigrateObserverRootToAppGroupV1"))
    }

    func testPeripheralAndWriterEffectsAreGuardedByLaunchReadiness() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let managerURL = root
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)
        let portText = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiBluetoothPort.swift"),
            encoding: .utf8
        )
        let guardedEffects = [
            ("startSegmentWriterIfNeeded", "omiSegmentWriter?.start()"),
            ("beginConnect", "bluetoothPort.connect("),
            ("handleCentralStateUpdate", "self.beginConnect("),
            ("advanceReadiness", "bluetoothPort.discoverServices("),
            ("advanceReadiness", "bluetoothPort.readValue("),
            ("advanceReadiness", "bluetoothPort.discoverCharacteristics("),
            ("advanceReadiness", "self.buildOpusDecoder()"),
            ("handleConnected", "self.readRSSI()"),
            ("handleConnected", "self.bluetoothPort.discoverServices("),
            ("handleDisconnected", "finalizeOpenChunkForDisconnect()"),
            ("handleDisconnected", "self.beginConnect("),
            ("handleDiscoveredServices", "self.bluetoothPort.discoverCharacteristics("),
            ("handleDiscoveredCharacteristics", "self.bluetoothPort.readValue("),
            ("handleUpdatedNotificationState", "self.buildOpusDecoder()"),
            ("handleAudioData", "self.onDecodedSamples"),
            ("subscribeAudio", "self.setAudioNotify"),
            ("setAudioNotify", "self.bluetoothPort.setNotify("),
            ("readRSSI", "self.bluetoothPort.readRSSI("),
            ("refreshPendantReadings", "self.bluetoothPort.readValue("),
            ("refreshStorageBacklogReading", "self.bluetoothPort.readValue("),
            ("attemptAudioResubscribe", "self.setAudioNotify"),
            ("finalizeOpenChunkForBackground", "finalizeOpenChunk()")
        ]

        // `enable()` clears manual disconnect before starting the writer, so only its readiness ordering applies.
        let enableBody = try Self.functionSlice(named: "enable", in: text)
        let enableReadiness = try XCTUnwrap(enableBody.range(of: "isLaunchReady"))
        let enableWriterStart = try XCTUnwrap(enableBody.range(of: "omiSegmentWriter?.start()"))
        XCTAssertLessThan(
            enableBody.distance(from: enableBody.startIndex, to: enableReadiness.lowerBound),
            enableBody.distance(from: enableBody.startIndex, to: enableWriterStart.lowerBound),
            "enable performs writer start before launch readiness"
        )

        for (method, effect) in guardedEffects {
            let body = try Self.functionSlice(named: method, in: text)
            let readiness = try XCTUnwrap(body.range(of: "isLaunchReady"), "missing readiness gate in \(method)")
            let disabled = try XCTUnwrap(body.range(of: "isOmiWorkDisabled"), "missing disabled gate in \(method)")
            let call = try XCTUnwrap(body.range(of: effect), "missing effect in \(method)")
            XCTAssertLessThan(
                body.distance(from: body.startIndex, to: readiness.lowerBound),
                body.distance(from: body.startIndex, to: call.lowerBound),
                "\(method) performs \(effect) before launch readiness"
            )
            XCTAssertLessThan(
                body.distance(from: body.startIndex, to: disabled.lowerBound),
                body.distance(from: body.startIndex, to: call.lowerBound),
                "\(method) performs \(effect) before checking disabled intent"
            )
        }

        for directCoreBluetoothSelector in [
            "CBCentralManager(",
            "cancelPeripheralConnection(",
            "peripheral.discoverServices(",
            "peripheral.discoverCharacteristics(",
            "peripheral.readValue(for:",
            "peripheral.readRSSI()",
            "peripheral.setNotifyValue("
        ] {
            XCTAssertFalse(text.contains(directCoreBluetoothSelector), "manager core directly performs \(directCoreBluetoothSelector)")
        }

        let livePortSelectors = [
            ("start", "CBCentralManager("),
            ("register", "peripheral.delegate ="),
            ("retrieveConnectedPeripherals", "retrieveConnectedPeripherals(withServices:"),
            ("retrievePeripherals", "retrievePeripherals(withIdentifiers:"),
            ("connect", "central?.connect("),
            ("cancelConnection", "cancelPeripheralConnection("),
            ("discoverServices", "discoverServices("),
            ("discoverCharacteristics", "discoverCharacteristics("),
            ("readValue", "readValue(for:"),
            ("readRSSI", "readRSSI()"),
            ("setNotify", "setNotifyValue(")
        ]
        for (method, selector) in livePortSelectors {
            let body = try Self.livePortFunctionSlice(named: method, in: portText)
            XCTAssertTrue(body.contains(selector), "live port \(method) is missing \(selector)")
        }
    }

    private static func functionSlice(named name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(name)"))
        let remaining = text[start.upperBound...]
        if let end = remaining.range(of: "\n    func ") {
            return text[start.lowerBound..<end.lowerBound]
        }
        return text[start.lowerBound...]
    }

    private static func livePortFunctionSlice(named name: String, in text: String) throws -> Substring {
        let livePort = try XCTUnwrap(text.range(of: "final class LiveOmiBluetoothPort"))
        return try Self.functionSlice(named: name, in: String(text[livePort.lowerBound...]))
    }
}
