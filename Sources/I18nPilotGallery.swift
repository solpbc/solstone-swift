// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import SwiftUI

struct I18nPilotGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(PilotCopy.resources(locale: Locale(identifier:"en-XA"), bundle:.main).enumerated()), id: \.offset) { index, resource in
                    Text(resource)
                        .accessibilityIdentifier("i18n-pilot.\(index)")
                }
            }.padding()
        }
        .environment(\.locale, Locale(identifier: "en-XA"))
        .accessibilityIdentifier("i18n-pilot.gallery")
    }
}
#endif
