// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct ObserverCaptureControlValueProvider: ControlValueProvider {
    var previewValue: ObserverCaptureControlValue {
        ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .unknownState)
    }

    func currentValue() async throws -> ObserverCaptureControlValue {
        let mirror = AppGroupMirror()
        let snapshot = mirror.snapshot()
        let permission = snapshot?.microphonePermission ?? .undetermined
        return ObserverCaptureControlState.value(snapshot: snapshot, permission: permission)
    }
}

struct ObserverCaptureControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: observerCaptureControlKind, provider: ObserverCaptureControlValueProvider()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: ObserverCaptureIntent()) {
                Label("audio", systemImage: "waveform")
                    .controlWidgetStatus(Text(value.status?.text ?? ""))
            }
            .privacySensitive()
            .disabled(value.isUnavailable)
        }
        .displayName("audio")
        .description("turn audio on and off.")
    }
}
