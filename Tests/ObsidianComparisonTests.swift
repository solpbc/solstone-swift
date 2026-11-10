// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

final class ObsidianComparisonTests: XCTestCase {
    private func stamp(_ time: Int64) -> ObsidianStamp { ObsidianStamp(epochSeconds: time, timeZone: TimeZone(identifier: "America/Denver")!) }
    private func note(_ path: String, _ text: String, id: Int? = 1, time: Int64 = 1_700_000_100) -> ObsidianWalkedNote {
        ObsidianWalkedNote(relativePath: path, documentIdentifier: id, mtimeMs: time * 1000,
            size: Int64(text.utf8.count), content: .sendable(text: text, contentHash: ObsidianWire.sha256Hex(Data(text.utf8))))
    }
    private func scan(_ vault: ObsidianVaultState, _ notes: [ObsidianWalkedNote], at time: Int64) throws -> ObsidianVaultState {
        try ObsidianComparison.reduce(vault, snapshot: ObsidianWalkSnapshot(notes: notes,
            unavailableCount: 0, tooLargeCount: 0, duration: 0.01), observed: self.stamp(time))
    }
    private func empty() -> ObsidianVaultState { ObsidianVaultState(id: "vault", folderName: "Notes") }
    private func established() throws -> ObsidianVaultState {
        var vault = try self.scan(self.empty(), [self.note("A.md", "original")], at: 1_700_000_110)
        vault.pendingChanges = []
        vault.table["A.md"]?.lastImmutableWindowStart = self.stamp(1_700_000_100).window.startEpochSeconds
        return vault
    }

    func testEmptyBaselineIsNotRepeatedWhenFirstNewNoteAppears() throws {
        var vault = try self.scan(self.empty(), [], at: 1_700_000_100)
        XCTAssertTrue(vault.baselineCompleted)
        vault = try self.scan(vault, [self.note("new.md", "new")], at: 1_700_000_500)
        XCTAssertEqual(vault.unappliedIntakeOps.map(\.kind), [.seed, .keep])
        XCTAssertEqual(vault.unappliedIntakeOps.map(\.sequence), [1, 2])
    }

    func testRenameEditRenameKeepsStableIdentityAndOriginalPreviousPath() throws {
        var vault = try self.established()
        let logicalID = vault.table["A.md"]?.logicalID
        vault = try self.scan(vault, [self.note("B.md", "original")], at: 1_700_000_500)
        vault = try self.scan(vault, [self.note("B.md", "edited", time: 1_700_000_510)], at: 1_700_000_515)
        vault = try self.scan(vault, [self.note("C.md", "edited", time: 1_700_000_510)], at: 1_700_000_520)
        XCTAssertEqual(vault.table["C.md"]?.logicalID, logicalID)
        XCTAssertEqual(vault.pendingChanges.count, 1)
        XCTAssertEqual(vault.pendingChanges.first?.change, .renamed)
        XCTAssertEqual(vault.pendingChanges.first?.previousPath, "A.md")
        XCTAssertEqual(vault.pendingChanges.first?.path, "C.md")
        XCTAssertEqual(vault.pendingChanges.first?.text, "edited")
    }

    func testExistingEditThenRemovalEmitsRemovalButFirstSightThenRemovalDrops() throws {
        var vault = try self.established()
        vault = try self.scan(vault, [self.note("A.md", "edit", time: 1_700_000_500)], at: 1_700_000_505)
        vault = try self.scan(vault, [], at: 1_700_000_510)
        vault = try self.scan(vault, [], at: 1_700_000_515)
        XCTAssertEqual(vault.pendingChanges.map(\.change), [.removed])
        XCTAssertEqual(vault.pendingChanges.first?.changedAt, self.stamp(1_700_000_510))
        XCTAssertEqual(vault.pendingChanges.first?.observedAt, self.stamp(1_700_000_510))
        var fresh = try self.scan(self.empty(), [], at: 1_700_000_100)
        fresh = try self.scan(fresh, [self.note("new.md", "new", time: 1_700_000_500)], at: 1_700_000_505)
        fresh = try self.scan(fresh, [], at: 1_700_000_510)
        fresh = try self.scan(fresh, [], at: 1_700_000_515)
        XCTAssertTrue(fresh.pendingChanges.isEmpty)
    }

    func testOversizedMoveRetainsRepresentedPathUntilReadableAgain() throws {
        var vault = try self.established()
        let logicalID = vault.table["A.md"]?.logicalID
        let tooLarge = ObsidianWalkedNote(relativePath: "B.md", documentIdentifier: 1,
            mtimeMs: 1_700_000_500_000, size: 5_000_000, content: .tooLarge(bytes: 5_000_000))
        vault = try self.scan(vault, [tooLarge], at: 1_700_000_505)
        XCTAssertEqual(vault.table["B.md"]?.representedPath, "A.md")
        XCTAssertTrue(vault.pendingChanges.isEmpty)
        vault = try self.scan(vault, [self.note("B.md", "small again", time: 1_700_000_510)], at: 1_700_000_515)
        XCTAssertEqual(vault.pendingChanges.first?.change, .renamed)
        XCTAssertEqual(vault.pendingChanges.first?.previousPath, "A.md")
        XCTAssertEqual(vault.pendingChanges.first?.logicalKey, logicalID)
    }

    func testEscapedLineLimitDoesNotKeepOrCountOversizeAndOtherNoteProceeds() throws {
        let baseline = try self.scan(self.empty(), [], at: 1_700_000_100)
        let text = String(repeating: "\u{0}", count: ObsidianWire.maxNoteBytes)
        let result = try self.scan(baseline, [self.note("huge.md", text), self.note("fit.md", "fits", id: 2)], at: 1_700_000_500)
        XCTAssertEqual(result.pendingChanges.map(\.path), ["fit.md"])
        XCTAssertNil(result.table["huge.md"]?.representedPath)
        XCTAssertFalse(result.table["huge.md"]?.intakeKept ?? true)
        XCTAssertEqual(result.unappliedIntakeOps.filter { $0.kind == .keep }.count, 1)
        XCTAssertEqual(result.tooLargeCount, 1)
    }

    func testUnidentifiedUnavailableCandidateHoldsMissingConfirmation() throws {
        var vault = try self.established()
        let unavailable = ObsidianWalkedNote(relativePath: "maybe-moved.md", documentIdentifier: nil,
            mtimeMs: 0, size: 0, content: .unavailable)
        vault = try self.scan(vault, [unavailable], at: 1_700_000_500)
        vault = try self.scan(vault, [unavailable], at: 1_700_000_600)
        XCTAssertNotNil(vault.table["A.md"])
        XCTAssertNil(vault.table["A.md"]?.firstMissingStamp)
        XCTAssertFalse(vault.pendingChanges.contains { $0.change == .removed })
        vault = try self.scan(vault, [self.note("maybe-moved.md", "original", id: nil)], at: 1_700_000_610)
        XCTAssertNil(vault.table["A.md"])
        XCTAssertEqual(vault.pendingChanges.first?.change, .renamed)
        XCTAssertEqual(vault.pendingChanges.first?.previousPath, "A.md")
        XCTAssertFalse(vault.unappliedIntakeOps.contains { $0.kind == .keep })
    }

    func testDuplicateFilesystemObservationsRejectTheScanWithoutTrapping() throws {
        let vault = try self.established()
        let duplicate = ObsidianWalkedNote(relativePath: "A.md", documentIdentifier: nil,
            mtimeMs: 0, size: 0, content: .unavailable)
        XCTAssertThrowsError(try self.scan(vault, [self.note("A.md", "original"), duplicate], at: 1_700_000_500))
    }

    func testPlaceholderCannotEraseIdentityBeforeAnUnavailableMove() throws {
        var vault = try self.established()
        let logicalID = vault.table["A.md"]?.logicalID
        let placeholder = ObsidianWalkedNote(relativePath: "A.md", documentIdentifier: nil,
            mtimeMs: 0, size: 0, content: .unavailable)
        vault = try self.scan(vault, [placeholder], at: 1_700_000_500)
        XCTAssertEqual(vault.table["A.md"]?.documentIdentifier, 1)
        let moved = ObsidianWalkedNote(relativePath: "B.md", documentIdentifier: 1,
            mtimeMs: 1_700_000_510_000, size: 5_000_000, content: .tooLarge(bytes: 5_000_000))
        vault = try self.scan(vault, [moved], at: 1_700_000_515)
        vault = try self.scan(vault, [moved], at: 1_700_000_520)
        XCTAssertNil(vault.table["A.md"])
        XCTAssertEqual(vault.table["B.md"]?.representedPath, "A.md")
        XCTAssertEqual(vault.table["B.md"]?.logicalID, logicalID)
        XCTAssertTrue(vault.pendingChanges.isEmpty)
        vault = try self.scan(vault, [self.note("B.md", "readable", time: 1_700_000_525)], at: 1_700_000_530)
        XCTAssertEqual(vault.pendingChanges.first?.change, .renamed)
        XCTAssertEqual(vault.pendingChanges.first?.previousPath, "A.md")
        XCTAssertEqual(vault.pendingChanges.first?.logicalKey, logicalID)
        XCTAssertFalse(vault.unappliedIntakeOps.contains { $0.kind == .keep })
    }

    func testUnsentFirstSightIsDroppedAcrossWindows() throws {
        var vault = try self.scan(self.empty(), [], at: 1_700_000_100)
        vault = try self.scan(vault, [self.note("new.md", "new", time: 1_700_000_500)], at: 1_700_000_505)
        vault = try self.scan(vault, [self.note("new.md", "edit", time: 1_700_000_900)], at: 1_700_000_905)
        XCTAssertEqual(vault.pendingChanges.count, 2)
        vault = try self.scan(vault, [], at: 1_700_000_910)
        vault = try self.scan(vault, [], at: 1_700_000_915)
        XCTAssertTrue(vault.pendingChanges.isEmpty)
    }

    @MainActor
    func testCounterSequencePreventsRenameReplayFromRemovingReusedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let intake = SourceIntakeStore(directoryURL: root)
        let time = Date(timeIntervalSince1970: 1_700_000_100)
        let operations = [
            ObsidianUnappliedIntakeOp(hash: "", intakeTime: time, sequence: 1, kind: .seed, baselineHashes: ["A"]),
            ObsidianUnappliedIntakeOp(hash: "B", intakeTime: time, sequence: 2, kind: .move, previousHash: "A"),
            ObsidianUnappliedIntakeOp(hash: "A", intakeTime: time, sequence: 3, kind: .keep)
        ]
        for operation in operations { XCTAssertEqual(intake.applyObsidianOperation(vaultID: "vault", operation: operation), .recorded) }
        for operation in operations { XCTAssertEqual(intake.applyObsidianOperation(vaultID: "vault", operation: operation), .unchanged) }
        guard case .ready(let snapshot) = intake.load() else { return XCTFail("intake unavailable") }
        XCTAssertEqual(snapshot.obsidian.total, 1)
        XCTAssertEqual(snapshot.obsidian.last, time)
        XCTAssertEqual(intake.applyObsidianOperation(vaultID: "vault", operation: ObsidianUnappliedIntakeOp(hash: "missing", intakeTime: time, sequence: 5)), .failed)
    }
}
