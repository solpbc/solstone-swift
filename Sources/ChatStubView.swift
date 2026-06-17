// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ChatStubView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Text(SourceVocabulary.chatStubBody)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .accessibilityIdentifier("chatStub.surface")
            .navigationTitle("ask")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
