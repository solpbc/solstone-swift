// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

nonisolated enum HomeSourceTileControl: Equatable {
    case none
    case toggle
}

struct HomeSourceTile: View {
    let source: Source
    let route: SourceRoute
    let control: HomeSourceTileControl
    var isOn: Binding<Bool> = .constant(false)
    var presentsScreencastPicker: Bool = false
    var onScreencastWillOpen: @MainActor @Sendable () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if self.dynamicTypeSize.isAccessibilitySize {
                self.verticalBody
            } else {
                self.horizontalBody
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: ConcentricRectangle())
        .accessibilityElement(children: .contain)
    }

    private var horizontalBody: some View {
        HStack(alignment: .top, spacing: 0) {
            self.cardLink
            if self.control == .toggle {
                self.switchSlot
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 12)
            }
        }
    }

    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.cardLink
            if self.control == .toggle {
                self.switchSlot
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var cardLink: some View {
        NavigationLink(value: ShellDestination.source(self.route)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(self.source.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    HomeSourceStateDot(state: self.source.state)
                }
                Text(self.source.state.label)
                    .font(.subheadline)
                    .foregroundStyle(self.stateLabelColor)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(14)
            .contentShape(ConcentricRectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(self.source.displayName)
        .accessibilityValue(homeSourceTileAccessibilityFacts(for: self.source.state).value)
        .accessibilityIdentifier("dayHome.tile.\(self.source.id)")
    }

    @ViewBuilder
    private var switchSlot: some View {
        ZStack {
            Toggle("", isOn: self.isOn)
                .labelsHidden()
                .allowsHitTesting(!self.presentsScreencastPicker)

            if self.presentsScreencastPicker {
                ScreencastPickerView(onWillOpen: self.onScreencastWillOpen)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityLabel(self.source.displayName)
        .accessibilityValue(homeSourceTileAccessibilityFacts(for: self.source.state).value)
    }

    private var stateLabelColor: Color {
        switch self.source.state {
        case .readyToSetUp:
            self.colorScheme == .dark ? .primary : .textOrangeAA
        case .off, .enrolling, .checking, .active, .paused, .needsAttention:
            .secondary
        }
    }
}

struct HomeAddMoreTile: View {
    var badgeVisible: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .overlay(alignment: .topTrailing) {
                        if self.badgeVisible {
                            Circle()
                                .fill(Color.solOrange)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -4)
                        }
                    }
                Text("dev-copy: add more")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(14)
            .contentShape(ConcentricRectangle())
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemGroupedBackground), in: ConcentricRectangle())
        .contentShape(ConcentricRectangle())
        .simultaneousGesture(TapGesture().onEnded { self.onTap() })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("dev-copy: add more")
        .accessibilityIdentifier("dayHome.sourcesEntry")
        .accessibilityAction {
            self.onTap()
        }
    }
}
