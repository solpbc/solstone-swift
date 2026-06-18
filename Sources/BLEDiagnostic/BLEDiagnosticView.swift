// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreBluetooth
import Foundation
import SwiftUI

struct BLEDiagnosticView: View {
    @State private var manager = BLEDiagnosticManager()

    var body: some View {
        List {
            self.scanSection
            self.deviceInfoSection
            self.gattSection
            self.audioSection
            self.logSection
        }
        .navigationTitle("omi ble harness")
    }

    private var scanSection: some View {
        Section("scan & connect") {
            LabeledContent("state", value: self.manager.stateLine)
            Toggle("scan", isOn: Binding(
                get: { self.manager.isScanning },
                set: { isScanning in
                    if isScanning {
                        self.manager.startScan()
                    } else {
                        self.manager.stopScan()
                    }
                }
            ))
            .disabled(self.manager.managerState != .poweredOn)

            Toggle("all devices", isOn: Binding(
                get: { self.manager.scanAllDevices },
                set: { self.manager.scanAllDevices = $0 }
            ))
            .disabled(self.manager.isScanning)

            if self.manager.discovered.isEmpty {
                ContentUnavailableView {
                    Label("no devices yet", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("tap scan to search nearby.")
                }
            } else {
                ForEach(self.manager.discovered) { peripheral in
                    Button {
                        self.manager.connect(peripheral.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(peripheral.name ?? "(unnamed)")
                                .font(.headline)
                            Text(peripheral.id.uuidString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("signal (RSSI) \(peripheral.rssi)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !peripheral.advertisedServiceUUIDs.isEmpty {
                                Text(peripheral.advertisedServiceUUIDs.map(BLEDiagnosticUUIDs.displayName).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .hoverEffect(.highlight)
                }
            }

            if self.manager.connectionState == .connected {
                LabeledContent("connected", value: self.manager.connectedPeripheralName ?? "(unnamed)")
                LabeledContent("connection", value: self.manager.connectionState.displayString)
                Button("disconnect") {
                    self.manager.disconnect()
                }
                .hoverEffect(.highlight)
            } else {
                LabeledContent("connection", value: self.manager.connectionState.displayString)
            }
        }
    }

    private var deviceInfoSection: some View {
        Section("device info & battery") {
            VStack(alignment: .leading, spacing: 4) {
                Text("firmware revision")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                self.readStateValue(self.manager.firmware) { $0 }
                    .font(.headline)
            }

            LabeledContent("manufacturer") {
                self.readStateValue(self.manager.manufacturer) { $0 }
            }
            LabeledContent("model") {
                self.readStateValue(self.manager.model) { $0 }
            }
            LabeledContent("hardware revision") {
                self.readStateValue(self.manager.hardwareRevision) { $0 }
            }
            LabeledContent("battery") {
                self.readStateValue(self.manager.battery) { "\($0)%" }
            }

            Button("re-read") {
                self.manager.readDeviceInfo()
                self.manager.readBattery()
            }
            .disabled(self.manager.connectionState != .connected)
            .hoverEffect(.highlight)
        }
    }

    private var gattSection: some View {
        Section("raw gatt explorer") {
            if self.manager.services.isEmpty {
                ContentUnavailableView {
                    Label("no services yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("connect a device to inspect services.")
                }
            } else {
                ForEach(self.manager.services) { service in
                    DisclosureGroup {
                        if service.characteristics.isEmpty {
                            Text("no characteristics yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(service.characteristics) { characteristic in
                                self.characteristicRow(characteristic)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.displayName)
                                .font(.headline)
                            Text(service.uuid)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var audioSection: some View {
        Section("codec & live audio") {
            if self.manager.connectionState != .connected {
                ContentUnavailableView {
                    Label("not connected", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("connect a device to inspect live audio.")
                }
            } else {
                LabeledContent("codec") {
                    self.readStateValue(self.manager.codec) { info in
                        "\(info.label) (raw \(info.rawByte))"
                    }
                }

                Button("re-read codec") {
                    self.manager.readCodec()
                }
                .hoverEffect(.highlight)

                if self.manager.isAudioSubscribed {
                    Button("unsubscribe") {
                        self.manager.unsubscribeAudio()
                    }
                    .hoverEffect(.highlight)

                    LabeledContent("packets", value: "\(self.manager.audioPackets)")
                    LabeledContent("frames", value: "\(self.manager.audioFrames)")
                    LabeledContent("decode ok", value: "\(self.manager.audioDecodeOK)")
                    LabeledContent("decode err", value: "\(self.manager.audioDecodeErrors)")
                    LabeledContent("gaps", value: "\(self.manager.audioGaps)")
                    LabeledContent("out of order", value: "\(self.manager.audioOutOfOrder)")
                    LabeledContent("malformed", value: "\(self.manager.audioMalformed)")
                    LabeledContent("markers", value: "\(self.manager.audioMarkers)")
                    LabeledContent("last marker") {
                        if let lastMarkerDate = self.manager.lastMarkerDate {
                            Text(lastMarkerDate, style: .time)
                        } else {
                            Text("none")
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("rate", value: self.kbpsText(self.manager.audioThroughputKBps))
                    LabeledContent("buffer", value: self.secondsText(self.manager.bufferedSeconds))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("level")
                            Spacer()
                            Text(self.percentText(self.manager.audioLevel))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: self.manager.audioLevel, total: 1)
                    }

                    Button("save last 10s") {
                        self.manager.saveAudioWindow()
                    }
                    .disabled(self.manager.bufferedSeconds <= 0)
                    .hoverEffect(.highlight)

                    if let audioShareURL = self.manager.audioShareURL {
                        ShareLink(item: audioShareURL) {
                            Label("share wav", systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Button("subscribe") {
                        self.manager.subscribeAudio()
                    }
                    .disabled(!self.manager.canSubscribeAudio)
                    .hoverEffect(.highlight)
                }
            }
        }
    }

    private var logSection: some View {
        Section {
            if self.manager.log.entries.isEmpty {
                ContentUnavailableView {
                    Label("no ble events yet", systemImage: "clock")
                } description: {
                    Text("events appear as the harness runs.")
                }
            } else {
                ForEach(self.manager.log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.severity.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(self.color(for: entry.severity))
                            Text(entry.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.subheadline)
                        if let hex = entry.hex {
                            Text(hex)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("log console")
        } footer: {
            HStack {
                Button("clear") {
                    self.manager.clearLog()
                }
                .disabled(self.manager.log.entries.isEmpty)

                ShareLink(item: self.manager.logSnapshot()) {
                    Label("export", systemImage: "square.and.arrow.up")
                }
                .disabled(self.manager.log.entries.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func characteristicRow(_ characteristic: BLECharacteristicNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(characteristic.displayName)
                .font(.subheadline.weight(.semibold))
            Text(characteristic.uuid)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !characteristic.propertyFlags.isEmpty {
                Text(characteristic.propertyFlags.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let latestHex = characteristic.latestHex {
                Text(latestHex)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let latestASCII = characteristic.latestASCII {
                Text(latestASCII)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                if characteristic.isReadable {
                    Button("read") {
                        self.manager.read(characteristic: characteristic)
                    }
                }
                if characteristic.isNotifiable {
                    Button(characteristic.isNotifying ? "stop notify" : "notify") {
                        self.manager.setNotify(characteristic, enabled: !characteristic.isNotifying)
                    }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func readStateValue<Value: Equatable>(
        _ state: BLEReadState<Value>,
        valueText: (Value) -> String
    ) -> some View {
        switch state {
        case .value(let value):
            Text(valueText(value))
        case .notRead:
            Text(state.placeholderText ?? "")
                .foregroundStyle(.secondary)
        case .unavailable:
            Text(state.placeholderText ?? "")
                .foregroundStyle(.red)
        }
    }

    private func color(for severity: BLELogSeverity) -> Color {
        switch severity {
        case .info:
            .secondary
        case .warn:
            .orange
        case .error:
            .red
        }
    }

    private func kbpsText(_ value: Double) -> String {
        "\(String(format: "%.1f", value)) kb/s"
    }

    private func secondsText(_ value: Double) -> String {
        "\(String(format: "%.1f", value))s"
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
