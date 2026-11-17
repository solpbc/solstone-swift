// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The initial question belongs to the admitted app shell. The settings pane
/// remains the durable way to reopen an unanswered choice.
struct DeviceMigrationInitialPrompt: ViewModifier {
    let presentationBlocked: Bool
    @Environment(DeviceMigrationOwnerModel.self) private var owner
    @Environment(ShellNavModel.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation: DeviceMigrationChoicePresentation?
    @State private var isMigration = false

    func body(content: Content) -> some View {
        content
            .task { self.presentIfNeeded() }
            .onChange(of: self.presentationBlocked) { _, _ in self.presentIfNeeded() }
            .onChange(of: self.owner.ownerSurfaceRevision) { _, _ in self.presentIfNeeded() }
            .onChange(of: self.scenePhase) { _, phase in
                if phase == .active { self.presentIfNeeded() }
            }
            .confirmationDialog(
                self.isMigration ? Text(AppStrings.ios_lookup_migration_choice_title()) : Text(AppStrings.ios_lookup_migration_replace_offer_title()),
                isPresented: Binding(
                    get: { self.presentation != nil },
                    set: { if !$0 { self.presentation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let context = self.presentation, self.isMigration {
                    Button(AppStrings.ios_lookup_migration_choice_same(), role: .destructive) {
                        Task { await self.owner.submitMigrationChoice(.sameDevice, presentedContext: context) }
                    }
                    .accessibilityIdentifier("device.migration.initial.same")
                    Button(AppStrings.ios_lookup_migration_choice_new()) {
                        Task { await self.owner.submitMigrationChoice(.newDevice, presentedContext: context) }
                    }
                    .accessibilityIdentifier("device.migration.initial.new")
                    Button(AppStrings.ios_lookup_migration_choice_defer(), role: .cancel) {}
                } else if let context = self.presentation {
                    Button(AppStrings.ios_lookup_migration_replace_offer_pick()) {
                        guard self.owner.freshPairOfferPresentation() == context else { return }
                        self.navigation.selectFromDeck(.shelfThisDevice)
                    }
                    Button(AppStrings.ios_lookup_migration_replace_offer_keep()) {
                        self.owner.keepBothFromFreshPairOffer(presentedContext: context)
                    }
                    Button(AppStrings.ios_lookup_migration_replace_offer_defer(), role: .cancel) {}
                }
            } message: {
                if self.isMigration {
                    Text(AppStrings.ios_lookup_migration_choice_body_fallback())
                } else {
                    Text(AppStrings.ios_lookup_migration_replace_offer_body())
                }
            }
    }

    private func presentIfNeeded() {
        // A journal link queued through pairing owns the first presentation.
        // Keep the offer unshown until that journal sheet has been dismissed.
        guard !self.presentationBlocked, self.scenePhase == .active, self.presentation == nil else { return }
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
