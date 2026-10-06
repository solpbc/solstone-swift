// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The initial question belongs to the admitted app shell. The settings pane
/// remains the durable way to reopen an unanswered choice.
struct DeviceMigrationInitialPrompt: ViewModifier {
    @Environment(DeviceMigrationOwnerModel.self) private var owner
    @Environment(ShellNavModel.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation: DeviceMigrationChoicePresentation?
    @State private var isMigration = false

    func body(content: Content) -> some View {
        content
            .task { self.presentIfNeeded() }
            .onChange(of: self.owner.ownerSurfaceRevision) { _, _ in self.presentIfNeeded() }
            .onChange(of: self.scenePhase) { _, phase in
                if phase == .active { self.presentIfNeeded() }
            }
            .confirmationDialog(
                self.isMigration ? Text("migration.choice.title") : Text("migration.replace_offer.title"),
                isPresented: Binding(
                    get: { self.presentation != nil },
                    set: { if !$0 { self.presentation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let context = self.presentation, self.isMigration {
                    Button("migration.choice.same", role: .destructive) {
                        Task { await self.owner.submitMigrationChoice(.sameDevice, presentedContext: context) }
                    }
                    .accessibilityIdentifier("device.migration.initial.same")
                    Button("migration.choice.new") {
                        Task { await self.owner.submitMigrationChoice(.newDevice, presentedContext: context) }
                    }
                    .accessibilityIdentifier("device.migration.initial.new")
                    Button("migration.choice.defer", role: .cancel) {}
                } else if let context = self.presentation {
                    Button("migration.replace_offer.pick") {
                        guard self.owner.freshPairOfferPresentation() == context else { return }
                        self.navigation.selectFromDeck(.shelfThisDevice)
                    }
                    Button("migration.replace_offer.keep") {
                        self.owner.keepBothFromFreshPairOffer(presentedContext: context)
                    }
                    Button("migration.replace_offer.defer", role: .cancel) {}
                }
            } message: {
                if self.isMigration {
                    Text("migration.choice.body_fallback")
                } else {
                    Text("migration.replace_offer.body")
                }
            }
    }

    private func presentIfNeeded() {
        guard self.scenePhase == .active, self.presentation == nil else { return }
        if self.owner.shouldPresentMigrationChoice,
           let context = self.owner.migrationChoicePresentation(),
           self.owner.markMigrationChoicePresented(context) {
            self.isMigration = true
            self.presentation = context
        } else if self.owner.shouldPresentFreshPairOffer,
                  let context = self.owner.freshPairOfferPresentation(),
                  self.owner.markFreshPairOfferPresented(operationID: context.operationID) {
            self.isMigration = false
            self.presentation = context
        }
    }
}
