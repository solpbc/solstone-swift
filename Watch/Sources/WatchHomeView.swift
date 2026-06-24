// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct WatchHomeView: View {
    let model: WatchSessionModel
    let captureModel: WatchCaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("solstone")
                .font(.headline)
            Text(self.captureModel.primaryText)
                .font(.subheadline)
            Text(self.captureModel.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(self.model.isReachable ? "iphone: reachable" : "iphone: not reachable")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(self.captureModel.actionText) {
                if self.captureModel.isRunning {
                    self.captureModel.stop()
                } else {
                    self.captureModel.start()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
