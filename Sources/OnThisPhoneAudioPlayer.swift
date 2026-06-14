// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Observation
import SwiftUI

@MainActor
protocol AudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    func play() throws
    func pause()
    func seek(to time: TimeInterval)
}

enum AudioPlaybackError: Error, Equatable, Sendable {
    case playbackFailed
}

@MainActor
final class AVAudioPlayerAdapter: NSObject, AudioPlaying {
    private let player: AVAudioPlayer

    init(url: URL) throws {
        self.player = try AVAudioPlayer(contentsOf: url)
        super.init()
        self.player.prepareToPlay()
    }

    var isPlaying: Bool {
        self.player.isPlaying
    }

    var currentTime: TimeInterval {
        get { self.player.currentTime }
        set { self.player.currentTime = newValue }
    }

    var duration: TimeInterval {
        self.player.duration
    }

    func play() throws {
        guard self.player.play() else {
            throw AudioPlaybackError.playbackFailed
        }
    }

    func pause() {
        self.player.pause()
    }

    func seek(to time: TimeInterval) {
        self.player.currentTime = time
    }
}

typealias AudioPlaybackTickProvider = @MainActor @Sendable () -> AsyncStream<Void>

@MainActor
@Observable
final class AudioPlaybackModel {
    private(set) var isPlaying: Bool
    private(set) var elapsed: TimeInterval
    private(set) var duration: TimeInterval

    var progressFraction: Double {
        get {
            guard self.duration > 0 else { return 0 }
            return min(max(self.elapsed / self.duration, 0), 1)
        }
        set {
            guard self.duration > 0 else { return }
            let clamped = min(max(newValue, 0), 1)
            self.seek(to: self.duration * clamped)
        }
    }

    @ObservationIgnored private let player: any AudioPlaying
    @ObservationIgnored private let session: any ObserverAudioSession
    @ObservationIgnored private let ticks: AudioPlaybackTickProvider
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var savedCategory: AVAudioSession.Category?

    init(
        player: any AudioPlaying,
        session: any ObserverAudioSession,
        ticks: @escaping AudioPlaybackTickProvider = AudioPlaybackModel.defaultTicks
    ) {
        self.player = player
        self.session = session
        self.ticks = ticks
        self.isPlaying = player.isPlaying
        self.elapsed = max(player.currentTime, 0)
        self.duration = max(player.duration, 0)
    }

    convenience init(
        url: URL,
        session: any ObserverAudioSession = AVAudioSession.sharedInstance(),
        ticks: @escaping AudioPlaybackTickProvider = AudioPlaybackModel.defaultTicks
    ) throws {
        try self.init(
            player: AVAudioPlayerAdapter(url: url),
            session: session,
            ticks: ticks
        )
    }

    static func defaultTicks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func play() throws {
        guard !self.isPlaying else { return }
        if self.duration > 0, self.elapsed >= self.duration {
            self.seek(to: 0)
        }

        do {
            if self.savedCategory == nil {
                self.savedCategory = self.session.category
            }
            try self.session.setCategory(.playback, mode: .default, options: [])
            try self.session.setActive(true, options: [])
            try self.player.play()
            self.isPlaying = true
            self.refreshFromPlayer()
            self.startTicks()
        } catch {
            self.player.pause()
            self.isPlaying = false
            self.stopTicks()
            self.restoreSessionIfNeeded()
            throw error
        }
    }

    func pause() {
        if self.isPlaying {
            self.player.pause()
        }
        self.isPlaying = false
        self.stopTicks()
        self.refreshPositionOnly()
        self.restoreSessionIfNeeded()
    }

    func stopForDisappear() {
        self.pause()
    }

    func seek(to time: TimeInterval) {
        let target = self.clamped(time)
        self.player.seek(to: target)
        self.elapsed = target
        if self.isPlaying, self.duration > 0, self.elapsed >= self.duration {
            self.finishPlayback()
        }
    }

    func refreshFromPlayer() {
        self.refreshPositionOnly()
        if self.isPlaying, self.duration > 0, self.elapsed >= self.duration {
            self.finishPlayback()
        }
    }
}

private extension AudioPlaybackModel {
    func startTicks() {
        self.stopTicks()
        self.tickTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.ticks() {
                self.refreshFromPlayer()
                if !self.isPlaying {
                    break
                }
            }
        }
    }

    func stopTicks() {
        self.tickTask?.cancel()
        self.tickTask = nil
    }

    func finishPlayback() {
        self.player.pause()
        self.isPlaying = false
        self.stopTicks()
        self.restoreSessionIfNeeded()
    }

    func refreshPositionOnly() {
        self.duration = max(self.player.duration, 0)
        self.elapsed = self.clamped(self.player.currentTime)
    }

    func clamped(_ time: TimeInterval) -> TimeInterval {
        let lowerBounded = max(time, 0)
        guard self.duration > 0 else { return lowerBounded }
        return min(lowerBounded, self.duration)
    }

    func restoreSessionIfNeeded() {
        guard let savedCategory else { return }
        try? self.session.setActive(false, options: .notifyOthersOnDeactivation)
        try? self.session.setCategory(savedCategory, mode: .default, options: [])
        self.savedCategory = nil
    }
}

struct OnThisPhoneAudioPlayerView: View {
    let url: URL
    let isObserverActive: Bool
    let gateHint: String

    @State private var model: AudioPlaybackModel?
    @State private var loadFailed = false

    init(
        url: URL,
        isObserverActive: Bool,
        gateHint: String = SourceVocabulary.audioPlaybackObserverActiveHint
    ) {
        self.url = url
        self.isObserverActive = isObserverActive
        self.gateHint = gateHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let model {
                HStack(spacing: 12) {
                    self.playPauseButton(model: model)
                    Slider(
                        value: Binding(
                            get: { model.progressFraction },
                            set: { model.progressFraction = $0 }
                        ),
                        in: 0...1
                    )
                    .disabled(model.duration <= 0)
                }

                HStack {
                    Text(Self.timeText(model.elapsed))
                    Spacer()
                    Text(Self.timeText(model.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if self.isObserverActive {
                    Text(self.gateHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if self.loadFailed {
                Text(SourceVocabulary.rawOriginalUnavailable)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: self.url) {
            guard self.model == nil else { return }
            do {
                self.model = try AudioPlaybackModel(url: self.url)
            } catch {
                self.loadFailed = true
            }
        }
        .onDisappear {
            self.model?.stopForDisappear()
        }
    }
}

private extension OnThisPhoneAudioPlayerView {
    func playPauseButton(model: AudioPlaybackModel) -> some View {
        Button {
            if model.isPlaying {
                model.pause()
            } else {
                try? model.play()
            }
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.headline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(self.isObserverActive && !model.isPlaying)
        .accessibilityLabel(model.isPlaying ? SourceVocabulary.audioPlaybackPauseLabel : SourceVocabulary.audioPlaybackPlayLabel)
        .accessibilityHint(self.isObserverActive && !model.isPlaying ? self.gateHint : SourceVocabulary.audioPlaybackHint)
    }

    static func timeText(_ time: TimeInterval) -> String {
        OnThisPhoneItem.formattedDuration(time) ?? "0s"
    }
}
