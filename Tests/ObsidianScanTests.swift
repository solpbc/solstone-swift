// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import XCTest
@testable import solstone_swift

@MainActor
final class ObsidianScanTests: XCTestCase {
    private var testDir: URL!
    private var intakeURL: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        self.testDir = URL(fileURLWithPath: "/var/tmp/obsidian_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.testDir, withIntermediateDirectories: true)
        self.intakeURL = self.testDir.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: self.intakeURL, withIntermediateDirectories: true)
        self.storeURL = self.testDir.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: self.storeURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = self.testDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func createTestVault(name: String) throws -> URL {
        let vaultURL = self.testDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let configURL = vaultURL.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        return vaultURL
    }

    // MARK: - 1. Location Validator Tests

    func testUnknownProviderCannotMasqueradeAsAnApplicationDocumentsPath() {
        XCTAssertFalse(ObsidianLocationValidator.isDocumentsClass(canonicalPath: "/unqualified/provider/Application/uuid/Documents/Vault"))
        XCTAssertFalse(ObsidianLocationValidator.isDocumentsClass(canonicalPath: "/var/mobile/Library/Application/uuid/Documents/Vault"))
        XCTAssertTrue(ObsidianLocationValidator.isDocumentsClass(canonicalPath: "/private/var/mobile/Containers/Data/Application/uuid/Documents/Vault"))
    }

    func testNativeLocalVaultMayOmitUbiquitousResourceButNeedsPositiveLocalEvidence() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/uuid/Documents/Notes")
        var resources = ObsidianLocationResources(isDirectory: true, isUbiquitousItem: nil,
            volumeIsLocal: true, canonicalPath: url.path, isSymbolicLink: false)
        XCTAssertTrue(ObsidianLocationValidator.validate(url: url, resources: resources).isSuccess)
        resources.volumeIsLocal = nil
        XCTAssertFalse(ObsidianLocationValidator.validate(url: url, resources: resources).isSuccess)
        resources.volumeIsLocal = true
        resources.canonicalPath = "/var/mobile/Library/File Provider Storage/Notes"
        XCTAssertFalse(ObsidianLocationValidator.validate(url: url, resources: resources).isSuccess)
        resources.canonicalPath = url.path
        resources.isUbiquitousItem = true
        XCTAssertFalse(ObsidianLocationValidator.validate(url: url, resources: resources).isSuccess)
    }

    func testCorruptStoreIsVisibleAndCannotBeOverwrittenBySelection() async throws {
        let corrupt = Data("broken private checkpoint".utf8)
        try corrupt.write(to: self.storeURL.appendingPathComponent("store.json"))
        let store = ObsidianStore(rootURL: self.storeURL)
        let engine = ObsidianSourceEngine(store: store)
        XCTAssertEqual(engine.status.tileState, .needsAttention)
        XCTAssertEqual(engine.status.attention, .privateStoreFault)
        let folder = try self.createTestVault(name: "CorruptStore")
        let result = await engine.chooseVault(url: folder)
        XCTAssertEqual(result.failureError, .invalidFolder(sentence: ObsidianVocabulary.PRIVATE_STORE_FAULT))
        XCTAssertEqual(try Data(contentsOf: self.storeURL.appendingPathComponent("store.json")), corrupt)
    }

    func testPauseAfterWindowPreparationKeepsMutablePendingChanges() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let engine = ObsidianSourceEngine(store: store)
        let vaultURL = try self.createTestVault(name: "PauseAtCommit")
        try "note".write(to: vaultURL.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let resources = ObsidianLocationResources(isDirectory: true, isUbiquitousItem: false,
            volumeIsLocal: true, canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/PauseAtCommit", isSymbolicLink: false)
        _ = await engine.chooseVault(url: vaultURL, resources: resources)
        await engine.turnOn()
        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let pending = try XCTUnwrap(store.selectedVault?.pendingChanges)
        let change = try XCTUnwrap(pending.first)
        let afterClose = Date(timeIntervalSince1970: TimeInterval(change.changedAt.closeEpochSeconds + 1))
        engine.clock = { afterClose }
        engine.testAfterPreparingCheckpoint = { engine.pause() }
        await engine.closeDueWindowsAndDeliver()
        XCTAssertTrue(store.document.paused)
        XCTAssertEqual(store.document.vaults[vaultID]?.pendingChanges, pending)
        XCTAssertTrue(store.document.vaults[vaultID]?.outboxItems.isEmpty ?? false)
        XCTAssertNil(store.document.vaults[vaultID]?.table["note.md"]?.lastImmutableWindowStart)
        let disk = ObsidianStore(rootURL: self.storeURL)
        XCTAssertTrue(disk.document.paused)
        XCTAssertEqual(disk.document.vaults[vaultID]?.pendingChanges, pending)
    }

    func testLocationValidatorDocumentsClassAcceptedWithArbitraryUUID() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/12345678-ABCD-EF01-2345-6789ABCDEF01/Documents/MyVault")
        let resources = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/private/var/mobile/Containers/Data/Application/12345678-ABCD-EF01-2345-6789ABCDEF01/Documents/MyVault",
            isSymbolicLink: false,
            isObsidianPresent: true,
            isObsidianDirectory: true,
            isObsidianSymbolicLink: false
        )
        let result = ObsidianLocationValidator.validate(url: url, resources: resources)
        XCTAssertTrue(result.isSuccess)
    }

    func testLocationValidatorRefusals() {
        let url = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/UUID/Documents/MyVault")

        // Non-ubiquitous third-party provider (File Provider Storage)
        let thirdPartyRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Library/File Provider Storage/MyVault",
            isSymbolicLink: false
        )
        let thirdPartyResult = ObsidianLocationValidator.validate(url: url, resources: thirdPartyRes)
        XCTAssertEqual(thirdPartyResult.failureError, .unsupportedLocation(sentence: ObsidianVocabulary.REFUSED_UNSUPPORTED_LOCATION_IPHONE))

        // Ubiquitous (iCloud)
        let ubiquitousRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: true,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/MyVault",
            isSymbolicLink: false
        )
        XCTAssertEqual(ObsidianLocationValidator.validate(url: url, resources: ubiquitousRes).failureError, .unsupportedLocation(sentence: ObsidianVocabulary.REFUSED_UNSUPPORTED_LOCATION_IPHONE))

        // Non-local volume
        let nonLocalRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: false,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/MyVault",
            isSymbolicLink: false
        )
        XCTAssertEqual(ObsidianLocationValidator.validate(url: url, resources: nonLocalRes).failureError, .unsupportedLocation(sentence: ObsidianVocabulary.REFUSED_UNSUPPORTED_LOCATION_IPHONE))

        // Nil canonicalPath (unclassifiable)
        let unclassifiableRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: nil,
            isSymbolicLink: false
        )
        XCTAssertEqual(ObsidianLocationValidator.validate(url: url, resources: unclassifiableRes).failureError, .unsupportedLocation(sentence: ObsidianVocabulary.REFUSED_UNSUPPORTED_LOCATION_IPHONE))

        // Symlink root
        let symlinkRootRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/MyVault",
            isSymbolicLink: true
        )
        XCTAssertEqual(ObsidianLocationValidator.validate(url: url, resources: symlinkRootRes).failureError, .invalidFolder(sentence: ObsidianVocabulary.REFUSED_INVALID_FOLDER))

        // Symlink .obsidian
        let symlinkConfigRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/MyVault",
            isSymbolicLink: false,
            isObsidianPresent: true,
            isObsidianDirectory: true,
            isObsidianSymbolicLink: true
        )
        XCTAssertEqual(ObsidianLocationValidator.validate(url: url, resources: symlinkConfigRes).failureError, .invalidFolder(sentence: ObsidianVocabulary.REFUSED_INVALID_FOLDER))

        // Missing .obsidian
        let missingConfigRes = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/MyVault",
            isSymbolicLink: false,
            isObsidianPresent: false,
            isObsidianDirectory: false,
            isObsidianSymbolicLink: false
        )
        XCTAssertEqual(ObsidianLocationValidator.validate(url: url, resources: missingConfigRes).failureError, .invalidFolder(sentence: ObsidianVocabulary.REFUSED_INVALID_FOLDER))
    }

    func testRefusalPreservesPreviousVault() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultAURL = try self.createTestVault(name: "VaultA")
        let resA = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/VaultA",
            isSymbolicLink: false
        )
        let outA = await engine.chooseVault(url: vaultAURL, resources: resA)
        XCTAssertTrue(outA.isSuccess)
        let selectedA = engine.status.selectedVaultID
        XCTAssertNotNil(selectedA)

        // Choose invalid vault B
        let vaultBURL = self.testDir.appendingPathComponent("VaultB", isDirectory: true)
        let resB = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: true, // iCloud -> refusal
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Library/Mobile Documents/VaultB",
            isSymbolicLink: false
        )
        let outB = await engine.chooseVault(url: vaultBURL, resources: resB)
        XCTAssertFalse(outB.isSuccess)
        // Selected vault is still VaultA
        XCTAssertEqual(engine.status.selectedVaultID, selectedA)
    }

    // MARK: - 2. Walk & Exclusion Tests

    func testWalkerExclusionsAndSymlinks() throws {
        let vaultURL = try self.createTestVault(name: "WalkerVault")

        // Regular note
        let note1 = vaultURL.appendingPathComponent("note1.md")
        try "# Note 1\nContent".write(to: note1, atomically: true, encoding: .utf8)

        // Nested note
        let sub = vaultURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let note2 = sub.appendingPathComponent("note2.md")
        try "# Note 2\nNested".write(to: note2, atomically: true, encoding: .utf8)

        // Dot file (.hidden.md)
        let hidden = vaultURL.appendingPathComponent(".hidden.md")
        try "hidden".write(to: hidden, atomically: true, encoding: .utf8)

        // Templates folders
        let templates = vaultURL.appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try "template".write(to: templates.appendingPathComponent("tmpl.md"), atomically: true, encoding: .utf8)

        let uTemplates = vaultURL.appendingPathComponent("_templates", isDirectory: true)
        try FileManager.default.createDirectory(at: uTemplates, withIntermediateDirectories: true)
        try "template".write(to: uTemplates.appendingPathComponent("tmpl.md"), atomically: true, encoding: .utf8)

        // Symlink note (should be excluded without error)
        let symlinkNote = vaultURL.appendingPathComponent("symlink.md")
        try? FileManager.default.createSymbolicLink(at: symlinkNote, withDestinationURL: note1)

        let snapshot = try ObsidianVaultWalker.walk(rootURL: vaultURL)
        let walkedPaths = Set(snapshot.notes.map(\.relativePath))

        XCTAssertTrue(walkedPaths.contains("note1.md"))
        XCTAssertTrue(walkedPaths.contains("nested/note2.md"))
        XCTAssertFalse(walkedPaths.contains(".hidden.md"))
        XCTAssertFalse(walkedPaths.contains("templates/tmpl.md"))
        XCTAssertFalse(walkedPaths.contains("_templates/tmpl.md"))
        XCTAssertFalse(walkedPaths.contains("symlink.md"))
    }

    // MARK: - 3. First Scan & Intake Seeding

    func testFirstScanSeedsIntakeAtZeroAndEmitsChangedNotes() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "SeedVault")
        let note1 = vaultURL.appendingPathComponent("note1.md")
        try "Hello World".write(to: note1, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/SeedVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        // Intake should be seeded at 0
        guard case .ready(let snap) = intake.load() else {
            XCTFail("intake not ready")
            return
        }
        XCTAssertEqual(snap.obsidian.total, 0)

        // Engine store should have recorded the note as a pending changed note
        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let vaultState = try XCTUnwrap(store.document.vaults[vaultID])
        XCTAssertEqual(vaultState.pendingChanges.count, 1)
        XCTAssertEqual(vaultState.pendingChanges.first?.change, .changed)
        XCTAssertEqual(vaultState.pendingChanges.first?.path, "note1.md")
        XCTAssertEqual(vaultState.frozenBaselineHashes.count, 1)
    }

    func testUnchangedMtimeAndSizeSkipFileRead() throws {
        let vaultURL = try self.createTestVault(name: "SkipVault")
        let noteURL = vaultURL.appendingPathComponent("file.md")
        try "Original Text".write(to: noteURL, atomically: true, encoding: .utf8)

        // First walk
        let snap1 = try ObsidianVaultWalker.walk(rootURL: vaultURL)
        XCTAssertEqual(snap1.notes.count, 1)
        let note = snap1.notes[0]
        guard case .sendable(let text, let hash) = note.content else {
            XCTFail("expected sendable note")
            return
        }

        // Prepare previousTable
        var lookup: [String: (mtimeMs: Int64, size: Int64, contentHash: String, text: String)] = [:]
        lookup[note.relativePath] = (note.mtimeMs, note.size, hash, text)

        // Second walk with identical file: content should be reused
        let snap2 = try ObsidianVaultWalker.walk(rootURL: vaultURL, previousTable: lookup)
        XCTAssertEqual(snap2.notes.count, 1)
        guard case .sendable(let text2, let hash2) = snap2.notes[0].content else {
            XCTFail("expected sendable note")
            return
        }
        XCTAssertEqual(hash2, hash)
        XCTAssertEqual(text2, text)
    }

    func testEqualHashIsNotAChange() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "HashEqualVault")
        let noteURL = vaultURL.appendingPathComponent("note.md")
        try "Content".write(to: noteURL, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/HashEqualVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let countAfterScan1 = store.document.vaults[vaultID]?.pendingChanges.count ?? 0

        // Touch the file: same content, touch changes mtime
        let later = Date(timeIntervalSinceNow: 10)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: noteURL.path)

        await engine.checkNow()
        let countAfterScan2 = store.document.vaults[vaultID]?.pendingChanges.count ?? 0
        XCTAssertEqual(countAfterScan1, countAfterScan2, "Touch without content change must not emit a pending change")
    }

    // MARK: - 4. Rename & Delayed Removal

    func testDelayedRemovalRequiresTwoScans() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "RemovalVault")
        let noteURL = vaultURL.appendingPathComponent("toBeRemoved.md")
        try "Bye bye".write(to: noteURL, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/RemovalVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        // Seal the baseline through the real packer before testing removal of
        // an existing note. A wholly mutable first sight is correctly dropped.
        let initial = try XCTUnwrap(store.document.vaults[vaultID]?.pendingChanges.first)
        let afterClose = Date(timeIntervalSince1970: TimeInterval(initial.changedAt.closeEpochSeconds + 1))
        engine.clock = { afterClose }
        await engine.closeDueWindowsAndDeliver()
        XCTAssertEqual(store.document.vaults[vaultID]?.outboxItems.count, 1)

        // Delete the file
        try FileManager.default.removeItem(at: noteURL)

        // First scan missing: recorded as firstObservedMissingAt, no removal emitted yet
        await engine.checkNow()
        XCTAssertEqual(store.document.vaults[vaultID]?.pendingChanges.count, 0)
        XCTAssertNotNil(store.document.vaults[vaultID]?.table["toBeRemoved.md"]?.firstObservedMissingAt)

        // Second scan missing: removal emitted
        await engine.checkNow()
        let changes = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.change, .removed)
        XCTAssertEqual(changes.first?.path, "toBeRemoved.md")
    }

    func testRenameViaDocumentIdentifierOrContentHash() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "RenameVault")
        let oldURL = vaultURL.appendingPathComponent("old.md")
        try "Renamed Content".write(to: oldURL, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/RenameVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        store.document.vaults[vaultID]?.pendingChanges.removeAll()

        // Move the file
        let newURL = vaultURL.appendingPathComponent("new.md")
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        await engine.checkNow()
        let changes = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes.count, 1)
        let rename = try XCTUnwrap(changes.first)
        XCTAssertEqual(rename.change, .renamed)
        XCTAssertEqual(rename.path, "new.md")
        XCTAssertEqual(rename.previousPath, "old.md")
    }

    // MARK: - 5. Coalescing in 5-Minute Windows

    func testSameWindowCoalescing() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "CoalesceVault")
        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/CoalesceVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)

        // Multiple saves of note.md in same window replace text
        let noteURL = vaultURL.appendingPathComponent("note.md")
        try "First Text".write(to: noteURL, atomically: true, encoding: .utf8)
        await engine.checkNow()

        try "Second Text".write(to: noteURL, atomically: true, encoding: .utf8)
        await engine.checkNow()

        let logicalID = try XCTUnwrap(store.document.vaults[vaultID]?.table["note.md"]?.logicalID)
        let changes = store.document.vaults[vaultID]?.pendingChanges.filter { $0.logicalKey == logicalID } ?? []
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.text, "Second Text")
    }

    func testWindowAEditPreservedWhenWindowBRenameOccurs() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "WindowVault")
        let noteURL = vaultURL.appendingPathComponent("note.md")
        try "Window A Text".write(to: noteURL, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/WindowVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let initialChanges = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(initialChanges.count, 1)
        let changeA = initialChanges[0]
        XCTAssertEqual(changeA.path, "note.md")

        // Advance clock to Window B (+400 seconds)
        engine.clock = { Date(timeIntervalSince1970: 1794156000 + 400) }

        // Rename in window B
        let renamedURL = vaultURL.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: noteURL, to: renamedURL)

        await engine.checkNow()

        let changes = store.document.vaults[vaultID]?.pendingChanges ?? []
        // Edit from window A must still be preserved, and rename from window B added
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].path, "note.md")
        XCTAssertEqual(changes[1].path, "renamed.md")
        XCTAssertEqual(changes[1].previousPath, "note.md")
    }

    // MARK: - 6. Failure & Error Safety

    func testCancellationLeavesStateUnmodified() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "CancelVault")
        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/CancelVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let genBefore = store.document.generation

        // Cancelled background refresh should return false and leave generation
        let task = Task {
            await engine.backgroundRefresh()
        }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(store.document.generation, genBefore)
    }

    // MARK: - 7. Acceptance Cases

    func testFutureAndBackwardMtime() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "TimeVault")
        let noteURL = vaultURL.appendingPathComponent("timeNote.md")
        try "Content 1".write(to: noteURL, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/TimeVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        store.document.vaults[vaultID]?.pendingChanges.removeAll()

        // 1. Future mtime (> now): must use observation time
        let futureDate = Date(timeIntervalSinceNow: 3600)
        try "Content 2".write(to: noteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: noteURL.path)

        let obsDate1 = Date(timeIntervalSince1970: 1_700_000_100)
        engine.clock = { obsDate1 }
        await engine.checkNow()

        let changes1 = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes1.count, 1)
        XCTAssertEqual(changes1.first?.changedAt.epochSeconds, Int64(obsDate1.timeIntervalSince1970))

        // 2. Backward mtime (<= lastReportedTime): must use observation time
        let pastDate = Date(timeIntervalSince1970: 1_000_000_000)
        try "Content 3".write(to: noteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: noteURL.path)

        let obsDate2 = Date(timeIntervalSince1970: 1_700_000_200)
        engine.clock = { obsDate2 }
        await engine.checkNow()

        let changes2 = store.document.vaults[vaultID]?.pendingChanges ?? []
        let lastChange = changes2.last
        XCTAssertEqual(lastChange?.changedAt.epochSeconds, Int64(obsDate2.timeIntervalSince1970))
    }

    private func ready(_ store: SourceIntakeStore) throws -> SourceIntakeSnapshot {
        guard case .ready(let snapshot) = store.load() else {
            XCTFail("Intake store not ready")
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }

    func testNoteOversizeMoveByDocIDThenShrinks() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)
        engine.documentIdentifierProvider = { url in
            if url.lastPathComponent == "note.md" || url.lastPathComponent == "moved.md" {
                return 1001
            }
            return nil
        }

        let vaultURL = try self.createTestVault(name: "SizeVault")
        let noteURL = vaultURL.appendingPathComponent("note.md")
        try "Normal note".write(to: noteURL, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/SizeVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let intakeAfterBaseline = try self.ready(intake).obsidian.total

        // Note grows past limit (> 4 MiB)
        let largeData = Data(repeating: 0x41, count: ObsidianWire.maxNoteFileSizeBytes + 1024)
        try largeData.write(to: noteURL)

        await engine.checkNow()
        XCTAssertEqual(store.document.vaults[vaultID]?.tooLargeCount, 1)
        // No removal emitted
        let removals1 = store.document.vaults[vaultID]?.pendingChanges.filter { $0.change == .removed } ?? []
        XCTAssertTrue(removals1.isEmpty)

        // Move note by documentIdentifier while too large
        let movedURL = vaultURL.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: noteURL, to: movedURL)

        await engine.checkNow()
        let removals2 = store.document.vaults[vaultID]?.pendingChanges.filter { $0.change == .removed } ?? []
        XCTAssertTrue(removals2.isEmpty)

        // Shrink back <= 4 MiB
        try "Shrunk back".write(to: movedURL, atomically: true, encoding: .utf8)
        await engine.checkNow()

        let removals3 = store.document.vaults[vaultID]?.pendingChanges.filter { $0.change == .removed } ?? []
        XCTAssertTrue(removals3.isEmpty)

        // No new intake count
        let intakeFinal = try self.ready(intake).obsidian.total
        XCTAssertEqual(intakeFinal, intakeAfterBaseline)
    }

    func testDeleteThenCreatePairsByHash() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "DeleteCreateVault")
        let fileA = vaultURL.appendingPathComponent("fileA.md")
        try "Identical content for hash pairing".write(to: fileA, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/DeleteCreateVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        store.document.vaults[vaultID]?.pendingChanges.removeAll()

        // Delete file A and create file B with identical content
        try FileManager.default.removeItem(at: fileA)
        let fileB = vaultURL.appendingPathComponent("fileB.md")
        try "Identical content for hash pairing".write(to: fileB, atomically: true, encoding: .utf8)

        await engine.checkNow()

        let changes = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes.count, 1)
        let rename = try XCTUnwrap(changes.first)
        XCTAssertEqual(rename.change, .renamed)
        XCTAssertEqual(rename.path, "fileB.md")
        XCTAssertEqual(rename.previousPath, "fileA.md")
    }

    func testDuplicateContentMatchedOneToOne() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "DupContentVault")
        let a1 = vaultURL.appendingPathComponent("a1.md")
        let a2 = vaultURL.appendingPathComponent("a2.md")
        try "Duplicate Content".write(to: a1, atomically: true, encoding: .utf8)
        try "Duplicate Content".write(to: a2, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/DupContentVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        store.document.vaults[vaultID]?.pendingChanges.removeAll()

        // Delete both a1 and a2, create b1 and b2
        try FileManager.default.removeItem(at: a1)
        try FileManager.default.removeItem(at: a2)
        let b1 = vaultURL.appendingPathComponent("b1.md")
        let b2 = vaultURL.appendingPathComponent("b2.md")
        try "Duplicate Content".write(to: b1, atomically: true, encoding: .utf8)
        try "Duplicate Content".write(to: b2, atomically: true, encoding: .utf8)

        await engine.checkNow()

        let changes = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes.count, 2)
        for change in changes {
            XCTAssertEqual(change.change, .renamed)
        }
        let oldPaths = Set(changes.compactMap(\.previousPath))
        let newPaths = Set(changes.map(\.path))
        XCTAssertEqual(oldPaths, ["a1.md", "a2.md"])
        XCTAssertEqual(newPaths, ["b1.md", "b2.md"])
    }

    func testContentIdenticalRenameAnchor() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        engine.clock = { baseDate }

        let vaultURL = try self.createTestVault(name: "AnchorVault")
        let noteA = vaultURL.appendingPathComponent("noteA.md")
        let noteB = vaultURL.appendingPathComponent("noteB.md")
        try "Content A".write(to: noteA, atomically: true, encoding: .utf8)
        try "Content B".write(to: noteB, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/AnchorVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        store.document.vaults[vaultID]?.pendingChanges.removeAll()

        // Edit Note A with a distinct mtime newer than lastChecked
        let editMtime = Date(timeIntervalSince1970: 1_700_000_050)
        try "Edited Content A".write(to: noteA, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: editMtime], ofItemAtPath: noteA.path)

        // Rename Note B (content-identical)
        let noteBRenamed = vaultURL.appendingPathComponent("noteB_renamed.md")
        try FileManager.default.moveItem(at: noteB, to: noteBRenamed)

        let obsDate = Date(timeIntervalSince1970: 1_700_000_100)
        engine.clock = { obsDate }
        await engine.checkNow()

        let changes = store.document.vaults[vaultID]?.pendingChanges ?? []
        let renameB = try XCTUnwrap(changes.first(where: { $0.path == "noteB_renamed.md" }))
        // Content-identical rename anchors to Note A's mtime (1_700_000_050), not obsDate
        XCTAssertEqual(renameB.changedAt.epochSeconds, Int64(editMtime.timeIntervalSince1970))
    }

    func testLaterChangeAfterClosedWindowUsesNewWindow() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "WindowShiftVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Initial".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/WindowShiftVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        store.document.vaults[vaultID]?.pendingChanges.removeAll()

        // Edit in Window 1 (epoch 1_700_000_000)
        let time1 = Date(timeIntervalSince1970: 1_700_000_000)
        engine.clock = { time1 }
        try "Edit 1".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: time1], ofItemAtPath: note.path)
        await engine.checkNow()

        let changes1 = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes1.count, 1)
        let window1Key = changes1[0].windowKey

        // Advance past window close (+400 seconds)
        let time2 = Date(timeIntervalSince1970: 1_700_000_400)
        engine.clock = { time2 }
        await engine.closeDueWindowsAndDeliver()

        // Pending changes from window 1 are packed to outbox
        let pendingAfterClose = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertTrue(pendingAfterClose.isEmpty)
        XCTAssertEqual(store.document.vaults[vaultID]?.outboxItems.count, 1)

        // Edit 2 in Window 2
        try "Edit 2".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: time2], ofItemAtPath: note.path)
        await engine.checkNow()

        let changes2 = store.document.vaults[vaultID]?.pendingChanges ?? []
        XCTAssertEqual(changes2.count, 1)
        XCTAssertNotEqual(changes2[0].windowKey, window1Key)
    }

    func testIncompleteEnumerationAndFailedPrivateWrite() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "ErrorFaultVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Original".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/ErrorFaultVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let lastCheckedBefore = store.document.vaults[vaultID]?.lastChecked

        // Simulate failed private write
        store.testFailNextSave = true
        try "Modified".write(to: note, atomically: true, encoding: .utf8)

        await engine.checkNow()

        // Prior rows kept, lastChecked not advanced
        XCTAssertEqual(store.document.vaults[vaultID]?.lastChecked, lastCheckedBefore)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Original")
    }

    func testFinishedScanAfterOffOrReselectionDoesNotPublish() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "OffReselectVault")
        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/OffReselectVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        // Turn off increments generation
        let genBefore = store.document.generation
        await engine.turnOff()
        XCTAssertGreaterThan(store.document.generation, genBefore)

        // Reselect vault also increments generation
        let genBeforeReselect = store.document.generation
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        XCTAssertGreaterThan(store.document.generation, genBeforeReselect)
    }

    func testRelaunchReplaysPendingAndAdoption() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "RelaunchVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Persistent Content".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/RelaunchVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let pendingCount = store.document.vaults[vaultID]?.pendingChanges.count ?? 0
        XCTAssertGreaterThan(pendingCount, 0)

        // Relaunch by creating a new store instance from same directory
        let reloadedStore = ObsidianStore(rootURL: self.storeURL)
        let reloadedPending = reloadedStore.document.vaults[vaultID]?.pendingChanges.count ?? 0
        XCTAssertEqual(reloadedPending, pendingCount)
    }

    func testInterruptedBaselineAndIntakeCounting() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "IntakeVault")
        let note1 = vaultURL.appendingPathComponent("note1.md")
        try "Note 1".write(to: note1, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/IntakeVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        // Baseline seeds at zero
        let snap1 = try self.ready(intake)
        XCTAssertEqual(snap1.obsidian.total, 0)

        // New note increments intake once
        let note2 = vaultURL.appendingPathComponent("note2.md")
        try "Note 2".write(to: note2, atomically: true, encoding: .utf8)
        await engine.checkNow()

        let snap2 = try self.ready(intake)
        XCTAssertEqual(snap2.obsidian.total, 1)

        // Edit does not increment intake
        try "Note 2 edited".write(to: note2, atomically: true, encoding: .utf8)
        await engine.checkNow()
        let snap3 = try self.ready(intake)
        XCTAssertEqual(snap3.obsidian.total, 1)

        // Rename does not increment intake
        let note2Renamed = vaultURL.appendingPathComponent("note2_renamed.md")
        try FileManager.default.moveItem(at: note2, to: note2Renamed)
        await engine.checkNow()
        let snap4 = try self.ready(intake)
        XCTAssertEqual(snap4.obsidian.total, 1)

        // Paused new note still counts intake
        engine.pause()
        let note3 = vaultURL.appendingPathComponent("note3.md")
        try "Note 3".write(to: note3, atomically: true, encoding: .utf8)
        await engine.checkNow()
        let snap5 = try self.ready(intake)
        XCTAssertEqual(snap5.obsidian.total, 2)
    }

    // MARK: - Filesystem Fixture Tests

    func testVaultRootOrObsidianUnreadableKeepsPriorRowsLastCheckedUnchanged() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "UnreadableVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Original Note".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/UnreadableVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let lastChecked1 = try XCTUnwrap(store.document.vaults[vaultID]?.lastChecked)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Original Note")

        // 1. Chmod vault root unreadable
        chmod(vaultURL.path, 0000)
        do {
            defer { chmod(vaultURL.path, 0755) }
            await engine.checkNow()
            XCTAssertEqual(store.document.vaults[vaultID]?.lastChecked, lastChecked1)
            XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Original Note")
            XCTAssertNil(store.document.vaults[vaultID]?.table["note.md"]?.firstObservedMissingAt)
            XCTAssertFalse((store.document.vaults[vaultID]?.pendingChanges ?? []).contains { $0.change == .removed })
        }

        // 2. Chmod .obsidian unreadable
        let obsDir = vaultURL.appendingPathComponent(".obsidian")
        chmod(obsDir.path, 0000)
        do {
            defer { chmod(obsDir.path, 0755) }
            await engine.checkNow()
            XCTAssertEqual(store.document.vaults[vaultID]?.lastChecked, lastChecked1)
            XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Original Note")
            XCTAssertNil(store.document.vaults[vaultID]?.table["note.md"]?.firstObservedMissingAt)
            XCTAssertFalse((store.document.vaults[vaultID]?.pendingChanges ?? []).contains { $0.change == .removed })
        }
    }

    func testUnreadableNoteKeepsLastRowAndPendingStateNotDelete() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "UnreadableNoteVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Original Note Content".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/UnreadableNoteVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Original Note Content")
        let pendingBefore = store.document.vaults[vaultID]?.pendingChanges.count ?? 0

        // Make note unreadable
        chmod(note.path, 0000)
        defer { chmod(note.path, 0644) }

        await engine.checkNow()

        // Keeps last row and pending state; not a delete
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Original Note Content")
        XCTAssertEqual(store.document.vaults[vaultID]?.pendingChanges.count, pendingBefore)
        XCTAssertNil(store.document.vaults[vaultID]?.table["note.md"]?.firstObservedMissingAt)
        XCTAssertFalse((store.document.vaults[vaultID]?.pendingChanges ?? []).contains { $0.change == .removed })
    }

    func testICloudPlaceholderMarksUnavailableNotRemoval() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "ICloudPlaceholderVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Known Note Content".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/ICloudPlaceholderVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Known Note Content")

        // Replace note with .note.md.icloud placeholder
        try FileManager.default.removeItem(at: note)
        let placeholder = vaultURL.appendingPathComponent(".note.md.icloud")
        try "placeholder".write(to: placeholder, atomically: true, encoding: .utf8)

        await engine.checkNow()

        // Unavailable count incremented, table keeps prior row, not added to delayed removals
        XCTAssertEqual(store.document.vaults[vaultID]?.unavailableCount, 1)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Known Note Content")
        XCTAssertNil(store.document.vaults[vaultID]?.table["note.md"]?.firstObservedMissingAt)
        XCTAssertFalse((store.document.vaults[vaultID]?.pendingChanges ?? []).contains { $0.change == .removed })
    }

    func testEnumerationFailureDoesNotFinalizeMissingPathNorAdvanceLastChecked() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "SubdirFailureVault")
        let subdir = vaultURL.appendingPathComponent("subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let subnote = subdir.appendingPathComponent("subnote.md")
        try "Subnote Content".write(to: subnote, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/SubdirFailureVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let lastChecked1 = try XCTUnwrap(store.document.vaults[vaultID]?.lastChecked)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["subfolder/subnote.md"]?.text, "Subnote Content")

        // Make subdirectory unreadable so contentsOfDirectory throws
        chmod(subdir.path, 0000)
        defer { chmod(subdir.path, 0755) }

        await engine.checkNow()

        // Does not finalize missing path, does not advance lastChecked
        XCTAssertEqual(store.document.vaults[vaultID]?.lastChecked, lastChecked1)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["subfolder/subnote.md"]?.text, "Subnote Content")
        XCTAssertNil(store.document.vaults[vaultID]?.table["subfolder/subnote.md"]?.firstObservedMissingAt)
        XCTAssertFalse((store.document.vaults[vaultID]?.pendingChanges ?? []).contains { $0.change == .removed })
    }

    func testTurnOffInTestHookDoesNotPublishAndCancellationDoesNotRaiseIncompleteScan() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "TestHookVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Initial Note".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/TestHookVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Initial Note")

        // Edit note, but install hook that turns off engine before generation check
        try "Late Note Content".write(to: note, atomically: true, encoding: .utf8)
        engine.testAfterWalkBeforeGenerationCheck = {
            engine.turnOff()
        }

        await engine.checkNow()

        // Generation changed, finished walk did not publish to store table
        XCTAssertEqual(store.document.vaults[vaultID]?.table["note.md"]?.text, "Initial Note")
        XCTAssertFalse(engine.incompleteScanOccurred)

        // Cancellation alone does not raise incompleteScanOccurred
        let task = Task {
            await engine.checkNow()
        }
        task.cancel()
        _ = await task.value
        XCTAssertFalse(engine.incompleteScanOccurred)
    }

    func testOutboxWriteFailureKeepsPendingWindow() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "OutboxFailVault")
        let note = vaultURL.appendingPathComponent("note.md")
        try "Outbox Note".write(to: note, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/OutboxFailVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let time1 = Date(timeIntervalSince1970: 1_700_000_000)
        engine.clock = { time1 }

        try "Outbox Note Changed".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: time1], ofItemAtPath: note.path)
        await engine.checkNow()

        let pendingChangesCount = store.document.vaults[vaultID]?.pendingChanges.count ?? 0
        XCTAssertGreaterThan(pendingChangesCount, 0)

        // Make outbox directory unwriteable
        chmod(store.outboxDirectoryURL.path, 0000)
        do {
            defer { chmod(store.outboxDirectoryURL.path, 0755) }
            // Advance clock past window close
            let time2 = Date(timeIntervalSince1970: 1_700_000_400)
            engine.clock = { time2 }
            await engine.closeDueWindowsAndDeliver()

            // Pending window kept because outbox write failed
            XCTAssertEqual(store.document.vaults[vaultID]?.pendingChanges.count, pendingChangesCount)
            XCTAssertEqual(store.document.vaults[vaultID]?.outboxItems.count, 0)
        }

        // Reloading ObsidianStore still has the pending rows from the committed scan
        let reloadedStore = ObsidianStore(rootURL: self.storeURL)
        XCTAssertEqual(reloadedStore.document.vaults[vaultID]?.pendingChanges.count, pendingChangesCount)
    }

    func testFailedIntakeWriteAfterNoteCommittedReplaysAtOriginalTime() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "IntakeFailVault")
        let note1 = vaultURL.appendingPathComponent("note1.md")
        try "Baseline Note".write(to: note1, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/IntakeFailVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        await engine.turnOn()

        let vaultID = try XCTUnwrap(store.document.selectedVaultID)
        let snap1 = try self.ready(intake)
        XCTAssertEqual(snap1.obsidian.total, 0)

        // Make intake directory unwriteable
        chmod(self.intakeURL.path, 0000)
        let originalIntakeTime = Date(timeIntervalSince1970: 1_700_000_123)
        engine.clock = { originalIntakeTime }

        let note2 = vaultURL.appendingPathComponent("note2.md")
        try "New Note".write(to: note2, atomically: true, encoding: .utf8)
        await engine.checkNow()

        // Note committed in store, but intake write failed -> unappliedIntakeOps retains it
        XCTAssertNotNil(store.document.vaults[vaultID]?.table["note2.md"])
        let unapplied = store.document.vaults[vaultID]?.unappliedIntakeOps ?? []
        XCTAssertEqual(unapplied.count, 1)
        XCTAssertEqual(unapplied.first?.intakeTime, originalIntakeTime)

        // Edits do not count again. Renames append an ordered seen-key move,
        // which replays after the original keep without adding to the total.
        try "New Note Edited".write(to: note2, atomically: true, encoding: .utf8)
        await engine.checkNow()
        XCTAssertEqual(store.document.vaults[vaultID]?.unappliedIntakeOps.count, 1)

        let note2Renamed = vaultURL.appendingPathComponent("note2_renamed.md")
        try FileManager.default.moveItem(at: note2, to: note2Renamed)
        await engine.checkNow()
        XCTAssertEqual(store.document.vaults[vaultID]?.unappliedIntakeOps.map(\.kind), [.keep, .move])

        try FileManager.default.removeItem(at: note2Renamed)
        await engine.checkNow()
        XCTAssertEqual(store.document.vaults[vaultID]?.unappliedIntakeOps.map(\.kind), [.keep, .move])

        // Restore intake directory permissions
        chmod(self.intakeURL.path, 0755)

        // Relaunch at a later time
        let replayTime = Date(timeIntervalSince1970: 1_700_010_000)
        let store2 = ObsidianStore(rootURL: self.storeURL)
        let intake2 = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine2 = ObsidianSourceEngine(store: store2, intakeStore: intake2)
        engine2.clock = { replayTime }

        // Counts once at original time
        let snap2 = try self.ready(intake2)
        XCTAssertEqual(snap2.obsidian.total, 1)
        XCTAssertEqual(store2.document.vaults[vaultID]?.unappliedIntakeOps.count, 0)
    }

    func testRePickWithInjectedDocumentIdentifierRestoresSameVaultID() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)

        let vaultURL = try self.createTestVault(name: "DocIDVault")
        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/DocIDVault",
            isSymbolicLink: false
        )

        // 1. Initial pick with injected doc ID 4242
        final class IDBox: @unchecked Sendable {
            var id: Int? = 4242
        }
        let idBox = IDBox()
        engine.documentIdentifierProvider = { _ in idBox.id }
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        let initialVaultID = try XCTUnwrap(store.document.selectedVaultID)
        XCTAssertEqual(store.document.vaults[initialVaultID]?.rootDocumentIdentifier, 4242)

        // 2. Re-pick with same identifier restores initialVaultID
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        let rePickVaultID = try XCTUnwrap(store.document.selectedVaultID)
        XCTAssertEqual(rePickVaultID, initialVaultID)

        // 3. Pick with different doc ID (even with same folder name) does NOT restore initialVaultID
        idBox.id = 8888
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        let differentDocVaultID = try XCTUnwrap(store.document.selectedVaultID)
        XCTAssertNotEqual(differentDocVaultID, initialVaultID)
        XCTAssertEqual(store.document.vaults[differentDocVaultID]?.rootDocumentIdentifier, 8888)
    }

    // MARK: - Progress Line: Delivered & Found Counts

    func testObsidianProgressDeliveredAndFoundCounts() async throws {
        let store = ObsidianStore(rootURL: self.storeURL)
        let intake = SourceIntakeStore(directoryURL: self.intakeURL)
        let engine = ObsidianSourceEngine(store: store, intakeStore: intake)
        engine.journalIdentityProvider = { "journal-test" }

        let vaultURL = try self.createTestVault(name: "ProgressVault")
        let note1 = vaultURL.appendingPathComponent("note1.md")
        let note2 = vaultURL.appendingPathComponent("note2.md")
        let note3 = vaultURL.appendingPathComponent("note3.md")
        try "Note 1 text".write(to: note1, atomically: true, encoding: .utf8)
        try "Note 2 text".write(to: note2, atomically: true, encoding: .utf8)
        try "Note 3 text".write(to: note3, atomically: true, encoding: .utf8)

        let res = ObsidianLocationResources(
            isDirectory: true,
            isUbiquitousItem: false,
            volumeIsLocal: true,
            canonicalPath: "/var/mobile/Containers/Data/Application/UUID/Documents/ProgressVault",
            isSymbolicLink: false
        )
        _ = await engine.chooseVault(url: vaultURL, resources: res)
        let vaultID = try XCTUnwrap(store.document.selectedVaultID)

        // 1. Initial scan commits: found is the committed population (3), delivered is 0 (no acknowledgement)
        await engine.turnOn()
        XCTAssertEqual(engine.status.totalFoundNotes, 3)
        XCTAssertEqual(engine.status.deliveredNotesCount, 0)

        // 2. One multi-note file acknowledged (containing note1 and note2) while note3 is still queued
        let hash1 = try XCTUnwrap(store.document.vaults[vaultID]?.table["note1.md"]?.logicalID)
        let hash2 = try XCTUnwrap(store.document.vaults[vaultID]?.table["note2.md"]?.logicalID)
        let hash3 = try XCTUnwrap(store.document.vaults[vaultID]?.table["note3.md"]?.logicalID)

        let outboxItem1 = ObsidianOutboxItem(
            itemID: UUID(),
            filename: "file1.jsonl",
            window: ObsidianWindow(day: "20261108", segment: "094000_300"),
            createdAt: Date(),
            lineCount: 2,
            byteCount: 100,
            sha256Hex: "hash1",
            timeZoneIdentifier: "America/Denver",
            offsetSeconds: -25200,
            vaultID: vaultID,
            folderName: "ProgressVault",
            noteIdentityHashes: [hash1, hash2]
        )
        let manifest1 = ObsidianTransfer.manifest(for: outboxItem1)

        // A failed acknowledgement save publishes nothing and preserves replayable state.
        let beforeAcknowledgement = store.document
        store.testFailNextSave = true
        await engine.recordDelivered(manifest: manifest1, successKind: .delivered(serverPath: nil, serverTimestamp: nil), journalIdentity: "journal-test")
        XCTAssertEqual(store.document, beforeAcknowledgement)
        XCTAssertEqual(engine.status.deliveredNotesCount, 0)
        XCTAssertEqual(engine.status.totalFoundNotes, 3)
        let afterFailedSave = ObsidianStore(rootURL: self.storeURL)
        XCTAssertEqual(afterFailedSave.document, beforeAcknowledgement)

        // Retrying the same acknowledged file commits its unique notes once.
        await engine.recordDelivered(manifest: manifest1, successKind: .delivered(serverPath: nil, serverTimestamp: nil), journalIdentity: "journal-test")
        XCTAssertEqual(engine.status.deliveredNotesCount, 2)
        XCTAssertEqual(engine.status.totalFoundNotes, 3)

        // Duplicate delivery of the same manifest or same path does not add again
        await engine.recordDelivered(manifest: manifest1, successKind: .alreadyStartedOrComplete(serverPath: nil, serverTimestamp: nil), journalIdentity: "journal-test")
        XCTAssertEqual(engine.status.deliveredNotesCount, 2)

        // segment_removed does not add notes
        let outboxItem2 = ObsidianOutboxItem(
            itemID: UUID(),
            filename: "file2.jsonl",
            window: ObsidianWindow(day: "20261108", segment: "094500_300"),
            createdAt: Date(),
            lineCount: 1,
            byteCount: 50,
            sha256Hex: "hash2",
            timeZoneIdentifier: "America/Denver",
            offsetSeconds: -25200,
            vaultID: vaultID,
            folderName: "ProgressVault",
            noteIdentityHashes: [hash3]
        )
        let manifest2 = ObsidianTransfer.manifest(for: outboxItem2)
        await engine.recordDelivered(manifest: manifest2, successKind: .removedInJournal, journalIdentity: "journal-test")
        XCTAssertEqual(engine.status.deliveredNotesCount, 2)

        // 3. Every note acknowledged -> delivered equals found
        await engine.recordDelivered(manifest: manifest2, successKind: .delivered(serverPath: nil, serverTimestamp: nil), journalIdentity: "journal-test")
        XCTAssertEqual(engine.status.deliveredNotesCount, 3)
        XCTAssertEqual(engine.status.deliveredNotesCount, engine.status.totalFoundNotes)

        // 4. A new store on the same directory keeps both numbers across relaunch
        let store2 = ObsidianStore(rootURL: self.storeURL)
        let engine2 = ObsidianSourceEngine(store: store2, intakeStore: intake)
        engine2.journalIdentityProvider = { "journal-test" }
        XCTAssertEqual(engine2.status.totalFoundNotes, 3)
        XCTAssertEqual(engine2.status.deliveredNotesCount, 3)
        engine2.journalIdentityProvider = { "different-empty-journal" }
        XCTAssertEqual(engine2.status.deliveredNotesCount, 0)
        engine2.journalIdentityProvider = { nil }
        XCTAssertEqual(engine2.status.deliveredNotesCount, 0)
        engine2.journalIdentityProvider = { "journal-test" }
        XCTAssertEqual(engine2.status.deliveredNotesCount, 3)
    }
}

private extension Result where Success == Void, Failure: Equatable {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
