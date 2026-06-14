// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

struct ManualCodeEntryView: View {
    private enum ManualCodeError: Error {
        case invalidFormat
        case invalidAddress
        case relayAddress
    }

    let onSubmit: @MainActor (String, URL) -> Void

    @State private var code = ""
    @State private var homeAddress = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("pairing code", text: self.$code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: self.code) { _, newValue in
                    self.code = Self.formatted(newValue)
                }

            TextField("http://192.168.1.44:5015", text: self.$homeAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Button("pair with code") {
                self.submit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!Self.isValid(self.code))
            .frame(maxWidth: .infinity, minHeight: 44)

            if let errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Pairing error: \(errorMessage)")
            }
        }
    }

    private func submit() {
        guard Self.isValid(self.code) else {
            self.errorMessage = Self.message(for: .invalidFormat)
            return
        }

        do {
            let homeURL = try Self.homeURL(from: self.homeAddress)
            self.errorMessage = nil
            self.onSubmit(self.code, homeURL)
        } catch let error as ManualCodeError {
            self.errorMessage = Self.message(for: error)
        } catch {
            self.errorMessage = Self.message(for: .invalidAddress)
        }
    }

    static func homeURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ManualCodeError.invalidAddress
        }

        let raw = trimmed.range(of: "://") == nil ? "http://\(trimmed)" : trimmed
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw ManualCodeError.invalidAddress
        }

        let relayHost = SPLPairingConstants.relayEndpoint.host?.lowercased()
        guard host != relayHost, host != "link.solpbc.org" else {
            throw ManualCodeError.relayAddress
        }
        return url
    }

    private static func formatted(_ value: String) -> String {
        String(value.uppercased().filter { isAllowed($0) }.prefix(8))
    }

    private static func isValid(_ value: String) -> Bool {
        value.count == 8 && value.allSatisfy(isAllowed)
    }

    private static func isAllowed(_ character: Character) -> Bool {
        "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(character)
    }

    private static func message(for error: ManualCodeError) -> String {
        switch error {
        case .invalidFormat:
            "enter the 8-character pairing code."
        case .invalidAddress:
            "enter the network address shown by your solstone."
        case .relayAddress:
            "paste the pairing link for remote pairing."
        }
    }
}
