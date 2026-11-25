// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

nonisolated enum HomeSourceTileControl: Equatable {
    case none
    case toggle
}

/// The deck tile.
///
/// Composition is the approved mock's, which the shipped build had flattened to a
/// name, a switch and a state word: glyph and control on the top line, then the
/// source's name, then the state (dot + word), then the state's own sub-line. The
/// sub-line is `SourceState.subtext(...)` — it already existed in the vocabulary and
/// simply was not being drawn, which is what left every tile two lines tall and the
/// grid ragged.
///
/// Every tile fills its row (`maxHeight: .infinity`), so a row of tiles is one band
/// rather than a set of differently-sized cards top-aligned against each other.
struct HomeSourceTile: View {
    let source: Source
    let route: SourceRoute
    let control: HomeSourceTileControl
    var isOn: Binding<Bool> = .constant(false)
    var otherDevices: [KnownSources.Device] = []
    var now = Date.distantPast
    var switchDisabled: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ShellNavModel.self) private var nav
    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 20

    var body: some View {
        Button {
            self.nav.selectFromDeck(ShellDestination.source(self.route))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                self.topLine
                self.caption
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ShellMetrics.tilePadding)
            // The tile is far larger than the floor in every real layout; stating the
            // floor keeps that true at the smallest text size and smallest window.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(ShellMetrics.tileShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(self.source.displayName)
        .accessibilityValue(self.tileAccessibilityValue)
        .accessibilityIdentifier("dayHome.tile.\(self.source.id)")
        .background(Color.deckSurface, in: ShellMetrics.tileShape)
        .overlay {
            ShellMetrics.tileShape.stroke(Color.deckHairline, lineWidth: 0.5)
        }
        .hoverEffect(.highlight)
    }

    /// The tile's accessible value: state word plus subtext override for observer or for any source in needs attention with an override, state word alone otherwise.
    static func accessibilityValue(for source: Source) -> String {
        if source.kind == .observer, let subtextOverride = source.subtextOverride {
            return AppStrings.ios_frame_homesourcetile_n66("\(source.state.label)", "\(subtextOverride)")
        }
        if source.state == .needsAttention, let subtextOverride = source.subtextOverride {
            return AppStrings.ios_frame_homesourcetile_n66("\(source.state.label)", "\(subtextOverride)")
        }
        return source.state.label
    }

    private var tileAccessibilityValue: String {
        guard let device = otherDevices.first, let entry = device.sources.first else { return Self.accessibilityValue(for: source) }
        return AppStrings.ios_frame_homesourcetile_n66(SharedSourceCopy.heading(otherDevices.count),
            SharedSourceCopy.line(device: device, entry: entry, spoken: true, now: now))
    }

    /// Glyph and control share the top line. At accessibility sizes the control drops
    /// below the glyph rather than squeezing it.
    @ViewBuilder
    private var topLine: some View {
        if self.dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                self.glyph
                switch self.control {
                case .none:
                    EmptyView()
                case .toggle:
                    self.switchSlot
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                self.glyph
                Spacer(minLength: 4)
                switch self.control {
                case .none:
                    EmptyView()
                case .toggle:
                    self.switchSlot
                }
            }
            // Every tile reserves the switch's row, with or without a switch, so the names
            // below line up across a row instead of dropping wherever a switch happens to sit.
            .frame(minHeight: ShellMetrics.tileTopLineHeight, alignment: .top)
        }
    }

    private var glyph: some View {
        Image(systemName: self.source.kind.glyph)
            .font(.system(size: self.glyphSize, weight: .medium))
            .foregroundStyle(self.glyphTint)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.source.displayName)
                .font(ShellFont.tileName)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let device = otherDevices.first, let entry = device.sources.first {
                SharedSourceHeading(count: otherDevices.count)
                SharedSourceTileLine(device: device, entry: entry, now: now)
            } else {
                HStack(spacing: 6) {
                    HomeSourceStateDot(state: self.source.state)
                    Text(self.source.state.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(self.stateLabelColor)
                }
                if self.source.showsSubtext, let subtext = self.subtext {
                    Text(subtext)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// An override only earns the sub-line if it says something the state word did
    /// not. `screen` supplies `off` as its own override, which under the state word
    /// `off` renders the tile as "off / off"; a sub-line that restates the line above
    /// it is noise, so it falls through to the state's own compact text.
    private var subtext: String? {
        if let override = self.source.subtextOverride, override != self.source.state.label {
            return override
        }
        return self.source.state.compactSubtext(activeSubtext: self.source.activeSubtext)
    }

    @ViewBuilder
    private var switchSlot: some View {
        Toggle("", isOn: self.isOn)
            .labelsHidden()
            .tint(.solOrange)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(self.switchDisabled)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityLabel(self.source.displayName)
            .accessibilityValue(Self.accessibilityValue(for: self.source))
            .accessibilityIdentifier("dayHome.tile.\(self.source.id).toggle")
    }

    /// The glyph carries the source's liveness: lit while it is taking something in,
    /// quiet otherwise. It is the same information the dot carries, at the size the
    /// eye lands on first.
    private var glyphTint: Color {
        switch self.source.state {
        case .active, .enrolling:
            .solOrangeAdaptive
        case .needsAttention:
            .red
        case .off, .paused, .readyToSetUp, .checking:
            .secondary
        }
    }

    private var stateLabelColor: Color {
        switch self.source.state {
        case .readyToSetUp:
            self.colorScheme == .dark ? .primary : .textOrangeAA
        case .active, .enrolling:
            .primary
        case .off, .checking, .paused, .needsAttention:
            .secondary
        }
    }
}

/// `import` and `add more` are destinations, not sources: no state word and no
/// control, per the shell contract. They share the source tile's shape and rhythm so
/// the deck reads as one grid.
private struct HomeDestinationTile: View {
    let glyph: String
    let title: String
    let subline: String
    let badgeVisible: Bool
    let identifier: String
    /// An empty slot rather than a thing the owner has: drawn as a dashed outline on
    /// the ground, so `add more` never reads as a sixth source at a glance.
    var isSlot: Bool = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 20

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: self.glyph)
                    .font(.system(size: self.glyphSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    // The same top line as a source tile, so `import` and `add more` line up with it.
                    .frame(minHeight: ShellMetrics.tileTopLineHeight, alignment: .top)
                    .overlay(alignment: .topTrailing) {
                        if self.badgeVisible {
                            Circle()
                                .fill(Color.solOrange)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -2)
                        }
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.title)
                        .font(ShellFont.tileName)
                        .foregroundStyle(.primary)
                    Text(self.subline)
                        .font(.footnote)
                        // A slot has no fill, so its subline sits straight on the sun arc's
                        // ground: `.secondary` measured 2.8:1 on the light true-dark ground
                        // and over the sun. 85 % primary also clears the selected deeper
                        // light night ground while keeping the empty-slot distinction.
                        .foregroundStyle(self.isSlot ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ShellMetrics.tilePadding)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(ShellMetrics.tileShape)
        }
        .buttonStyle(.plain)
        .background(self.isSlot ? Color.clear : Color.deckSurface, in: ShellMetrics.tileShape)
        .overlay {
            if self.isSlot {
                // Ink, not the hairline: the slot sits straight on the sun arc's ground, and the
                // hairline vanished on the night ground.
                ShellMetrics.tileShape.stroke(
                    Color.primary.opacity(0.38),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
            } else {
                ShellMetrics.tileShape.stroke(Color.deckHairline, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(self.title)
        .accessibilityValue(self.subline)
        .accessibilityIdentifier(self.identifier)
        .hoverEffect(.highlight)
    }
}

struct HomeAddMoreTile: View {
    var badgeVisible: Bool
    let onTap: () -> Void

    var body: some View {
        HomeDestinationTile(
            glyph: "plus",
            title: SourceVocabulary.addMoreTitle,
            subline: SourceVocabulary.addMoreSubline,
            badgeVisible: self.badgeVisible,
            identifier: "dayHome.sourcesEntry",
            isSlot: true,
            action: self.onTap
        )
    }
}

nonisolated enum HomeImportTileSignal: Equatable, Sendable {
    case idle
    case waiting(detail: String)
    case paused(detail: String)
    case sending(detail: String)
    case checking(detail: String)
    case readyToReview(detail: String)
    case needsAttention(detail: String)

    var statusWord: String? {
        switch self {
        case .idle: nil
        case .waiting: AppStrings.ios_app_importtilewaiting()
        case .paused: AppStrings.ios_app_importtilepaused()
        case .sending: AppStrings.ios_app_sending()
        case .checking: AppStrings.ios_app_importtilechecking()
        case .readyToReview: AppStrings.ios_app_importtilereadytoreview()
        case .needsAttention: AppStrings.ios_transfer_needsattention()
        }
    }

    var detailText: String {
        switch self {
        case .idle: SourceVocabulary.importSubline
        case .waiting(let detail), .paused(let detail), .sending(let detail), .checking(let detail), .readyToReview(let detail), .needsAttention(let detail):
            detail
        }
    }

    var accessibilityLabel: String {
        guard let statusWord = self.statusWord else {
            return SourceVocabulary.importTitle
        }
        return AppStrings.ios_app_importtilespoken(statusWord, self.detailText)
    }

    var accessibilityValue: String {
        self.statusWord == nil ? SourceVocabulary.importSubline : ""
    }

    var uiTestSignalName: String {
        switch self {
        case .idle: "idle"
        case .waiting: "waiting"
        case .paused: "paused"
        case .sending: "sending"
        case .checking: "checking"
        case .readyToReview: "readyToReview"
        case .needsAttention: "needsAttention"
        }
    }

    private static func resumableProgressDetail(
        progress: TransferResumableProgress,
        otherQueuedCount: Int
    ) -> String {
        let sent = ImportByteFormat.bytes(progress.bytesSent)
        let total = ImportByteFormat.bytes(progress.bytesTotal)
        if otherQueuedCount > 0 {
            return AppStrings.ios_app_importtileprogressmore(otherQueuedCount, sent, total)
        }
        return AppStrings.ios_app_importtileprogress(sent, total)
    }

    /// Worst-signal-wins resolution for the Home `import` tile:
    /// `needs attention` > `ready to review` > `checking` / `sending` > `paused` > `waiting` > `idle`.
    static func resolve(
        failedCount: Int,
        readyToReviewCount: Int,
        reviewExpiredCount: Int,
        inFlightCount: Int,
        pendingCount: Int,
        activeItems: [ShareImportActiveItem],
        isOfflineOrUnpaired: Bool,
        isPairingRefused: Bool = false
    ) -> HomeImportTileSignal {
        if failedCount > 0 {
            let matching = activeItems.filter {
                if case .needsAttention = $0.phase { return true }
                return false
            }
            let detail = failedCount == 1
                ? (matching.first?.filename ?? AppStrings.ios_app_importtileitemscount(1))
                : AppStrings.ios_app_importtileitemscount(failedCount)
            return .needsAttention(detail: detail)
        }
        let queuedOrActiveTotal = max(pendingCount, inFlightCount)
        if isPairingRefused, queuedOrActiveTotal > 0 {
            let matching = activeItems.filter(\.isDeviceListItem)
            let detail = queuedOrActiveTotal == 1
                ? (matching.first?.filename ?? AppStrings.ios_app_importtileitemscount(1))
                : AppStrings.ios_app_importtileitemscount(queuedOrActiveTotal)
            return .needsAttention(detail: detail)
        }
        let reviewTotal = readyToReviewCount + reviewExpiredCount
        if reviewTotal > 0 {
            let matching = activeItems.filter(\.isReviewCardItem)
            let detail = reviewTotal == 1
                ? (matching.first?.filename ?? AppStrings.ios_app_importtilereadycount(1))
                : AppStrings.ios_app_importtilereadycount(reviewTotal)
            return .readyToReview(detail: detail)
        }

        let otherQueuedCount = max(0, queuedOrActiveTotal - 1)
        if let checkingItem = activeItems.first(where: {
            if case .sending = $0.phase, $0.resumableProgress?.phase == .checking { return true }
            return false
        }), let progress = checkingItem.resumableProgress {
            return .checking(detail: Self.resumableProgressDetail(progress: progress, otherQueuedCount: otherQueuedCount))
        }
        if let sendingResumable = activeItems.first(where: {
            if case .sending = $0.phase, $0.resumableProgress?.phase == .sending { return true }
            return false
        }), let progress = sendingResumable.resumableProgress {
            return .sending(detail: Self.resumableProgressDetail(progress: progress, otherQueuedCount: otherQueuedCount))
        }

        let pausedInFlightCount = activeItems.filter {
            if case .sending = $0.phase, $0.resumableProgress?.phase == .paused { return true }
            return false
        }.count
        let activeNonPausedInFlight = max(0, inFlightCount - pausedInFlightCount)
        if activeNonPausedInFlight > 0 {
            let matching = activeItems.filter {
                if case .sending = $0.phase { return $0.resumableProgress?.phase != .paused }
                return false
            }
            let detail = activeNonPausedInFlight == 1
                ? (matching.first?.filename ?? AppStrings.ios_app_importtilefilescount(1))
                : AppStrings.ios_app_importtilefilescount(activeNonPausedInFlight)
            return .sending(detail: detail)
        }

        let pausedResumable = activeItems.filter { item in
            switch item.phase {
            case .sending:
                return item.resumableProgress?.phase == .paused
            case .waiting:
                return item.resumableProgress != nil
            case .readyToReview, .reviewExpired, .needsAttention:
                return false
            }
        }.max { lhs, rhs in
            let lBytes = lhs.resumableProgress?.bytesSent ?? 0
            let rBytes = rhs.resumableProgress?.bytesSent ?? 0
            if lBytes != rBytes { return lBytes < rBytes }
            return lhs.createdAt < rhs.createdAt
        }
        if let pausedResumable, let progress = pausedResumable.resumableProgress {
            return .paused(detail: Self.resumableProgressDetail(progress: progress, otherQueuedCount: otherQueuedCount))
        }

        if pendingCount > 0 {
            let detail = isOfflineOrUnpaired
                ? AppStrings.ios_app_importtilewaitingforjournal()
                : AppStrings.ios_app_importtilewaitingcount(pendingCount)
            return .waiting(detail: detail)
        }
        return .idle
    }
}

/// Distinct shape + color marker for each active import tile state (never color alone).
struct HomeImportStateMarker: View {
    let signal: HomeImportTileSignal
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 10

    var body: some View {
        self.shape
            .frame(width: self.size, height: self.size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shape: some View {
        switch self.signal {
        case .idle:
            EmptyView()
        case .waiting:
            Circle().strokeBorder(.secondary, lineWidth: 1.5)
        case .paused:
            HStack(spacing: max(1.5, self.size * 0.2)) {
                Capsule().fill(.secondary).frame(width: max(2, self.size * 0.26), height: self.size * 0.85)
                Capsule().fill(.secondary).frame(width: max(2, self.size * 0.26), height: self.size * 0.85)
            }
        case .sending:
            Circle().fill(Color.solOrange)
        case .checking:
            Circle().strokeBorder(Color.solOrange, lineWidth: 1.75)
        case .readyToReview:
            ZStack {
                Circle().strokeBorder(Color.solOrange, lineWidth: 1.5)
                Circle()
                    .fill(Color.solOrange)
                    .frame(width: self.size * 0.42, height: self.size * 0.42)
            }
        case .needsAttention:
            ZStack {
                Circle().strokeBorder(Color.red, lineWidth: 1.5)
                Capsule()
                    .fill(Color.red)
                    .frame(width: self.size * 0.7, height: 1.5)
            }
        }
    }
}

struct HomeImportTile: View {
    @Environment(ShellNavModel.self) private var nav
    @Environment(ShareTransferHolder.self) private var shareTransferHolder: ShareTransferHolder?
    @Environment(AppConfig.self) private var appConfig: AppConfig?
    @Environment(TunnelManager.self) private var tunnelManager: TunnelManager?
    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 20

    private var signal: HomeImportTileSignal {
        guard let holder = self.shareTransferHolder else { return .idle }
        let isOfflineOrUnpaired = !(self.appConfig?.isPaired ?? false)
            || !(self.tunnelManager?.state.isConnected ?? false)
            || (self.appConfig?.awaitingMarkConfirmation ?? false)
            || holder.isPairingRefused
        return HomeImportTileSignal.resolve(
            failedCount: holder.failedCount,
            readyToReviewCount: holder.readyToReviewCount,
            reviewExpiredCount: holder.reviewExpiredCount,
            inFlightCount: holder.inFlightCount,
            pendingCount: holder.pendingCount,
            activeItems: holder.liveActiveItems,
            isOfflineOrUnpaired: isOfflineOrUnpaired,
            isPairingRefused: holder.isPairingRefused
        )
    }

    var body: some View {
        let resolved = self.signal
        if resolved == .idle {
            HomeDestinationTile(
                glyph: "square.and.arrow.down",
                title: SourceVocabulary.importTitle,
                subline: SourceVocabulary.importSubline,
                badgeVisible: false,
                identifier: "dayHome.importEntry",
                action: { self.nav.selectFromDeck(ShellDestination.import) }
            )
        } else {
            self.activeTile(resolved)
        }
    }

    private func activeTile(_ resolved: HomeImportTileSignal) -> some View {
        Button {
            self.nav.selectFromDeck(ShellDestination.import)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: self.glyphSize, weight: .medium))
                    .foregroundStyle(self.glyphTint(for: resolved))
                    .frame(minHeight: ShellMetrics.tileTopLineHeight, alignment: .top)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(SourceVocabulary.importTitle)
                        .font(ShellFont.tileName)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let statusWord = resolved.statusWord {
                        HStack(spacing: 6) {
                            HomeImportStateMarker(signal: resolved)
                            Text(statusWord)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(self.wordColor(for: resolved))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(resolved.detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ShellMetrics.tilePadding)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(ShellMetrics.tileShape)
        }
        .buttonStyle(.plain)
        .background(Color.deckSurface, in: ShellMetrics.tileShape)
        .overlay {
            ShellMetrics.tileShape.stroke(self.borderColor(for: resolved), lineWidth: self.borderWidth(for: resolved))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(resolved.accessibilityLabel)
        .accessibilityValue(resolved.accessibilityValue)
        .accessibilityIdentifier("dayHome.importEntry")
        .hoverEffect(.highlight)
    }

    private func glyphTint(for signal: HomeImportTileSignal) -> Color {
        switch signal {
        case .needsAttention: .red
        case .readyToReview, .sending, .checking: Color.solOrangeAdaptive
        case .waiting, .paused, .idle: .secondary
        }
    }

    private func wordColor(for signal: HomeImportTileSignal) -> Color {
        switch signal {
        case .needsAttention: .red
        case .readyToReview, .sending, .checking: Color.solOrangeAdaptive
        case .waiting, .paused, .idle: .secondary
        }
    }

    private func borderColor(for signal: HomeImportTileSignal) -> Color {
        switch signal {
        case .readyToReview: Color.solOrange.opacity(0.6)
        case .needsAttention: Color.red.opacity(0.45)
        case .idle, .waiting, .paused, .sending, .checking: Color.deckHairline
        }
    }

    private func borderWidth(for signal: HomeImportTileSignal) -> CGFloat {
        switch signal {
        case .readyToReview, .needsAttention: 1
        case .idle, .waiting, .paused, .sending, .checking: 0.5
        }
    }
}
