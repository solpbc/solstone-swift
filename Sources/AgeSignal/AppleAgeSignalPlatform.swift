// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_AGE_SIGNAL
import DeclaredAgeRange
import Foundation
import PermissionKit
import StoreKit
import UIKit
import os

nonisolated private let ageSignalLog = Logger(subsystem: "app.solstone.swift", category: "age-signal")

/// Apple's Declared Age Range, PermissionKit and StoreKit, behind the launch check.
///
/// The age range Apple returns is reduced to a category inside `requestCategory` and goes no
/// further: it is not stored, logged or sent.
@available(iOS 26.2, *)
@MainActor
final class AppleAgeSignalPlatform: AgeSignalPlatform {
    /// The ages the rule turns on; Apple's answer can be no finer than these allow.
    static let ageGates = (13, 18)

    private struct NoPresenter: Error {}
    private struct Unverified: Error {}

    /// Before iOS 26.4 the parental-consent requirement arrives with the age answer itself.
    private var answerRequiresApproval = false

    func isEligible() async throws -> Bool {
        do {
            return try await Self.eligibility()
        } catch let error as AgeRangeService.Error where Self.settlesNothing(error) {
            return false
        }
    }

    func requestCategory() async throws -> AgeSignalCategory? {
        guard let presenter = Self.presenter() else { throw NoPresenter() }
        let response: AgeRangeService.Response
        do {
            response = try await AgeRangeService.shared.requestAgeRange(
                ageGates: Self.ageGates.0, Self.ageGates.1, in: presenter
            )
        } catch let error as AgeRangeService.Error where Self.settlesNothing(error) {
            return nil
        }
        switch response {
        case .declinedSharing:
            return nil
        case .sharing(let range):
            self.answerRequiresApproval = Self.controlsRequireApproval(range)
            return AgeSignalCategory(lowerBound: range.lowerBound, upperBound: range.upperBound)
        @unknown default:
            return nil
        }
    }

    func requiresParentalConsentForSignificantChange() async throws -> Bool {
        if #available(iOS 26.4, *) {
            do {
                return try await Self.parentalConsentRequired()
            } catch let error as AgeRangeService.Error where Self.settlesNothing(error) {
                return false
            }
        }
        return self.answerRequiresApproval
    }

    func currentRatingCode() async -> Int? {
        await AppStore.ageRatingCode
    }

    func installedThisBuild() async throws -> Bool {
        // An unverified record is an error, which the check treats as no signal.
        guard case .verified(let transaction) = try await AppTransaction.shared else { throw Unverified() }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return transaction.originalAppVersion == build
    }

    func askParent() async throws {
        guard let presenter = Self.presenter() else { throw NoPresenter() }
        let topic = SignificantAppUpdateTopic(description: AppStrings.ios_app_agesignalupdatedescription())
        try await AskCenter.shared.ask(PermissionQuestion(significantAppUpdateTopic: topic), in: presenter)
    }

    func parentAnswers() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await response in AskCenter.shared.responses(for: SignificantAppUpdateTopic.self) {
                    continuation.yield(response.choice.answer == .approval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // The service is not Sendable, so its nonisolated properties are read off the main actor.
    @concurrent
    private nonisolated static func eligibility() async throws -> Bool {
        try await AgeRangeService.shared.isEligibleForAgeFeatures
    }

    @available(iOS 26.4, *)
    @concurrent
    private nonisolated static func parentalConsentRequired() async throws -> Bool {
        try await AgeRangeService.shared.requiredRegulatoryFeatures.contains(.significantAppChangeRequiresParentalConsent)
    }

    /// Answers that retrying cannot change: the system has nothing for this person or refused
    /// the request.
    private static func settlesNothing(_ error: AgeRangeService.Error) -> Bool {
        if error == .invalidRequest {
            // A build without the entitlement, or a request the system refuses: say so, since
            // the check is then doing nothing. Carries no age.
            ageSignalLog.error("age range request refused as invalid")
            return true
        }
        if error == .notAvailable { return true }
        if #available(iOS 27.0, *) {
            return error == .invalidAccount || error == .declinedOnboarding
        }
        return false
    }

    private static func controlsRequireApproval(_ range: AgeRangeService.AgeRange) -> Bool {
        if #available(iOS 26.4, *) { return false }
        return range.activeParentalControls.contains(.significantAppChangeApprovalRequired)
    }

    private static func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
