// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Turning screen on or off goes through Apple's broadcast sheet, the only way iOS
/// starts or stops a broadcast. The primer that names Apple's button shows the first
/// time only; every later request opens Apple's sheet directly, in one tap.
private struct ScreencastStartFlow: ViewModifier {
    let request: Int
    @Environment(ScreencastManager.self) private var screencastManager
    @AppStorage(UserSettings.screencastPrimerSeenKey) private var primerSeen = false
    @State private var showingPrimer = false
    @State private var pickerOpenRequest = 0

    func body(content: Content) -> some View {
        content
            .background {
                // Never seen or tapped itself: it only opens Apple's sheet on request.
                ScreencastPickerView(openRequest: self.pickerOpenRequest) {
                    self.screencastManager.notePickerWillOpen()
                }
                .frame(width: 1, height: 1)
                .opacity(0.015)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .sheet(isPresented: self.$showingPrimer) {
                ScreencastPrimerSheet()
            }
            .onChange(of: self.request) { _, _ in
                if self.primerSeen {
                    self.pickerOpenRequest += 1
                } else {
                    self.showingPrimer = true
                }
            }
    }
}

extension View {
    /// Opens the screen flow each time `request` changes.
    func screencastStartFlow(request: Int) -> some View {
        self.modifier(ScreencastStartFlow(request: request))
    }
}
