// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The Safari source's page: two setup steps until the first page comes in, then its
/// state, the way to its switch in Settings, and whether anything is still waiting on this device.
struct SafariSourceDetailView: View {
    @Environment(SafariSourceModel.self) private var model
    @Environment(AppConfig.self) private var appConfig
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// Safari on iPad opens extensions from a button in its address bar; on iPhone, from the page menu.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var menuTap: SafariTap { self.isPad ? .extensions : .pageMenu }
    @AppStorage("safari.setup.firstSite") private var typedSite = ""
    @AppStorage("safari.setup.sawWorking") private var sawWorking = false
    @AppStorage(SafariSetUpChoice.storageKey) private var storedChoice = ""
    @State private var wentToSettings = false
    @State private var settingsFailed = false
    @State private var wentToSafari = false

    var body: some View {
        let status = SafariSourceStatus(snapshot: self.model.snapshot, extensionOn: self.model.extensionOn)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SafariVocabulary.valueLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.deckSurface, in: ShellMetrics.cardShape)
                    .accessibilityIdentifier("safari.page.valueLine")
                if SafariSetUpStep.isShown(snapshot: self.model.snapshot) {
                    self.setUpSteps(status)
                } else {
                    if self.model.snapshot?.lastAccepted != nil, !self.sawWorking {
                        self.workingBlock
                    }
                    SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) { self.stateBlock(status) }
                    if self.model.snapshot != nil {
                        SourceDetailBlock(title: LocationVocabulary.deliveryBlockTitle) { self.deliveryBlock }
                    }
                    if status.sourceState == .active {
                        SourceDetailBlock(title: SafariVocabulary.addAnother) {
                            self.tapRow([self.menuTap, .solstone])
                        }
                    }
                }
                if !SafariSetUpStep.isShown(snapshot: self.model.snapshot) {
                    SourceHomeTileControl(sourceID: "safari")
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("safari.page")
#if DEBUG
        .overlay(alignment: .topLeading) {
            UITestStateProbe(identifier: "safari.page.state.\(status.sourceState)")
            UITestStateProbe(identifier: "safari.page.openSettings.calls.\(SafariUITestSource.calls.openSettings)")
        }
#endif
        .navigationTitle(SafariVocabulary.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The extension writes the store from another process; read it while shown.
            while !Task.isCancelled {
                self.model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task { await self.model.refreshExtensionState() }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active else { return }
            self.model.refresh()
            Task { await self.model.refreshExtensionState() }
        }
        .onDisappear {
            if self.model.snapshot?.lastAccepted != nil { self.sawWorking = true }
        }
    }

    private func setUpSteps(_ status: SafariSourceStatus) -> some View {
        let step = SafariSetUpStep(snapshot: self.model.snapshot, extensionOn: self.model.extensionOn)
        let source = safariSourceModel(snapshot: self.model.snapshot, extensionOn: self.model.extensionOn,
                                       isJournalPaired: self.appConfig.isPaired)
        return VStack(alignment: .leading, spacing: 0) {
            if status.sourceState == .off, let reason = source.subtext {
                Text(reason)
                    .font(.subheadline)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("safari.page.subtext")
            }
            self.stepRow(number: 1, title: SafariVocabulary.stepTurnOn, isDone: step == .addSite, isCurrent: step == .turnOn) {
                self.turnOnStep
            }
            Divider().padding(.vertical, 10)
            self.stepRow(number: 2, title: SafariVocabulary.stepChooseSites, isDone: false, isCurrent: step == .addSite) {
                self.chooseSitesStep
            }
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay { ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5) }
    }

    private func stepRow<Content: View>(number: Int, title: String, isDone: Bool, isCurrent: Bool,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.solOrange : Color.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(ShellFont.sectionTitle)
                    .foregroundStyle(isCurrent || isDone ? .primary : .secondary)
                if isCurrent { content() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safari.page.step\(number)\(isDone ? ".done" : "")")
    }

    /// Whether this view can still take the owner to the extension's page in Settings.
    private var canOpenSettings: Bool {
        SafariExtensionControl.canOpenSettings && !self.settingsFailed
    }

    private var turnOnStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.canOpenSettings ? SafariVocabulary.stepTurnOnBodyWithLink : SafariVocabulary.stepTurnOnBody)
                .font(.subheadline)
            HStack {
                Text(SafariVocabulary.switchName)
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .disabled(true)
                    .tint(.green)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SafariVocabulary.switchName)
            if self.canOpenSettings {
                Button {
                    Task {
                        let opened = await self.model.openExtensionSettings()
                        self.wentToSettings = opened
                        self.settingsFailed = !opened
                    }
                } label: {
                    Text(SafariVocabulary.openSettings).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("safari.openSettings")
                if self.wentToSettings, self.scenePhase == .active {
                    Text(SafariVocabulary.notOnYet)
                        .font(.subheadline)
                        .accessibilityIdentifier("safari.page.notOnYet")
                }
            } else {
                Text(self.isPad ? SafariVocabulary.settingsByHandPad : SafariVocabulary.settingsByHand)
                    .font(.subheadline)
                    .accessibilityIdentifier("safari.page.settingsByHand")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Step 2 asks which sites; the answer only picks the panel below it.
    private var chooseSitesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.choiceButton(.everySite, title: SafariVocabulary.chooseEverySite)
            self.choiceButton(.oneAtATime, title: SafariVocabulary.chooseOneAtATime)
            switch SafariSetUpChoice(rawValue: self.storedChoice) {
            case .everySite: self.everySitePanel.padding(.top, 4)
            case .oneAtATime: self.oneAtATimePanel.padding(.top, 4)
            case nil: EmptyView()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choiceButton(_ choice: SafariSetUpChoice, title: String) -> some View {
        let isChosen = SafariSetUpChoice(rawValue: self.storedChoice) == choice
        return Button {
            self.storedChoice = choice.rawValue
        } label: {
            HStack(spacing: 6) {
                if isChosen {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("safari.page.choose.\(choice.rawValue)")
    }

    /// Any site will do once Other Websites allows them all, so there is no site to open.
    private var everySitePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.canOpenSettings {
                Text(SafariVocabulary.everySiteBody)
                    .font(.subheadline)
                    .accessibilityIdentifier("safari.page.everySite.body")
                Button {
                    Task { self.settingsFailed = await !self.model.openExtensionSettings() }
                } label: {
                    Text(SafariVocabulary.openSettings).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("safari.page.everySite.openSettings")
            } else {
                Text(SafariVocabulary.everySiteByHand)
                    .font(.subheadline)
                    .accessibilityIdentifier("safari.page.everySite.byHand")
            }
            Text(self.isPad ? SafariVocabulary.everySiteNextPad : SafariVocabulary.everySiteNext)
                .font(.subheadline)
                .accessibilityIdentifier("safari.page.everySite.next")
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safari.page.everySite")
    }

    /// The app can't see Other Websites, so this says what Allow there means without claiming it's set.
    private var oneAtATimePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SafariVocabulary.oneAtATimeOtherWebsites)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("safari.page.oneAtATime.otherWebsites")
            self.addSiteStep
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var addSiteStep: some View {
        let host = SafariFirstSite.host(from: self.typedSite)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SafariVocabulary.siteField)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField(SafariVocabulary.sitePlaceholder, text: self.$typedSite)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .accessibilityIdentifier("safari.page.siteField")
            }
            self.tapRow([self.menuTap, .solstone, .add, .alwaysAllow])
            Text(SafariVocabulary.safariAsks)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                guard let host else { return }
                self.open(SafariFirstSite.urls(for: host)[...])
                self.wentToSafari = true
            } label: {
                Text(SafariVocabulary.openInSafari).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(host == nil)
            .accessibilityIdentifier("safari.openInSafari")
            if self.wentToSafari, let host {
                Text(SafariVocabulary.waitingFor(host))
                    .font(.subheadline)
                    .accessibilityIdentifier("safari.page.waitingFor")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ urls: ArraySlice<URL>) {
        guard let url = urls.first else { return }
        self.openURL(url) { opened in
            if !opened { self.open(urls.dropFirst()) }
        }
    }

    private var workingBlock: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.solOrange)
                .accessibilityHidden(true)
            Text(SafariVocabulary.working)
                .font(ShellFont.sectionTitle)
            Text(SafariVocabulary.workingBody)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("safari.page.working")
    }

    private enum SafariTap {
        case pageMenu, extensions, solstone, add, alwaysAllow

        var label: String {
            switch self {
            case .pageMenu: SafariVocabulary.tapPageMenu
            case .extensions: SafariVocabulary.tapExtensions
            case .solstone: SafariVocabulary.tapSolstone
            case .add: SafariVocabulary.tapAdd
            case .alwaysAllow: SafariVocabulary.tapAlwaysAllow
            }
        }

        var symbol: String {
            switch self {
            case .pageMenu: "line.3.horizontal.decrease"
            case .extensions: "puzzlepiece.extension"
            case .solstone: "sun.max"
            case .add: "plus"
            case .alwaysAllow: "checkmark"
            }
        }
    }

    /// The controls to tap in Safari, in order. Safari can't be drawn over, so they're shown first.
    private func tapRow(_ taps: [SafariTap]) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(taps.enumerated()), id: \.offset) { index, tap in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(height: 34)
                }
                VStack(spacing: 3) {
                    Image(systemName: tap.symbol)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    Text(tap.label)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(taps.map(\.label).joined(separator: ", then "))
    }

    private func stateBlock(_ status: SafariSourceStatus) -> some View {
        let source = safariSourceModel(snapshot: self.model.snapshot, extensionOn: self.model.extensionOn,
                                       isJournalPaired: self.appConfig.isPaired)
        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: status.sourceState)
            if let subtext = status.attention ?? source.subtext {
                Text(subtext)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("safari.page.subtext")
            }
            if status.sourceState == .active {
                Text(SafariVocabulary.whileClosed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("safari.page.whileClosed")
            }
            Text(SafariVocabulary.privateBrowsing)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if self.model.snapshot != nil {
                self.settingsRow
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Safari and Settings own the extension's switch, so the page takes the owner there.
    @ViewBuilder
    private var settingsRow: some View {
        if self.canOpenSettings {
            Text(self.isPad ? SafariVocabulary.manageInSettingsPad : SafariVocabulary.manageInSettings)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(SafariVocabulary.openSettings) {
                Task { self.settingsFailed = await !self.model.openExtensionSettings() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("safari.page.openSettings")
        } else {
            Text(self.isPad ? SafariVocabulary.manageByHandPad : SafariVocabulary.manageByHand)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("safari.page.manageByHand")
        }
    }

    private var deliveryBlock: some View {
        let snapshot = self.model.snapshot
        let waiting = (snapshot?.heldBytes ?? 0) + (snapshot?.queuedBytes ?? 0) > 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(waiting ? SafariVocabulary.waiting : SafariVocabulary.nothingWaiting)
                .font(.subheadline)
                .accessibilityIdentifier(waiting ? "safari.page.waiting" : "safari.page.nothingWaiting")
            if let last = snapshot?.lastAccepted {
                Text(SafariVocabulary.lastPage(last))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("safari.page.lastPage")
            } else {
                Text(self.isPad ? SafariVocabulary.noPageYetPad : SafariVocabulary.noPageYet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
