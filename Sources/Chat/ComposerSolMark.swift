import SwiftUI

@MainActor
@Observable
final class ComposerTalentElapsedModel {
    var now = Date()
    private(set) var isTicking = false
    private var tickTask: Task<Void, Never>?

    func update(isBusy: Bool, reduceMotion: Bool) {
        if isBusy, !reduceMotion {
            self.start()
        } else {
            self.stop()
        }
    }

    func start() {
        guard self.tickTask == nil else { return }
        self.now = Date()
        self.isTicking = true
        self.tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.now = Date()
            }
        }
    }

    func stop() {
        self.tickTask?.cancel()
        self.tickTask = nil
        self.isTicking = false
    }

}

struct ComposerSolMark: View {
    let isBusy: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: self.action) {
            ZStack {
                Circle()
                    .stroke(Color.solOrange.opacity(self.isBusy ? 0.45 : 0), lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .scaleEffect(self.isPulsing ? 1.12 : 1)
                    .opacity(self.isPulsing ? 0.45 : 1)

                Image("SolWordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .opacity(self.isBusy ? 1 : 0.55)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SourceVocabulary.chatTalentDetailTitle)
        .onAppear {
            self.updatePulse()
        }
        .onChange(of: self.isBusy) { _, _ in
            self.updatePulse()
        }
        .onChange(of: self.reduceMotion) { _, _ in
            self.updatePulse()
        }
        .animation(
            self.isBusy && !self.reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
            value: self.pulse
        )
    }

    private var isPulsing: Bool {
        self.isBusy && !self.reduceMotion && self.pulse
    }

    private func updatePulse() {
        self.pulse = self.isBusy && !self.reduceMotion
    }
}

struct TalentWorkDetailSheet: View {
    let running: [ChatTalentActivity]
    let queued: [ChatTalentActivity]
    let now: Date

    var body: some View {
        NavigationStack {
            List {
                if self.running.isEmpty, self.queued.isEmpty {
                    Text(SourceVocabulary.chatTalentDetailEmpty)
                        .foregroundStyle(.secondary)
                } else {
                    if !self.running.isEmpty {
                        Section(SourceVocabulary.chatTalentRunningTitle) {
                            ForEach(self.running) { talent in
                                TalentWorkRow(talent: talent, stateFallback: SourceVocabulary.chatTalentTaskFallback, now: self.now)
                            }
                        }
                    }

                    if !self.queued.isEmpty {
                        Section(SourceVocabulary.chatTalentQueuedTitle) {
                            ForEach(self.queued) { talent in
                                TalentWorkRow(talent: talent, stateFallback: SourceVocabulary.chatTalentQueuedFallback, now: self.now)
                            }
                        }
                    }
                }
            }
            .navigationTitle(SourceVocabulary.chatTalentDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TalentWorkRow: View {
    let talent: ChatTalentActivity
    let stateFallback: String
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.talent.label)
                    .font(.subheadline.weight(.semibold))
                Text(self.taskText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(self.elapsedText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var taskText: String {
        let task = self.talent.task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return task.isEmpty ? self.stateFallback : task
    }

    private var elapsedText: String {
        guard let start = self.talent.timestamp ?? self.talent.queuedAt else { return "" }
        let seconds = max(0, Int(self.now.timeIntervalSince(start)))
        let minutes = seconds / 60
        return "\(minutes)m"
    }
}
