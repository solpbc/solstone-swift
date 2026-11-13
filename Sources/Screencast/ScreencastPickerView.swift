// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ReplayKit
import SwiftUI

struct ScreencastPickerView: UIViewRepresentable {
    nonisolated static let preferredExtension = "app.solstone.swift.broadcast"

    /// Each change opens Apple's sheet as if the picker's own button were tapped, so a
    /// control elsewhere (the home switch, the detail page's button) can open it in one tap.
    let openRequest: Int
    let onWillOpen: @MainActor @Sendable () -> Void

    init(openRequest: Int = 0, onWillOpen: @escaping @MainActor @Sendable () -> Void) {
        self.openRequest = openRequest
        self.onWillOpen = onWillOpen
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(openRequest: self.openRequest, onWillOpen: self.onWillOpen)
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = Self.preferredExtension
        context.coordinator.attach(to: picker)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = Self.preferredExtension
        context.coordinator.attach(to: uiView)
        context.coordinator.openIfRequested(self.openRequest, picker: uiView)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let onWillOpen: @MainActor @Sendable () -> Void
        private weak var attachedButton: UIButton?
        private var handledOpenRequest: Int

        init(openRequest: Int, onWillOpen: @escaping @MainActor @Sendable () -> Void) {
            self.handledOpenRequest = openRequest
            self.onWillOpen = onWillOpen
        }

        func openIfRequested(_ request: Int, picker: RPSystemBroadcastPickerView) {
            guard request != self.handledOpenRequest else { return }
            self.handledOpenRequest = request
            // Out of the view update: presenting from inside one is undefined.
            Task { @MainActor [weak self, weak picker] in
                guard let self, let picker else { return }
                self.attach(to: picker)
                self.attachedButton?.sendActions(for: .touchUpInside)
            }
        }

        func attach(to picker: RPSystemBroadcastPickerView) {
            guard let button = self.broadcastButton(in: picker) else { return }
            button.frame = picker.bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            guard button !== self.attachedButton else { return }
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
