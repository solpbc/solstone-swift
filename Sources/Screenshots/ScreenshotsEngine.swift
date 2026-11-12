// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// What the screens say. Replaced as a whole so a change is visible.
struct ScreenshotsSnapshot: Equatable {
    var everOn = false
    var enabled = false
    var paused = false
    var needsSpan = false
    var access: ScreenshotsAccess = .notDetermined
    var fullAccessWasHeld = false
    var capabilityNotListed = false
    var paired = false
    var selectedSpan: ScreenshotsSpan = .last30Days
    var confirm: ScreenshotsConfirm = .checking
    var progressDone = 0
    var progressTotal = 0
    var backfillOpen = false
    var lastChecked: Date?
    var waiting = 0
    var finals: [ScreenshotsFinal] = []
    var view: ScreenshotsViewState = ScreenshotsPresentation.viewState(ScreenshotsViewInput(
        everOn: false, enabled: false, paused: false, needsSpan: false, access: .notDetermined,
        fullAccessWasHeld: false, paired: false, capabilityNotListed: false, backfillOpen: false,
        progressDone: 0, progressTotal: 0
    ))
}

enum ScreenshotsConfirm: Equatable {
    case checking
    case failed
    case ready(ScreenshotsSpan, Int)
}

struct ScreenshotsFinal: Equatable, Identifiable {
    var localIdentifier: String
    var phase: ScreenshotsPhase
    var id: String { self.localIdentifier }
}

@MainActor
@Observable
final class ScreenshotsSourceEngine {
    private let library: any ScreenshotsLibrary
    private let store: ScreenshotsStore
    private let sender: any ScreenshotsSending
    private let intake: SourceIntakeStore?
    private let timeZone: TimeZone
    var isPaired: () -> Bool = { false }
    private(set) var snapshot = ScreenshotsSnapshot()
    private var pumping = false

    init(
        library: any ScreenshotsLibrary,
        store: ScreenshotsStore,
        sender: any ScreenshotsSending,
        intake: SourceIntakeStore? = nil,
        timeZone: TimeZone = .current
    ) {
        self.library = library
        self.store = store
        self.sender = sender
        self.intake = intake
        self.timeZone = timeZone
        self.library.setObserving(false)
        self.publish()
    }

    var wantsBackgroundRefresh: Bool {
        let document = self.store.document
        return document.everOn && document.enabled && !document.needsSpan && self.library.access() == .full
    }

    var waitingCount: Int { self.snapshot.waiting }

    /// Waiting screenshots that cannot leave yet, so finish-syncing does not wait on them.
    var unsendableCount: Int {
        self.snapshot.capabilityNotListed || self.library.access() != .full ? self.snapshot.waiting : 0
    }

    func launch() async {
        self.refreshAccess()
        await self.catchUp()
        if self.snapshot.view.showChooser { await self.count() }
        await self.pump()
    }

    func foreground() async {
        self.refreshAccess()
        await self.catchUp()
        await self.pump()
    }

    func backgroundRefresh() async -> Bool {
        guard self.wantsBackgroundRefresh else { return true }
        await self.catchUp()
        await self.pump()
        return true
    }

    func refreshAccess() {
        let access = self.library.access()
        if access == .full {
            self.store.document.fullAccessWasHeld = true
            self.library.setObserving(true)
        } else {
            self.library.setObserving(false)
        }
        self.store.save()
        self.publish()
    }

    func requestFullAccess() async {
        let access = await self.library.requestAccess()
        if access == .full { self.store.document.fullAccessWasHeld = true }
        self.library.setObserving(access == .full)
        self.store.save()
        self.publish()
        if access == .full { await self.count() }
    }

    func chooseSpan(_ span: ScreenshotsSpan) async {
        self.store.document.selectedSpan = span
        self.store.save()
        await self.count()
    }

    func confirm() async {
        let document = self.store.document
        guard case .ready(let span, _) = self.snapshot.confirm, span == document.selectedSpan else { return }
        let ids = document.countedIDs
        self.store.document.everOn = true
        self.store.document.enabled = true
        self.store.document.needsSpan = false
        self.store.document.liveFloor = span.start(now: Date(), timeZone: self.timeZone)
        self.store.document.progressDone = 0
        self.store.document.progressTotal = ids.count
        let delivered = self.store.document.deliveredLocalIDs
        for id in ids where !delivered.contains(id) {
            if let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == id }) {
                self.store.document.items[index].inFrozen = true
            } else if let asset = await self.library.asset(localIdentifier: id) {
                self.store.document.items.append(self.item(asset, frozen: true))
            } else {
                self.store.document.items.append(ScreenshotsItem(
                    localIdentifier: id, created: Date(), phase: .deleted, hash: nil,
                    inFrozen: true, countedInProgress: true, exportAttempts: 0
                ))
                self.store.document.progressDone += 1
            }
        }
        for index in self.store.document.items.indices where !ids.contains(self.store.document.items[index].localIdentifier) {
            self.store.document.items[index].inFrozen = false
        }
        self.recountFrozen()
        if self.store.document.changeToken == nil {
            self.store.document.changeToken = self.library.currentToken()
        }
        self.store.document.lastChecked = Date()
        self.store.save()
        self.publish()
        await self.pump()
    }

    func turnOn() async {
        if self.store.document.everOn {
            self.closePause(at: Date())
            self.store.document.enabled = true
            self.store.document.needsSpan = true
            self.store.document.paused = false
            self.store.save()
            self.publish()
            await self.count()
            return
        }
        await self.requestFullAccess()
    }

    func turnOff() {
        self.closePause(at: Date())
        self.store.document.enabled = false
        self.store.document.paused = false
        self.store.document.needsSpan = false
        self.store.save()
        self.publish()
    }

    func pause() {
        guard self.store.document.enabled, !self.store.document.paused, !self.store.document.needsSpan else { return }
        self.store.document.paused = true
        self.store.document.pauseWindows.append(ScreenshotsPauseWindow(start: Date(), end: nil))
        self.store.save()
        self.publish()
        Task { await self.catchUp() }
    }

    func resume() async {
        guard self.store.document.paused else { return }
        self.closePause(at: Date())
        self.store.document.paused = false
        self.store.save()
        self.publish()
        await self.catchUp()
        await self.pump()
    }

    func retry(_ localIdentifier: String) async {
        guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == localIdentifier }) else { return }
        let phase = self.store.document.items[index].phase
        guard ScreenshotsVocabulary.finalCanRetry(phase) else { return }
        self.store.document.items[index].phase = .pending
        self.store.document.items[index].exportAttempts = 0
        self.store.save()
        self.publish()
        await self.pump()
    }

    /// A new pairing: an on source asks how far back again, with a fresh count, and sends
    /// nothing new until the owner confirms. An off source stays off and asks when turned on.
    /// Photos access and a pause stay. A screenshot already waiting still goes, to the journal
    /// paired now. Saved before it returns.
    func restartFirstSetup() {
        // What the earlier journal had is no record of what this one has.
        self.store.document.items.removeAll { $0.phase == .delivered }
        self.store.document.progressDone = 0
        self.store.document.progressTotal = 0
        // The last count was the earlier journal's: it is not this one's consent.
        self.store.document.countedSpan = nil
        self.store.document.countedIDs = []
        if self.store.document.everOn && self.store.document.enabled {
            self.store.document.needsSpan = true
        }
        self.store.save()
        self.publish()
        guard self.snapshot.view.showChooser else { return }
        Task { await self.count() }
    }

    func noteCapability(_ capability: ScreenshotsCapabilityGate.Capability) {
        self.snapshot.capabilityNotListed = capability == .notListed
        self.publish()
        if capability == .listed {
            Task { await self.pump() }
        }
    }

    func noteDelivered(localIdentifier: String, hash: String) {
        guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == localIdentifier }) else { return }
        self.store.document.items[index].phase = .delivered
        self.store.document.items[index].hash = hash
        self.markProgress(at: index)
        self.intake?.recordScreenshot(hash: hash, now: Date())
        self.store.save()
        self.publish()
        Task { await self.pump() }
    }

    func noteRefused(localIdentifier: String) {
        guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == localIdentifier }) else { return }
        guard !self.store.document.items[index].phase.isTerminal else { return }
        self.finish(index, .journalRefused)
    }

    func libraryChanged() async {
        await self.catchUp()
        await self.pump()
    }

    private func count() async {
        guard self.library.access() == .full else { return }
        let span = self.store.document.selectedSpan
        self.store.document.isCounting = true
        self.store.document.countFailed = false
        self.store.save()
        self.publish()
        let start = span.start(now: Date(), timeZone: self.timeZone)
        do {
            let assets = try await self.library.screenshots(onOrAfter: start)
            let delivered = self.store.document.deliveredLocalIDs
            let ids = assets.map(\.localIdentifier).filter { !delivered.contains($0) }
            guard self.store.document.selectedSpan == span else { return }
            self.store.document.countedSpan = span
            self.store.document.countedIDs = ids
            self.store.document.isCounting = false
            self.store.document.countFailed = false
        } catch {
            self.store.document.isCounting = false
            self.store.document.countFailed = true
            self.store.document.countedIDs = []
            self.store.document.countedSpan = nil
        }
        self.store.save()
        self.publish()
    }

    private func catchUp() async {
        let document = self.store.document
        guard document.everOn, document.enabled, !document.needsSpan, self.library.access() == .full else { return }
        let changes = await self.library.changes(since: document.changeToken)
        switch changes {
        case .expired:
            await self.rescan()
        case .delta(let inserted, let updated, let deleted, let token):
            self.apply(deleted: deleted)
            let ids = Array(Set(inserted + updated))
            for id in ids {
                guard let asset = await self.library.asset(localIdentifier: id) else { continue }
                self.considerLive(asset)
            }
            self.store.document.changeToken = token
        }
        self.store.document.lastChecked = Date()
        self.store.save()
        self.publish()
    }

    private func rescan() async {
        let start = self.store.document.liveFloor
            ?? self.store.document.selectedSpan.start(now: Date(), timeZone: self.timeZone)
        guard let assets = try? await self.library.screenshots(onOrAfter: start) else { return }
        for asset in assets {
            if self.store.document.items.contains(where: { $0.localIdentifier == asset.localIdentifier && $0.phase != .pending }) {
                continue
            }
            let frozen = self.store.document.items.first(where: { $0.localIdentifier == asset.localIdentifier })?.inFrozen ?? false
            if !frozen && ScreenshotsWire.takenWhilePaused(created: asset.created, windows: self.store.document.pauseWindows) {
                continue
            }
            self.considerLive(asset, ignorePause: frozen)
        }
        self.store.document.changeToken = self.library.currentToken()
    }

    private func considerLive(_ asset: ScreenshotsAsset, ignorePause: Bool = false) {
        if let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
            let item = self.store.document.items[index]
            if item.phase.isTerminal || item.phase == .queued { return }
            if item.inFrozen || ignorePause { return }
            if self.store.document.paused || ScreenshotsWire.takenWhilePaused(created: asset.created, windows: self.store.document.pauseWindows) {
                return
            }
            return
        }
        // Photos reports an edit, a favourite or a new date on an old screenshot as a change.
        // One from before what the owner chose, that this source never took, stays out.
        if let floor = self.store.document.liveFloor, asset.created < floor { return }
        if self.store.document.paused || ScreenshotsWire.takenWhilePaused(created: asset.created, windows: self.store.document.pauseWindows) {
            return
        }
        self.store.document.items.append(ScreenshotsItem(
            localIdentifier: asset.localIdentifier,
            created: asset.created,
            phase: .pending,
            hash: nil,
            inFrozen: false,
            countedInProgress: false,
            exportAttempts: 0
        ))
    }

    private func apply(deleted: [String]) {
        for id in deleted {
            guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == id }) else { continue }
            let phase = self.store.document.items[index].phase
            guard phase == .pending else { continue }
            self.finish(index, .deleted)
        }
    }

    private func pump() async {
        guard !self.pumping else { return }
        self.pumping = true
        defer { self.pumping = false }
        let document = self.store.document
        guard document.enabled, !document.needsSpan, self.library.access() == .full else { return }
        let queued = document.items.filter { $0.phase == .queued }.count
        let room = max(0, ScreenshotsWire.copyWindow - queued)
        guard room > 0 else { return }
        let candidates = self.store.document.items.filter { item in
            guard item.phase == .pending else { return false }
            if item.inFrozen { return true }
            if self.store.document.paused { return false }
            return !ScreenshotsWire.takenWhilePaused(created: item.created, windows: self.store.document.pauseWindows)
        }.prefix(room)
        for candidate in candidates {
            await self.export(candidate.localIdentifier)
        }
    }

    private func export(_ localIdentifier: String) async {
        guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == localIdentifier }),
              self.store.document.items[index].phase == .pending
        else { return }
        let found = await self.library.asset(localIdentifier: localIdentifier)
        // A new pairing may have dropped items while Photos was asked.
        guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == localIdentifier }) else { return }
        guard let asset = found else {
            self.finish(index, .deleted)
            return
        }
        if ScreenshotsWire.exceedsLimits(byteCount: 0, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight) {
            self.finish(index, .tooBig)
            return
        }
        let exported = await self.library.export(localIdentifier: localIdentifier)
        guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == localIdentifier }) else { return }
        switch exported {
        case .missing:
            self.finish(index, .deleted)
        case .failed:
            self.store.document.items[index].exportAttempts += 1
            if self.store.document.items[index].exportAttempts >= ScreenshotsWire.exportAttempts {
                self.finish(index, .unreadable)
            } else {
                self.store.save()
                await self.export(localIdentifier)
            }
        case .bytes(let data, let uti):
            await self.accept(index: index, asset: asset, data: data, uti: uti)
        }
    }

    private func accept(index: Int, asset: ScreenshotsAsset, data: Data, uti: String) async {
        guard let prepared = ScreenshotsWire.uploadBytes(data: data, uniformTypeIdentifier: uti) else {
            self.finish(index, .refusedType)
            return
        }
        let pixels = ScreenshotsWire.pixels(in: prepared.data)
        let width = pixels?.0 ?? asset.pixelWidth
        let height = pixels?.1 ?? asset.pixelHeight
        if ScreenshotsWire.exceedsLimits(byteCount: prepared.data.count, pixelWidth: width, pixelHeight: height) {
            self.finish(index, .tooBig)
            return
        }
        let hash = ScreenshotsWire.sha256Hex(prepared.data)
        // The same bytes under another screenshot are already in this journal.
        if self.store.document.hasDelivered(hash: hash) {
            self.store.document.items[index].hash = hash
            self.store.document.items[index].phase = .delivered
            self.markProgress(at: index)
            self.store.save()
            self.publish()
            return
        }
        let zone = self.timeZone
        let placement = ScreenshotsWire.placement(of: asset.created, timeZone: zone)
        let upload = ScreenshotsUpload(
            localIdentifier: asset.localIdentifier,
            itemID: ScreenshotsWire.itemID(forHash: hash),
            bytes: prepared.data,
            filename: ScreenshotsWire.filename(ext: prepared.ext),
            contentType: prepared.contentType,
            hash: hash,
            capturedAt: placement.capturedAt,
            day: placement.day,
            segment: placement.segment,
            offsetSeconds: placement.offsetSeconds,
            timeZoneIdentifier: zone.identifier,
            created: asset.created
        )
        do {
            try await self.sender.send(upload)
            guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else { return }
            self.store.document.items[index].phase = .queued
            self.store.document.items[index].hash = hash
            self.intake?.recordScreenshot(hash: hash, now: Date())
            self.store.save()
            self.publish()
        } catch {
            // A new pairing may have dropped items while the send was awaited.
            guard let index = self.store.document.items.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else { return }
            self.store.document.items[index].exportAttempts += 1
            if self.store.document.items[index].exportAttempts >= ScreenshotsWire.exportAttempts {
                self.finish(index, .unreadable)
            } else {
                self.store.save()
            }
        }
    }

    private func finish(_ index: Int, _ phase: ScreenshotsPhase) {
        guard self.store.document.items.indices.contains(index) else { return }
        self.store.document.items[index].phase = phase
        self.markProgress(at: index)
        self.store.save()
        self.publish()
    }

    private func markProgress(at index: Int) {
        guard self.store.document.items[index].inFrozen, !self.store.document.items[index].countedInProgress else { return }
        guard self.store.document.items[index].phase.isTerminal else { return }
        self.store.document.items[index].countedInProgress = true
        self.store.document.progressDone += 1
    }

    private func recountFrozen() {
        let frozen = self.store.document.items.filter(\.inFrozen)
        self.store.document.progressTotal = frozen.count
        self.store.document.progressDone = frozen.filter(\.countedInProgress).count
    }

    private func item(_ asset: ScreenshotsAsset, frozen: Bool) -> ScreenshotsItem {
        ScreenshotsItem(
            localIdentifier: asset.localIdentifier,
            created: asset.created,
            phase: .pending,
            hash: nil,
            inFrozen: frozen,
            countedInProgress: false,
            exportAttempts: 0
        )
    }

    private func closePause(at date: Date) {
        guard let index = self.store.document.pauseWindows.lastIndex(where: { $0.end == nil }) else { return }
        self.store.document.pauseWindows[index].end = date
    }

    private func publish() {
        let document = self.store.document
        let access = self.library.access()
        let paired = self.isPaired()
        let backfillOpen = document.progressTotal > 0 && document.progressDone < document.progressTotal
        let input = ScreenshotsViewInput(
            everOn: document.everOn,
            enabled: document.enabled,
            paused: document.paused,
            needsSpan: document.needsSpan,
            access: access,
            fullAccessWasHeld: document.fullAccessWasHeld,
            paired: paired,
            capabilityNotListed: self.snapshot.capabilityNotListed,
            backfillOpen: backfillOpen,
            progressDone: document.progressDone,
            progressTotal: document.progressTotal
        )
        let confirm: ScreenshotsConfirm
        if document.countFailed {
            confirm = .failed
        } else if document.isCounting || document.countedSpan != document.selectedSpan {
            confirm = .checking
        } else {
            confirm = .ready(document.selectedSpan, document.countedIDs.count)
        }
        let waiting = document.items.filter { $0.phase == .pending || $0.phase == .queued }.count
        self.snapshot = ScreenshotsSnapshot(
            everOn: document.everOn,
            enabled: document.enabled,
            paused: document.paused,
            needsSpan: document.needsSpan,
            access: access,
            fullAccessWasHeld: document.fullAccessWasHeld,
            capabilityNotListed: self.snapshot.capabilityNotListed,
            paired: paired,
            selectedSpan: document.selectedSpan,
            confirm: confirm,
            progressDone: document.progressDone,
            progressTotal: document.progressTotal,
            backfillOpen: backfillOpen,
            lastChecked: document.lastChecked,
            waiting: waiting,
            finals: document.items.filter { ScreenshotsVocabulary.finalMessage($0.phase) != nil }.map {
                ScreenshotsFinal(localIdentifier: $0.localIdentifier, phase: $0.phase)
            },
            view: ScreenshotsPresentation.viewState(input)
        )
    }
}
