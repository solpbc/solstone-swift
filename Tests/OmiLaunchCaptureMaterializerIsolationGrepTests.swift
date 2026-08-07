// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiLaunchCaptureMaterializerIsolationGrepTests: XCTestCase {
    func testMaterializerSourcesDoNotReferenceTransferOrCaptureAcknowledgement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Omi")
        let names = ["OmiLaunchCaptureMaterializer.swift", "OmiLaunchCaptureMaterializationIdentity.swift", "OmiLaunchCaptureMaterializationProvenance.swift", "OmiAACChunkWriter.swift"]
        for name in names {
            let text = try String(contentsOf: root.appendingPathComponent(name))
            for forbidden in ["enqueue", "acknowledge(", "retireIfEligible", "hold(", "releaseGate", "TransferEngine", "TransferSpool", "ObserverAudioTransferEnqueuer"] {
                XCTAssertFalse(text.contains(forbidden), "\(forbidden) in \(name)")
            }
        }
    }
}
