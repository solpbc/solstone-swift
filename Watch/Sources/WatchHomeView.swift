// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct WatchHomeView: View {
    let model: WatchSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("solstone")
                .font(.headline)
            Text("ready")
                .font(.subheadline)
            Text(self.model.isReachable ? "iphone: reachable" : "iphone: not reachable")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
