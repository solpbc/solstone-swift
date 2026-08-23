// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Wave 3 iPad split-view stub: self-naming so an accidental iPhone push is visible. Not dead code.
struct ShellPaneStub: View {
    let name: String
    let identifier: String

    var body: some View {
        Text(self.name)
            .navigationTitle(self.name)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("shell.stub.\(self.identifier)")
    }
}
