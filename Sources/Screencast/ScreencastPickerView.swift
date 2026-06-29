// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ReplayKit
import SwiftUI

struct ScreencastPickerView: UIViewRepresentable {
    nonisolated static let preferredExtension = "app.solstone.swift.broadcast"

    let onWillOpen: @MainActor @Sendable () -> Void

    init(onWillOpen: @escaping @MainActor @Sendable () -> Void) {
        self.onWillOpen = onWillOpen
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWillOpen: self.onWillOpen)
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = Self.preferredExtension
        picker.showsMicrophoneButton = false
        context.coordinator.attach(to: picker)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = Self.preferredExtension
        uiView.showsMicrophoneButton = false
        context.coordinator.attach(to: uiView)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let onWillOpen: @MainActor @Sendable () -> Void
        private weak var attachedButton: UIButton?

        init(onWillOpen: @escaping @MainActor @Sendable () -> Void) {
            self.onWillOpen = onWillOpen
        }

        func attach(to picker: RPSystemBroadcastPickerView) {
            guard let button = self.broadcastButton(in: picker),
                  button !== self.attachedButton
            else { return }
            self.attachedButton?.removeTarget(self, action: #selector(self.handleTap), for: .touchUpInside)
            button.addTarget(self, action: #selector(self.handleTap), for: .touchUpInside)
            self.attachedButton = button
        }

        @objc private func handleTap() {
            self.onWillOpen()
        }

        private func broadcastButton(in picker: RPSystemBroadcastPickerView) -> UIButton? {
            for subview in picker.subviews {
                if let button = subview as? UIButton {
                    return button
                }
            }
            return nil
        }
    }
}
