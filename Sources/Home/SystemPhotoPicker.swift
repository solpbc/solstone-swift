// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import PhotosUI
import SwiftUI

/// The system photo picker. It runs out of process and is built without a photo library, so
/// choosing photos asks for no Photos permission, grants the app no library access and carries
/// no asset identifiers: each choice arrives as an ordinary item, the way the share sheet hands one over.
struct SystemPhotoPicker: UIViewControllerRepresentable {
    let onFinish: @MainActor ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.onFinish = self.onFinish
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: self.onFinish)
    }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onFinish: @MainActor ([NSItemProvider]) -> Void

        init(onFinish: @escaping @MainActor ([NSItemProvider]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            self.onFinish(results.map(\.itemProvider))
        }
    }
}
