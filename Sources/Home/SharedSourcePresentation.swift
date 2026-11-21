// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

extension Source {
    var offersRemoteSourceCard: Bool {
        (kind == .obsidian || kind == .calendar) &&
            (state == .off || (state == .readyToSetUp && subtextOverride == nil))
    }
}

enum SharedSourceCopy {
    // SA1 and SA2 share a cardinal message.
    static func heading(_ count: Int) -> String { AppStrings.ios_sharedsources_heading(count) }
    static var alsoOn: String { AppStrings.ios_sharedsources_also() }

    // SA3 uses the device name; SA4 substitutes the vault name (if present).
    static func line(device: KnownSources.Device, entry: KnownSources.Entry, detail: Bool = false,
                     spoken: Bool = false, now: Date) -> String {
        join(fields(device: device, entry: entry, detail: detail, spoken: spoken, now: now), spoken: spoken)
    }

    private static func join(_ parts: [String], spoken: Bool) -> String {
        switch parts.count {
        case 3:
            return spoken ? AppStrings.ios_sharedsources_spokentriple(parts[0], parts[1], parts[2])
                : AppStrings.ios_sharedsources_triple(parts[0], parts[1], parts[2])
        case 2:
            return spoken ? AppStrings.ios_sharedsources_spokenpair(parts[0], parts[1])
                : AppStrings.ios_sharedsources_pair(parts[0], parts[1])
        default:
            return parts.first ?? ""
        }
    }

    /// On the tile a long device name gives way first: 19 characters, trimmed, then an ellipsis.
    static func tileName(_ name: String) -> String {
        guard name.count > 20 else { return name }
        return String(name.prefix(19)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The written line where it can run to more than one line (an `also on` value, a card line).
    /// A state or a time never splits, and the space before each separator holds, so a line breaks
    /// only after a separator or inside a long name, and never starts with one.
    static func wrappingLine(device: KnownSources.Device, entry: KnownSources.Entry, detail: Bool = false,
                             now: Date) -> String {
        let held = "\u{00A0}"
        let named = (detail ? entry.detail : device.display_label) != nil
        var parts = fields(device: device, entry: entry, detail: detail, now: now)
        for index in parts.indices where index > 0 || !named {
            parts[index] = parts[index].replacingOccurrences(of: " ", with: held)
        }
        return join(parts, spoken: false).replacingOccurrences(of: " · ", with: held + "· ")
    }

    static func fields(device: KnownSources.Device, entry: KnownSources.Entry, detail: Bool = false,
                       spoken: Bool = false, now: Date) -> [String] {
        var parts = [String]()
        if let name = detail ? entry.detail : device.display_label { parts.append(name) }
        if entry.state == "paused" { parts.append(SourceState.paused.label) }
        if entry.state == "needs_attention" { parts.append(SourceState.needsAttention.label) }
        if let time = entry.time(seen: device.device_last_seen_at) {
            let seconds = now.timeIntervalSince(time)
            if spoken, seconds >= 60, seconds < 3600 {
                parts.append(AppStrings.ios_about_relative_minute(Int(seconds / 60)))
            } else {
                parts.append(SourceIntakeFormat.relative(time, now: now, calendar: .current))
            }
        }
        return parts
    }
}

/// Keep state and time intact as the tile narrows. A separator belongs to the field before it.
struct SharedSourceTileLine: View {
    let device: KnownSources.Device
    let entry: KnownSources.Entry
    let now: Date

    var body: some View {
        let fields = SharedSourceCopy.fields(device: device, entry: entry, now: now)
        SharedSourceLineLayout {
            ForEach(fields.indices, id: \.self) { index in
                let field = fields[index]
                HStack(spacing: 0) {
                    if index == 0 {
                        Text(verbatim: SharedSourceCopy.tileName(field))
                            .lineLimit(1)
                    } else {
                        Text(verbatim: field).fixedSize()
                    }
                    if index < fields.count - 1 {
                        Text(verbatim: " ·").fixedSize()
                    }
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct SharedSourceLineLayout: Layout {
    private func positions(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            if x > 0 && x + ideal.width > width {
                x = 0
                y = height
            }
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            frames.append(frame)
            x = frame.maxX + 3
            height = max(height, frame.maxY)
        }
        return (frames, CGSize(width: frames.map(\.maxX).max() ?? 0, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (frames, _) = positions(subviews, width: bounds.width)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }
}

struct SharedSourceHeading: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.caption2)
                .accessibilityHidden(true)
            Text(SharedSourceCopy.heading(count))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

struct SharedSourceDetails: View {
    let source: Source
    var facts = false
    var setupInProgress = false
    @Environment(AppConfig.self) private var config
    @State private var now = Date()

    var body: some View {
        let devices = config.sharedSources.others(source.id)
        Group {
            if !setupInProgress, !devices.isEmpty {
                if source.offersRemoteSourceCard && !facts {
                    VStack(alignment: .leading, spacing: 12) {
                        SharedSourceHeading(count: devices.count)
                        ForEach(devices, id: \.cid) { device in
                            if device.cid != devices.first?.cid { Divider() }
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: glyph(device.device_type)).foregroundStyle(.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: device.display_label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    ForEach(device.sources.indices, id: \.self) { i in
                                        let entry = device.sources[i]
                                        let line = SharedSourceCopy.wrappingLine(device: device, entry: entry, detail: true, now: now)
                                        if !line.isEmpty {
                                            Text(verbatim: line).font(.footnote).foregroundStyle(.secondary)
                                                .accessibilityLabel(SharedSourceCopy.line(device: device, entry: entry, detail: true, spoken: true, now: now))
                                        }
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ShellMetrics.surfacePadding)
                    .background(Color.deckSurface, in: ShellMetrics.cardShape)
                    .overlay { ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5) }
                    .accessibilityIdentifier("sharedSources.card")
                    .task { await refreshNowPeriodically { now = Date() } }
                } else if facts && [.active, .paused, .needsAttention].contains(source.state) {
                    ForEach(devices, id: \.cid) { device in
                        if let entry = device.sources.first {
                            let label = device.cid == devices.first?.cid ? SharedSourceCopy.alsoOn : ""
                            LabeledContent(label, value: SharedSourceCopy.wrappingLine(device: device, entry: entry, now: now))
                                .accessibilityValue(SharedSourceCopy.line(device: device, entry: entry, spoken: true, now: now))
                        }
                    }
                    .task { await refreshNowPeriodically { now = Date() } }
                }
            }
        }
    }

    private func glyph(_ type: String?) -> String {
        switch type {
        case "tablet": "ipad"
        case "phone", "mobile": "iphone"
        case "laptop": "laptopcomputer"
        default: "desktopcomputer"
        }
    }
}
