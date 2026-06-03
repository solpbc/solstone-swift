// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct LocationSourceDetailView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if self.locationManager.sourceState == .off {
                    LocationEnrollmentContent(manager: self.locationManager)
                } else {
                    self.stateContent
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(LocationVocabulary.sourceDisplayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension LocationSourceDetailView {
    @ViewBuilder
    var stateContent: some View {
        let sourceState = self.locationManager.sourceState

        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: sourceState.symbol)
                    Text(sourceState.label)
                }
                .font(.headline)

                Text(sourceState.subtext(activeSubtext: LocationVocabulary.activeSubtext))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LocationEnrollmentContent: View {
    @State private var coordinator: LocationEnrollmentCoordinator

    private let presentation = LocationEnrollmentPresentation.current

    init(manager: LocationManager) {
        self._coordinator = State(initialValue: LocationEnrollmentCoordinator(manager: manager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.valueBlock

            SourceDetailBlock(title: self.presentation.tierDialHeader) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(self.presentation.tierDialSubhead)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(LocationTier.allCases, id: \.self) { tier in
                        self.tierOption(tier)
                    }

                    Text(self.presentation.batteryHonesty)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(self.presentation.turnOnLocation) {
                        Task {
                            await self.coordinator.confirm()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(self.coordinator.showingPrimer)
                }
            }

            if self.coordinator.showingPrimer {
                SourceDetailBlock(title: self.presentation.alwaysPrimerHeader) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(self.presentation.alwaysBackgroundPrimer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button(self.presentation.alwaysPrimerContinue) {
                            Task {
                                await self.coordinator.acknowledgePrimer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
        }
    }
}

private extension LocationEnrollmentContent {
    var valueBlock: some View {
        Text(self.presentation.preEnrollmentValue)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func tierOption(_ tier: LocationTier) -> some View {
        let isSelected = self.coordinator.selectedTier == tier
        return Button {
            self.coordinator.selectTier(tier)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.solOrangeAccessible : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(tier.label)
                            .font(.headline)

                        if tier == .balanced {
                            Text(LocationVocabulary.balancedDefaultBadge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.solOrangeAccessible)
                        }
                    }

                    Text(tier.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.solOrangeAccessible : Color(.separator), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
