// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import WebRTC
import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "voice")

final class WebRTCManager: NSObject, WebRTCConnecting {
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var eventContinuation: AsyncStream<DataChannelEvent>.Continuation?

    func connect(ephemeralKey: String) async throws -> (callId: String, events: AsyncStream<DataChannelEvent>) {
        self.disconnect()

        let (stream, continuation) = AsyncStream<DataChannelEvent>.makeStream()
        self.eventContinuation = continuation

        let factory = RTCPeerConnectionFactory()

        let config = RTCConfiguration()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            self.eventContinuation?.finish()
            self.eventContinuation = nil
            throw WebRTCError.peerConnectionFailed
        }
        self.peerConnection = peerConnection

        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "echoCancellation": "true",
                "autoGainControl": "true",
                "noiseSuppression": "true",
                "highpassFilter": "true",
            ]
        )
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection.add(audioTrack, streamIds: ["stream0"])

        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        guard let dataChannel = peerConnection.dataChannel(forLabel: "oai-events", configuration: dataChannelConfig) else {
            self.peerConnection = nil
            self.eventContinuation?.finish()
            self.eventContinuation = nil
            throw WebRTCError.dataChannelFailed
        }
        dataChannel.delegate = self
        self.dataChannel = dataChannel

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        let offer = try await peerConnection.offer(for: offerConstraints)
        try await peerConnection.setLocalDescription(offer)

        let (answerSdp, callId) = try await self.exchangeSdp(offer: offer.sdp, ephemeralKey: ephemeralKey)

        let answer = RTCSessionDescription(type: .answer, sdp: answerSdp)
        try await peerConnection.setRemoteDescription(answer)

        self.configureAudioSession()

        return (callId: callId, events: stream)
    }

    func disconnect() {
        self.dataChannel?.close()
        self.dataChannel = nil
        self.peerConnection?.close()
        self.peerConnection = nil
        self.eventContinuation?.finish()
        self.eventContinuation = nil
    }
}

private extension WebRTCManager {
    func exchangeSdp(offer sdp: String, ephemeralKey: String) async throws -> (answerSdp: String, callId: String) {
        guard let url = URL(string: "https://api.openai.com/v1/realtime/calls") else {
            throw WebRTCError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(sdp.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw WebRTCError.sdpExchangeFailed(status)
        }

        guard let answerSdp = String(data: data, encoding: .utf8), !answerSdp.isEmpty else {
            throw WebRTCError.invalidSdpResponse
        }

        guard let location = httpResponse.value(forHTTPHeaderField: "Location"), !location.isEmpty else {
            throw WebRTCError.missingCallId
        }

        let callId: String
        if let url = URL(string: location), let lastPathComponent = url.pathComponents.last, !lastPathComponent.isEmpty, lastPathComponent != "/" {
            callId = lastPathComponent
        } else {
            callId = location
        }

        return (answerSdp: answerSdp, callId: callId)
    }

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            log.error("[solstone-swift] audio session config failed: \(String(describing: error))")
        }
    }

    func handleDataChannelMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return
        }

        switch type {
        case "output_audio_buffer.started":
            self.eventContinuation?.yield(.modelSpeakingStarted)
        case "output_audio_buffer.stopped":
            self.eventContinuation?.yield(.modelSpeakingStopped)
        case "input_audio_buffer.speech_started":
            self.eventContinuation?.yield(.userSpeechStarted)
        case "input_audio_buffer.speech_stopped":
            self.eventContinuation?.yield(.userSpeechStopped)
        default:
            break
        }
    }

    enum WebRTCError: Error {
        case peerConnectionFailed
        case dataChannelFailed
        case invalidEndpoint
        case sdpExchangeFailed(Int)
        case invalidSdpResponse
        case missingCallId
    }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .disconnected || newState == .failed {
            Task { @MainActor [weak self] in
                self?.eventContinuation?.yield(.disconnected)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension WebRTCManager: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            self?.handleDataChannelMessage(data)
        }
    }
}
