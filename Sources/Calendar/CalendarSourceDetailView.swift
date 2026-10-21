// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

/// The calendar source's page: enrolment until the owner confirms, then its state, its
/// calendars, its recent notes and what is on its way.
struct CalendarSourceDetailView: View {
    @Environment(CalendarSourceHandle.self) private var handle

    var body: some View {
        CalendarSourcePageView(source: self.handle.source)
    }
}

private struct CalendarSourcePageView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: CalendarPageModel

    init(source: any CalendarSourceControlling) {
        self._model = State(initialValue: CalendarPageModel(source: source))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if self.model.state.everOn {
                    self.onContent
                } else {
                    self.enrolContent
                }
                SourceHomeTileControl(sourceID: "calendar")
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            UITestStateProbe(identifier: "calendar.page.state.\(self.model.mode.rawValue)")
        }
#endif
        .navigationTitle(CalendarVocabulary.label)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("calendar.page")
        .task {
            await self.model.enter()
        }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await self.model.returnedToForeground() }
        }
    }

    // MARK: before the source has been on

    @ViewBuilder
    private var enrolContent: some View {
        Text(CalendarVocabulary.valueLine(isJournalPaired: self.appConfig.isPaired))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deckSurface, in: ShellMetrics.cardShape)
            .accessibilityIdentifier("calendar.page.valueLine")

        SourceDetailBlock(title: CalendarVocabulary.spanHeader) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CalendarVocabulary.spanOrder, id: \.self) { span in
                    self.spanOption(span)
                }
                Text(CalendarVocabulary.spanFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("calendar.page.spanFootnote")
            }
        }

        switch self.model.enrolAction {
        case .turnOn:
            Button(CalendarVocabulary.turnOn) {
                Task { await self.model.turnOn() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityHint(CalendarVocabulary.turnOnHint)
            .accessibilityIdentifier("calendar.turnOn")
        case .openSettings:
            VStack(alignment: .leading, spacing: 12) {
                SourceDetailReasonLine(message: CalendarVocabulary.cannotRead)
                    .accessibilityIdentifier("calendar.page.reason.cannotRead")
                self.openSettingsButton
            }
        case .restricted:
            SourceDetailReasonLine(message: CalendarVocabulary.restricted)
                .accessibilityIdentifier("calendar.page.reason.restricted")
        case .chooseCalendars(let label):
            self.chooseCalendars(label)
        }
    }

    @ViewBuilder
    private func chooseCalendars(_ label: CalendarConfirmLabel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceDetailVerdictLine(state: self.model.status.sourceState)
            Text(CalendarVocabulary.readyToSetUpSubline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("calendar.page.readyToSetUpSubline")
        }

        if !self.model.source.calendars.isEmpty {
            SourceDetailBlock(title: CalendarVocabulary.calendarsHeader) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(self.model.source.calendars) { calendar in
                        Toggle(calendar.title, isOn: Binding(
                            get: { calendar.followed },
                            set: { on in Task { await self.model.setUpCalendar(calendar.id, on: on) } }
                        ))
                        .tint(.solOrange)
                        .frame(minHeight: 44)
                        .accessibilityHint(CalendarVocabulary.calendarSwitchHint)
                        .accessibilityIdentifier("calendar.setup.calendar.\(calendar.id)")
                    }
                }
            }
        }

        if label == .failed {
            VStack(alignment: .leading, spacing: 12) {
                SourceDetailReasonLine(message: CalendarVocabulary.countFailed)
                    .accessibilityIdentifier("calendar.page.countFailed")
                Button(CalendarVocabulary.tryAgain) {
                    Task { await self.model.count() }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("calendar.tryAgain")
            }
        } else {
            Button(Self.confirmTitle(label)) {
                Task { await self.model.confirm() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!self.model.canConfirm)
            .accessibilityHint(CalendarVocabulary.confirmHint)
            .accessibilityIdentifier("calendar.confirm")
        }
    }

    private static func confirmTitle(_ label: CalendarConfirmLabel) -> String {
        switch label {
        case .checking, .failed: SourceVocabulary.sourceStateCheckingLabel
        case .count(let count): CalendarVocabulary.bringIn(count: count)
        case .startFromToday: CalendarVocabulary.startFromToday
        }
    }

    private func spanOption(_ span: CalendarSpanChoice) -> some View {
        let isSelected = self.model.span == span
        return Button {
            Task { await self.model.pick(span) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.solOrange : .secondary)
                    .frame(width: 24)
                Text(CalendarVocabulary.spanLabel(span))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("calendar.span.\(span.rawValue)")
    }

    private var openSettingsButton: some View {
        Button(LocationVocabulary.openSettingsAction) {
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("calendar.openSettings")
    }

    // MARK: once on

    @ViewBuilder
    private var onContent: some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            self.stateBlock
        }
        SourceDetailBlock(title: CalendarVocabulary.calendarsBlockTitle) {
            self.calendarsBlock
        }
        SourceDetailBlock(title: LocationVocabulary.recentBlockTitle) {
            self.recentBlock
        }
        SourceDetailBlock(title: LocationVocabulary.deliveryBlockTitle) {
            self.deliveryBlock
        }
    }

    private var stateBlock: some View {
        let status = self.model.status
        let state = self.model.state
        let fact = self.model.followedFact
        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: status.sourceState)
            if let attention = status.attention {
                SourceDetailReasonLine(message: attention.text)
                    .accessibilityIdentifier("calendar.page.attention")
                if attention.opensSettings {
                    self.openSettingsButton
                }
            }
            if let subtext = status.sourceState.subtext(
                activeSubtext: CalendarVocabulary.activeSubtext(isJournalPaired: self.appConfig.isPaired),
                isJournalPaired: self.appConfig.isPaired
            ) {
                Text(subtext)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let checked = state.lastCompletedCheck {
                Text(CalendarVocabulary.lastChecked(checked.formatted(date: .omitted, time: .shortened)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("calendar.page.lastChecked")
            }
            Text(CalendarVocabulary.followed(fact.followed, of: fact.total))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("calendar.page.followed")
            Text(CalendarVocabulary.honestyLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if status.attention == nil {
                Button(state.paused ? SourceVocabulary.resume : SourceVocabulary.pause) {
                    Task { await self.model.pauseOrResume() }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityHint(state.paused ? CalendarVocabulary.resumeHint : CalendarVocabulary.pauseHint)
                .accessibilityIdentifier("calendar.pauseResume")
            }
        }
    }

    private var calendarsBlock: some View {
        let pending = self.model.pendingSwitchOn
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(self.model.source.calendars) { calendar in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(calendar.title, isOn: Binding(
                        get: { calendar.followed },
                        set: { on in Task { await self.model.setCalendar(calendar.id, on: on) } }
                    ))
                    .tint(.solOrange)
                    .frame(minHeight: 44)
                    .disabled(pending != nil && pending != calendar.id)
                    .accessibilityHint(CalendarVocabulary.calendarSwitchHint)
                    .accessibilityIdentifier("calendar.calendar.\(calendar.id)")

                    switch calendar.importStep {
                    case .readyToConfirm(let count):
                        HStack(spacing: 12) {
                            Button(count == 0 ? CalendarVocabulary.startFromToday : CalendarVocabulary.bringIn(count: count)) {
                                Task { await self.model.confirmCalendar(calendar.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityHint(CalendarVocabulary.confirmHint)
                            .accessibilityIdentifier("calendar.calendar.\(calendar.id).confirm")
                            Button(CalendarVocabulary.notNow) {
                                Task { await self.model.notNow(calendar.id) }
                            }
                            .buttonStyle(.bordered)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("calendar.calendar.\(calendar.id).notNow")
                        }
                    case .counting:
                        Text(SourceVocabulary.sourceStateCheckingLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .importing, nil:
                        EmptyView()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentBlock: some View {
        let recent = self.model.state.recent
        if recent.isEmpty {
            Text(SourceVocabulary.recentEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, note in
                    Text(CalendarVocabulary.recent(note.kind, title: note.title ?? ""))
                        .font(.subheadline)
                        .accessibilityIdentifier("calendar.page.recent.\(note.kind.rawValue)")
                }
            }
        }
    }

    private var deliveryBlock: some View {
        let line: String = switch self.model.deliveryLine {
        case .quiet: LocationVocabulary.deliveryQuietLine
        case .sending(let count): CalendarVocabulary.deliverySending(count: count)
        case .needsAttention(let count): CalendarVocabulary.deliveryNeedsAttention(count: count)
        case .waitingForJournalUpdate: CalendarVocabulary.waitingForJournalUpdate
        }
        return Text(line)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("calendar.page.delivery")
    }
}
