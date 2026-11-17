// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceState: Codable, Equatable, Sendable {
    case off
    case enrolling
    case readyToSetUp
    case checking
    case active
    case paused
    case needsAttention

    var label: String {
        switch self {
        case .off:
            AppStrings.ios_app_off()
        case .enrolling:
            AppStrings.ios_app_watchheadlineenrolling()
        case .readyToSetUp:
            SourceVocabulary.sourceStateReadyToSetUpLabel
        case .checking:
            SourceVocabulary.sourceStateCheckingLabel
        case .active:
            AppStrings.ios_app_on()
        case .paused:
            AppStrings.ios_safaribrowser_paused()
        case .needsAttention:
            SourceVocabulary.needsAttention
        }
    }

    var symbol: String {
        switch self {
        case .off:
            "power.circle"
        case .enrolling:
            "arrow.triangle.2.circlepath"
        case .readyToSetUp:
            "plus.circle"
        case .checking:
            "arrow.triangle.2.circlepath"
        case .active:
            "checkmark.circle"
        case .paused:
            "pause.circle"
        case .needsAttention:
            "exclamationmark.triangle"
        }
    }

    func universalSubtext(isJournalPaired: Bool) -> String? {
        switch self {
        case .off:
            SourceVocabulary.offSubtext(isJournalPaired: isJournalPaired)
        case .enrolling:
            SourceVocabulary.enrollingSubtext(isJournalPaired: isJournalPaired)
        case .readyToSetUp, .checking:
            nil
        case .active:
            nil
        case .paused:
            SourceVocabulary.pausedSubtext
        case .needsAttention:
            nil
        }
    }

    /// The sub-line under the state word, or `nil` when the state says it all.
    ///
    /// `readyToSetUp` returns `nil` deliberately. A source the owner has never set up
    /// has nothing to add that the state word did not already say, and the fall-through
    /// below would hand it the source's *running* line — `ready to set up` over `on`.
    /// A source with something of its own to say here supplies a `subtextOverride`.
    func subtext(activeSubtext: String, isJournalPaired: Bool) -> String? {
        if case .readyToSetUp = self {
            return nil
        }
        if case .needsAttention = self {
            return nil
        }
        if let universal = self.universalSubtext(isJournalPaired: isJournalPaired) {
            return universal
        }
        return self.saysMoreThanTheStateWord(activeSubtext) ? activeSubtext : nil
    }

    /// A sub-line never repeats the state word: audio's running line is "on", under "on".
    private func saysMoreThanTheStateWord(_ line: String) -> Bool {
        line != self.label
    }

    /// The deck tile's sub-line.
    ///
    /// The short half of `subtext(...)`, said in the room a tile has. The detail view is
    /// where a state explains itself in full ("intake is off. turn it on
    /// any time."); on a tile that wraps to three lines and truncates, so the tile takes
    /// less. ⛔ Not a second vocabulary: never a claim the long form does not make.
    ///
    /// ⛔ Do not read "the tail of the long form" into this. Of the instances here, `off`
    /// is a tail, `paused` is the long form's first sentence and `setting up` is its head
    /// clause — the binding rule is that a tile says nothing new, not where the cut falls.
    /// `readyToSetUp` returns `nil`: the state word is the whole message on a tile.
    func compactSubtext(activeSubtext: String) -> String? {
        switch self {
        case .off:
            // The tile's switch already says it can be turned on, so an off tile has no sub-line.
            nil
        case .enrolling:
            SourceVocabulary.enrollingSubtextCompact
        case .paused:
            SourceVocabulary.pausedSubtextCompact
        case .needsAttention:
            nil
        case .checking, .readyToSetUp:
            nil
        case .active:
            self.saysMoreThanTheStateWord(activeSubtext) ? activeSubtext : nil
        }
    }

    func voiceOverText(activeSubtext: String, isJournalPaired: Bool) -> String {
        switch self {
        case .off:
            AppStrings.ios_app_voiceovertext("\(SourceVocabulary.offSubtext(isJournalPaired: isJournalPaired))")
        case .enrolling:
            AppStrings.ios_app_voiceovertext3("\(SourceVocabulary.enrollingSubtext(isJournalPaired: isJournalPaired))")
        case .readyToSetUp:
            SourceVocabulary.sourceStateReadyToSetUpLabel
        case .checking:
            AppStrings.ios_sourcevocabulary_checking()
        case .active:
            self.saysMoreThanTheStateWord(activeSubtext) ? AppStrings.ios_app_voiceovertext4_native("\(Self.sentence(activeSubtext))") : AppStrings.ios_sourcevocabulary_on()
        case .paused:
            AppStrings.ios_app_voiceovertext2("\(SourceVocabulary.pausedSubtext)")
        case .needsAttention:
            AppStrings.ios_source_attention_spoken()
        }
    }

    private static func sentence(_ text: String) -> String {
        AppStrings.language == "en-US" ? (text.hasSuffix(".") ? text : "\(text).") : text
    }
}

nonisolated enum SourceVocabulary {
    private static let offSubtextUnpaired = AppStrings.ios_app_turnitonanytime()
    private static let offSubtextPaired = AppStrings.ios_app_offsubtextpaired()
    // The tile-sized half of the sub-lines above. Each is the tail of its long form.
    static let enrollingSubtextCompact = AppStrings.ios_app_gettingready()
    static let pausedSubtextCompact = AppStrings.ios_app_pausedsubtextcompact()

    private static let enrollingSubtextUnpaired = AppStrings.ios_app_gettingready()
    private static let enrollingSubtextPaired = AppStrings.ios_app_enrollingsubtextpaired()
    static let sourceStateReadyToSetUpLabel = AppStrings.ios_app_sourcestatereadytosetuplabel()
    static let sourceStateCheckingLabel = AppStrings.ios_app_sourcestatecheckinglabel()
    static let pausedSubtext = AppStrings.ios_app_pausedsubtext()
    static let microphoneTakenSubtextCompact = AppStrings.ios_app_microphonetakensubtextcompact()
    static let microphoneTakenSubtext = AppStrings.ios_app_microphonetakensubtext()
    static let audioAttentionMicrophoneOff = AppStrings.ios_app_audioattentionmicrophoneoff()
    static let audioAttentionNotRunning = AppStrings.ios_app_audioattentionnotrunning()
    static let audioAttentionStorageFull = AppStrings.ios_app_audioattentionstoragefull()
    static let needsAttention = AppStrings.ios_transfer_needsattention()

    static let observerActiveSubtext = AppStrings.ios_app_on()
    static let shareSendingProgress = AppStrings.ios_app_sharesendingprogress()
    static let shareDeliveredProgress = AppStrings.ios_app_sharedeliveredprogress()
    static let sendStateSaved = AppStrings.ios_app_onthisdevice()
    static let sendStateSending = AppStrings.ios_app_sending()
    static let sendStateCompactSaved = AppStrings.ios_liveactivity_waitingtosync()
    static let sendStateCompactOnTheWay = AppStrings.ios_app_sendstatecompactontheway()
    static let sendStateCompactInJournal = AppStrings.ios_app_inyourjournal()
    static let onThisPhoneWaitingExplain = AppStrings.ios_app_onthisphonewaitingexplain()
    static let tryNow = AppStrings.ios_app_trynow()
    static let waitingToSync = sendStateCompactSaved
    static let screencastDisplayName = AppStrings.ios_brand_broadcastname()
    static let screencastActiveSubtext = AppStrings.ios_app_screencastactivesubtext()
    static let screencastStartingSubtext = AppStrings.ios_app_waitingforthesystemsheet()
    static let screencastOffSubtext = AppStrings.ios_app_off()
    static let screencastAttentionStorageLow = AppStrings.ios_app_screencastattentionstoragelow()
    static let screencastAttentionNoVideo = AppStrings.ios_app_screencastattentionnovideo()
    static let screencastAttentionNotSaved = AppStrings.ios_app_screencastattentionnotsaved()
    static let screencastAttentionNotRunning = AppStrings.ios_app_screencastattentionnotrunning()
    static let screencastUnavailableSubtext = AppStrings.ios_app_unavailable()
    static let screencastDetailTitle = AppStrings.ios_brand_broadcastname()
    static let screencastStateTitle = AppStrings.ios_app_state()
    static let screencastRecentTitle = AppStrings.ios_app_recent()
    static let screencastDeliveryTitle = AppStrings.ios_app_screencastdeliverytitle()
    static let screencastStartButton = AppStrings.ios_app_screencaststartbutton()
    static let screencastStopButton = AppStrings.ios_app_screencaststopbutton()
    static let screencastOpenSystemSheet = AppStrings.ios_app_screencastopensystemsheet()
    static let screencastReadyText = AppStrings.ios_app_screencastreadytext()
    static let screencastStartingText = AppStrings.ios_app_waitingforthesystemsheet()
    static let screencastActiveText = AppStrings.ios_app_screencastactivetext()
    static let screencastUnavailableText = AppStrings.ios_transfer_screencastunavailabletext()
    static let screencastNoVideoText = AppStrings.ios_transfer_screencastnovideotext()
    static let screencastFinalizeFailedText = AppStrings.ios_transfer_screencastfinalizefailedtext()
    static let screencastFinalizeTimeoutText = AppStrings.ios_transfer_screencastfinalizetimeouttext()
    static let screencastFilesystemFailedText = AppStrings.ios_transfer_screencastfilesystemfailedtext()
    static let screencastStorageLowText = AppStrings.ios_transfer_screencaststoragelowtext()
    static let screencastSystemEndedSubtext = AppStrings.ios_app_screencastsystemendedsubtext()
    static let screencastPrimerTitle = AppStrings.ios_sourcevocabularyswift_beforeiosasks()
    static let screencastPrimerBodyActive = AppStrings.ios_app_screencastprimerbodyactive()
    static let screencastPrimerBodyOff = AppStrings.ios_app_screencastprimerbodyoff()
    static let screencastPrimerBody = screencastPrimerBodyOff

    // The status pill resolves to one of six states and names it in one word or
    // phrase. `connected · syncing` was two of those states at once.
    static let connectedLabel = AppStrings.ios_connection_connectedlabel()
    static let syncingLabel = AppStrings.ios_app_syncinglabel()
    static let statusConnectingLabel = AppStrings.ios_app_connecting()
    static let statusOfflineLabel = AppStrings.ios_connection_statusofflinelabel()
    static let stallWaitingLabel = AppStrings.ios_observer_stallwaitinglabel()
    static let stallNotConnectedLabel = AppStrings.ios_app_notconnected()
    static let stallCantReachYourJournal = AppStrings.ios_migration_offline_title()
    static let stallTryAgainLabel = AppStrings.ios_migration_offline_action()
    static let stallTriesEveryAddress = AppStrings.ios_app_stalltrieseveryaddress()
    static let stallTryingLabel = AppStrings.ios_app_stalltryinglabel()
    static let stallPairAgainLabel = AppStrings.ios_migration_keyrefused_title()
    static let stallPairAgainDetail = AppStrings.ios_app_stallpairagaindetail()

    static func stallLastReached(date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppStrings.language == "en-US" ? Locale(identifier: "en_US_POSIX") : AppStrings.locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return AppStrings.ios_app_stalllastreached("\(relative)")
    }

    static let addMoreTitle = AppStrings.ios_app_addmoretitle()
    static let addMoreSubline = AppStrings.ios_app_addmoresubline()
    // The status view's own lead. `all caught up` is words, never a zero.
    static let whatIsWaitingSection = AppStrings.ios_app_whatiswaitingsection()
    static let syncingToYourJournal = AppStrings.ios_app_syncingtoyourjournal()
    static let heldOnThisDevice = AppStrings.ios_app_onthisdevice()

    static let addMoreNotOnHome = AppStrings.ios_app_addmorenotonhome()
    static let addMoreAlreadyOnHome = AppStrings.ios_app_addmorealreadyonhome()
    static let addMoreFooter = AppStrings.ios_app_addmorefooter()
    static let addMoreSuggestionsTitle = AppStrings.ios_app_addmoresuggestionstitle()
    static let addMoreSuggestionsBody = AppStrings.ios_app_addmoresuggestionsbody()
    static let importTitle = AppStrings.ios_app_importtitle()
    static let calendarTitle = AppStrings.ios_calendar_calendar()
    static let obsidianTitle = AppStrings.ios_obsidian_obsidian()
    // `anything` is not an honest category: the import surface names photos and files
    // and nothing else, so the tile names those two and stops.
    static let importSubline = AppStrings.ios_app_importsubline()
    static let giveThisATileOnHome = AppStrings.ios_app_givethisatileonhome()
    static let hidingThisNeverTurnsItOff =
        AppStrings.ios_app_hidingthisneverturnsitoff()
    static let whatItAddsTitle = AppStrings.ios_app_whatitaddstitle()
    static let openSettings = AppStrings.ios_location_openiossettings()
    static let statusTitle = AppStrings.ios_app_status()
    static let settingsTitle = AppStrings.ios_app_settingstitle()
    // What VoiceOver calls the dimmed shell beside the open shelf: it is the way back.
    static let shelfDismissLabel = AppStrings.ios_app_shelfdismisslabel()
    static let waitingGoesToNextJournal =
        AppStrings.ios_app_waitinggoestonextjournal()
    static let deckToggleTitle = AppStrings.ios_app_decktoggletitle()
    static let getHelp = AppStrings.ios_app_gethelp()
    static let reportAProblem = AppStrings.ios_app_reportaproblem()
    static let trustLineConfigured = AppStrings.ios_app_trustlineconfigured()
    static let watchHeadlineOff = AppStrings.ios_app_off()
    static let watchHeadlineEnrolling = AppStrings.ios_app_watchheadlineenrolling()
    static let watchHeadlineListening = AppStrings.ios_app_on()
    static let watchHeadlineStopping = AppStrings.ios_app_watchheadlinestopping()
    static let watchPanelRunning = AppStrings.ios_app_watchpanelrunning()
    static let watchMicrophoneUnavailable = AppStrings.ios_app_watchmicrophoneunavailable()
    static let watchAudioStoppedItself = AppStrings.ios_app_audiostoppeditself()
    static let watchAudioCouldNotBeSaved = AppStrings.ios_app_audiocouldnotbesaved()
    static let watchStatusSaveFailed = AppStrings.ios_app_watchstatussavefailed()
    static let watchStatusUnreadable = AppStrings.ios_app_watchstatusunreadable()
    static let watchManifestScanFailed = AppStrings.ios_app_watchmanifestscanfailed()
    static let watchManifestCatalogPartial = AppStrings.ios_app_watchmanifestcatalogpartial()
    static let watchLocationUnavailable = AppStrings.ios_app_watchlocationunavailable()
    static let watchGenericUnavailable = AppStrings.ios_app_watchgenericunavailable()
    static let watchStatusAudioOutcomeLabel = AppStrings.ios_app_watchstatusaudiooutcomelabel()
    static let watchStatusAudioOutcomeOwnerStopped = AppStrings.ios_app_watchstatusaudiooutcomeownerstopped()
    static let watchNoticeMicrophoneAccessTitle = AppStrings.ios_app_watchnoticemicrophoneaccesstitle()
    static let watchNoticeMicrophoneAccessBody = AppStrings.ios_app_watchnoticemicrophoneaccessbody()
    static let watchNoticeAudioCouldNotStartTitle = AppStrings.ios_app_watchnoticeaudiocouldnotstarttitle()
    static let watchNoticeAudioCouldNotStartBody = AppStrings.ios_app_openthesolstoneapponyourwatchto()
    static let watchNoticeAudioStoppedTitle = AppStrings.ios_app_audiostoppeditself()
    static let watchNoticeAudioStoppedBody = AppStrings.ios_app_openthesolstoneapponyourwatchto()
    static let watchNoticeAudioCouldNotBeSavedTitle = AppStrings.ios_app_audiocouldnotbesaved()
    static let watchNoticeAudioCouldNotBeSavedBody = AppStrings.ios_app_watchnoticeaudiocouldnotbesavedbody()
    static let watchNoticeAudioCouldNotBeConfirmedTitle = AppStrings.ios_app_watchnoticeaudiocouldnotbeconfirmedtitle()
    static let watchNoticeAudioCouldNotBeConfirmedBody = AppStrings.ios_app_watchnoticeaudiocouldnotbeconfirmedbody()
    static let watchPipelineSending = AppStrings.ios_app_sending()
    static let watchPipelineSaved = AppStrings.ios_app_savedonyourwatch()
    static let watchPipelineUnknown = "—"
    static let watchPipelineConfirming = AppStrings.ios_app_watchpipelineconfirming()
    static let watchPipelineAbandoned = AppStrings.ios_app_watchpipelineabandoned()
    static let watchPipelineAbandonedSubtext = AppStrings.ios_app_watchpipelineabandonedsubtext()
    static let watchPipelineHandedOff = AppStrings.ios_app_watchpipelinehandedoff()
    static let watchPipelineRelayStuckReason = AppStrings.ios_app_watchpipelinerelaystuckreason()
    static let watchPipelineHandoffStuckReason = AppStrings.ios_app_watchpipelinehandoffstuckreason()
    static let watchPipelineOrphanStuckReason = AppStrings.ios_app_watchpipelineorphanstuckreason()
    static let watchPipelineReportedGroupLabel = AppStrings.ios_app_watchpipelinereportedgrouplabel()
    static let watchPipelineKnownGroupLabel = AppStrings.ios_app_watchpipelineknowngrouplabel()
    static let watchStuckNoticeTitle = AppStrings.ios_app_watchstucknoticetitle()
    static let watchAppUpdateReason = AppStrings.ios_app_watchappupdatereason()
    static let watchAppUpdateSentence = AppStrings.ios_app_watchappupdatesentence()
    static let watchAppUpdateHowToSummary = AppStrings.ios_app_watchappupdatehowtosummary()
    static let watchAppUpdateHowToBody = AppStrings.ios_app_watchappupdatehowtobody()
    static let watchPipelineRelayStuckNextStep = AppStrings.ios_app_watchpipelinerelaystucknextstep()
    static let watchPipelineHandoffStuckNextStep = AppStrings.ios_app_watchpipelinehandoffstucknextstep()
    static let watchPipelineOrphanStuckNextStep = AppStrings.ios_app_watchpipelineorphanstucknextstep()
    static let watchWaitingForPhone = AppStrings.ios_app_watchwaitingforphone()
    static let watchLinkConnected = AppStrings.ios_app_watchlinkconnected()
    static let watchLinkNotConnected = AppStrings.ios_app_watchlinknotconnected()
    static let watchSourceDisplayName = AppStrings.ios_app_watchsourcedisplayname()
    static let watchComplicationUnknownHeadline = AppStrings.ios_app_watchcomplicationunknownheadline()
    static let watchComplicationUnknownDetail = AppStrings.ios_app_openthesolstoneapponyourwatch()
    static let watchComplicationUnknownInline = AppStrings.ios_app_watchcomplicationunknowninline()
    static let watchActivationFailedSubtext = AppStrings.ios_app_watchactivationfailedsubtext()
    static let watchNoWatchPairedSubtext = AppStrings.ios_app_watchnowatchpairedsubtext()
    static let watchReadyToSetUpSubtext = AppStrings.ios_app_watchreadytosetupsubtext()
    static let watchInstalledNeverOpenedSubtext = AppStrings.ios_app_watchinstalledneveropenedsubtext()
    static let watchReceivingNowSubtext = AppStrings.ios_app_watchreceivingnowsubtext()
    static let watchIdleNowSubtext = AppStrings.ios_app_watchidlenowsubtext()
    static let watchListeningSubtext = AppStrings.ios_app_watchlisteningsubtext()
    static let watchSteadyObservingHeadline = AppStrings.ios_app_watchsteadyobservingheadline()
    static let watchObservingSentenceBase = AppStrings.ios_app_watchobservingsentencebase()
    static let watchSteadyReceivingHeadline = AppStrings.ios_app_watchsteadyreceivingheadline()
    static let watchSteadyWatchWaitingHeadline = AppStrings.ios_app_savedonyourwatch()
    static let watchSteadyPhoneSyncingHeadline = AppStrings.ios_app_onthisdevice()
    static let watchSteadyCaughtUpSentence = AppStrings.ios_app_watchsteadycaughtupsentence()
    static let watchSteadyQuietHeadline = AppStrings.ios_app_watchsteadyquietheadline()
    static let watchPresenceConnectedNow = AppStrings.ios_app_watchpresenceconnectednow()
    static let watchPresenceNeverHeard = AppStrings.ios_app_watchpresenceneverheard()
    static let watchSetupHeader = AppStrings.ios_app_watchsetupheader()
    static let watchSetupValueLine = AppStrings.ios_app_watchsetupvalueline()
    static let watchSetupNoWatchBody = AppStrings.ios_app_watchsetupnowatchbody()
    static let watchCheckingLine = AppStrings.ios_app_watchcheckingline()
    static let watchSetupInstallTitle = AppStrings.ios_app_watchsetupinstalltitle()
    static let watchSetupInstallSubline = AppStrings.ios_app_watchsetupinstallsubline()
    static let watchSetupInstallButton = AppStrings.ios_app_watchsetupinstallbutton()
    static let watchSetupInstallButtonHint = AppStrings.ios_app_watchsetupinstallbuttonhint()
    static let watchSetupInstallDisclosureSummary = AppStrings.ios_app_watchsetupinstalldisclosuresummary()
    static let watchSetupInstallDisclosureBody = AppStrings.ios_app_watchsetupinstalldisclosurebody()
    static let watchSetupOpenTitle = AppStrings.ios_app_openthesolstoneapponyourwatch()
    static let watchSetupOpenSubline = AppStrings.ios_app_watchsetupopensubline()
    static let watchSetupFirstMomentTitle = AppStrings.ios_app_watchsetupfirstmomenttitle()
    static let watchSetupCelebration = AppStrings.ios_app_watchsetupcelebration()
    static let watchSetupStepPending = AppStrings.ios_app_watchsetupsteppending()
    static let watchSetupStepActive = AppStrings.ios_app_watchsetupstepactive()
    static let watchSetupStepComplete = AppStrings.ios_app_watchsetupstepcomplete()
    static let watchStateBlockTitle = AppStrings.ios_app_state()
    static let watchDiagnosticsBlockTitle = AppStrings.ios_home_watchdiagnosticsblocktitle()
    static let watchTechnicalDetailTitle = AppStrings.ios_app_watchtechnicaldetailtitle()
    static let watchReceivedLabel = AppStrings.ios_app_watchreceivedlabel()
    static let watchNotYetInJournalLabel = AppStrings.ios_app_watchnotyetinjournallabel()
    static let watchHandedToJournalLabel = AppStrings.ios_app_watchhandedtojournallabel()
    static let watchLastSyncLabel = AppStrings.ios_app_watchlastsynclabel()
    static let watchLastSyncNever = AppStrings.ios_app_watchlastsyncnever()
    static let watchActivationLabel = AppStrings.ios_app_watchactivationlabel()
    static let watchPairedWithPhoneLabel = AppStrings.ios_app_watchpairedwithphonelabel()
    static let watchInstalledLabel = AppStrings.ios_app_watchinstalledlabel()
    static let watchLastReceivedLabel = AppStrings.ios_app_watchlastreceivedlabel()
    static let watchLastReceivedNever = AppStrings.ios_app_watchlastreceivednever()
    static let watchLastStagingDetailLabel = AppStrings.ios_app_watchlaststagingdetaillabel()
    static let watchLastLedgerDetailLabel = AppStrings.ios_app_watchlastledgerdetaillabel()
    static let watchLastSyncDetailLabel = AppStrings.ios_app_watchlastsyncdetaillabel()
    static let watchLastUploadErrorLabel = AppStrings.ios_app_watchlastuploaderrorlabel()
    static let watchStatusLabel = AppStrings.ios_app_watchstatuslabel()
    static let watchReachableLabel = AppStrings.ios_app_reachable()
    static let watchDetailNone = AppStrings.ios_app_watchdetailnone()
    static let watchBooleanYes = AppStrings.ios_app_watchbooleanyes()
    static let watchBooleanNo = AppStrings.ios_app_watchbooleanno()
    static let watchActivationActivated = AppStrings.ios_app_watchactivationactivated()
    static let watchActivationInactive = AppStrings.ios_app_watchactivationinactive()
    static let watchActivationNotActivated = AppStrings.ios_app_watchactivationnotactivated()
    static let watchRelativeJustNow = AppStrings.ios_app_watchrelativejustnow()
    static let watchShareDiagnosticsLabel = AppStrings.ios_app_watchsharediagnosticslabel()
    static let watchShareDiagnosticsHint = AppStrings.ios_app_watchsharediagnosticshint()
    static let watchPrepareDiagnosticsHint = AppStrings.ios_app_watchpreparediagnosticshint()
    static let watchDiagnosticsExportTitle = AppStrings.ios_app_watchdiagnosticsexporttitle()
    static let watchDiagnosticsExportFileName = "watch-diagnostics.txt"
    static let watchDiagnosticsStageReportEnvironment = AppStrings.ios_app_watchdiagnosticsstagereportenvironment()
    static let watchDiagnosticsStageWatchSnapshot = AppStrings.ios_app_watchdiagnosticsstagewatchsnapshot()
    static let watchDiagnosticsStageRetentionAppleQueue = AppStrings.ios_app_watchdiagnosticsstageretentionapplequeue()
    static let watchDiagnosticsStageIPhoneStaging = AppStrings.ios_app_watchdiagnosticsstageiphonestaging()
    static let watchDiagnosticsStageJournalHandoff = AppStrings.ios_app_watchdiagnosticsstagejournalhandoff()
    static let watchDiagnosticsRelayAssessmentLabel = AppStrings.ios_app_watchdiagnosticsrelayassessmentlabel()
    static let watchDiagnosticsWatchUserInfoQueueLabel = AppStrings.ios_app_watchdiagnosticswatchuserinfoqueuelabel()
    static let watchDiagnosticsIPhoneACKQueueLabel = AppStrings.ios_app_watchdiagnosticsiphoneackqueuelabel()
    static let watchDiagnosticsActiveBacklogLabel = AppStrings.ios_app_watchdiagnosticsactivebackloglabel()
    static let watchDiagnosticsVisibleActiveLabel = AppStrings.ios_app_watchdiagnosticsvisibleactivelabel()
    static let watchDiagnosticsOmittedActiveLabel = AppStrings.ios_app_watchdiagnosticsomittedactivelabel()
    static let watchDiagnosticsEvidenceUnavailableLabel = AppStrings.ios_app_watchdiagnosticsevidenceunavailablelabel()
    static let watchDiagnosticsOmittedObservationsLabel = AppStrings.ios_app_watchdiagnosticsomittedobservationslabel()
    static let watchDiagnosticsPhoneLedgerLabel = AppStrings.ios_app_watchdiagnosticsphoneledgerlabel()
    static let watchDiagnosticsPhoneLedgerRetainedEntriesLabel = AppStrings.ios_app_watchdiagnosticsphoneledgerretainedentrieslabel()
    static let watchDiagnosticsPhoneLedgerReceivedLabel = AppStrings.ios_app_watchdiagnosticsphoneledgerreceivedlabel()
    static let watchDiagnosticsPhoneLedgerHandedLabel = AppStrings.ios_app_watchdiagnosticsphoneledgerhandedlabel()
    static let watchDiagnosticsPhoneLedgerDroppedLabel = AppStrings.ios_app_watchdiagnosticsphoneledgerdroppedlabel()
    static let watchDiagnosticsPhoneLedgerHandedAndDroppedLabel = AppStrings.ios_app_watchdiagnosticsphoneledgerhandedanddroppedlabel()
    static let watchDiagnosticsIPhoneRecognizedACKLabel = AppStrings.ios_app_watchdiagnosticsiphonerecognizedacklabel()
    static let watchDiagnosticsIPhoneParseableACKLabel = AppStrings.ios_app_watchdiagnosticsiphoneparseableacklabel()
    static let watchDiagnosticsIPhoneDistinctACKIdentitiesLabel = AppStrings.ios_app_watchdiagnosticsiphonedistinctackidentitieslabel()
    static let watchDiagnosticsIPhoneDuplicateACKExtrasLabel = AppStrings.ios_app_watchdiagnosticsiphoneduplicateackextraslabel()
    static let watchDiagnosticsIPhoneMalformedMissingACKLabel = AppStrings.ios_app_watchdiagnosticsiphonemalformedmissingacklabel()
    static let watchDiagnosticsIPhoneNonACKUserInfoLabel = AppStrings.ios_app_watchdiagnosticsiphonenonackuserinfolabel()
    static let watchDiagnosticsVisibleActiveClassificationLabel = AppStrings.ios_app_watchdiagnosticsvisibleactiveclassificationlabel()
    static let watchDiagnosticsNotProvided = AppStrings.ios_watch_notprovided()
    static let watchDiagnosticsUnavailable = AppStrings.ios_app_unavailable()
    static let watchDiagnosticsIndeterminate = AppStrings.ios_app_watchdiagnosticsindeterminate()
    static let problemReportsToggle = AppStrings.ios_app_problemreportstoggle()
    static let problemReportsToggleHint = AppStrings.ios_app_problemreportstogglehint()
    static let problemReportsTitle = AppStrings.ios_app_problemreports()
    static let problemReportsRow = AppStrings.ios_app_problemreports()
    static let problemReportsRowHint = AppStrings.ios_app_problemreportsrowhint()
    static let problemReportsReportRowHint = AppStrings.ios_app_problemreportsreportrowhint()
    static let problemReportsOptedOutTitle = AppStrings.ios_app_problemreportsoptedouttitle()
    static let problemReportsOptedOutBody = AppStrings.ios_app_problemreportsoptedoutbody()
    static let problemReportsEmptyTitle = AppStrings.ios_app_problemreportsemptytitle()
    static let problemReportsEmptyBody = AppStrings.ios_app_problemreportsemptybody()
    static let problemReportKindCrash = AppStrings.ios_app_problemreportkindcrash()
    static let problemReportKindHang = AppStrings.ios_app_problemreportkindhang()
    static let problemReportKindCPUException = AppStrings.ios_app_problemreportkindcpuexception()
    static let problemReportKindDiskWriteException = AppStrings.ios_app_problemreportkinddiskwriteexception()
    static let problemReportKindAppLaunch = AppStrings.ios_app_problemreportkindapplaunch()
    static let problemReportKindAppExit = AppStrings.ios_app_problemreportkindappexit()
    static let problemReportKindMetrics = AppStrings.ios_app_problemreportkindmetrics()
    static let problemReportKindUnknown = AppStrings.ios_app_problemreportkindunknown()
    static let problemReportsShare = AppStrings.ios_observer_share()
    static let problemReportsShareHint = AppStrings.ios_app_problemreportssharehint()
    static let problemReportsShareAll = AppStrings.ios_app_problemreportsshareall()
    static let problemReportsShareAllHint = AppStrings.ios_app_problemreportsshareallhint()
    static let problemReportsDelete = AppStrings.ios_app_problemreportsdelete()
    static let problemReportsDeleteHint = AppStrings.ios_app_problemreportsdeletehint()
    static let problemReportsDeleteAll = AppStrings.ios_app_problemreportsdeleteall()
    static let problemReportsDeleteAllHint = AppStrings.ios_app_problemreportsdeleteallhint()
    static let problemReportsDeleteAllConfirmTitle = AppStrings.ios_app_problemreportsdeleteallconfirmtitle()
    static let problemReportsDeleteAllConfirmBody = AppStrings.ios_app_problemreportsdeleteallconfirmbody()
    static let problemReportsMissingTitle = AppStrings.ios_app_problemreportsmissingtitle()
    static let problemReportsMissingBody = AppStrings.ios_app_problemreportsmissingbody()

    static func watchPipelineStaleAsOf(_ relative: String) -> String {
        AppStrings.ios_app_watchpipelinestaleasof("\(relative)")
    }

    // L4.4 placeholders pending owner-facing copy signoff.
    static func watchStatusAsOf(_ relative: String) -> String {
        AppStrings.ios_app_watchstatusasof("\(relative)")
    }
    static let watchStatusUnknownSubtext = AppStrings.ios_app_watchstatusunknownsubtext()
    static let watchStatusUnknownReason = AppStrings.ios_app_watchstatusunknownreason()

    static func watchSavedOnWatchCount(_ n: Int) -> String {
        AppStrings.ios_watch_count_watchsavedonwatchcount(n)
    }

    static func watchSendingCount(_ n: Int) -> String {
        AppStrings.ios_watch_count_watchsendingcount(n)
    }

    static func watchConfirmingCount(_ n: Int) -> String {
        AppStrings.ios_watch_count_watchconfirmingcount(n)
    }

    static func watchAbandonedCount(_ n: Int) -> String {
        AppStrings.ios_watch_count_watchabandonedcount(n)
    }

    static func watchHandedToPhoneCount(_ n: Int) -> String {
        AppStrings.ios_watch_count_watchhandedtophonecount(n)
    }

    static func watchWaitingToSyncFromWatch(_ n: Int) -> String {
        AppStrings.ios_app_watchwaitingtosyncfromwatch_native("\(n)")
    }

    static func watchObservingSentence(elapsedMinutes: Int?) -> String {
        guard let elapsedMinutes, elapsedMinutes >= 1 else {
            return Self.watchObservingSentenceBase
        }
        return AppStrings.ios_app_watchobservingsentence("\(Self.watchObservingSentenceBase)", "\(elapsedMinutes)")
    }

    static func watchSteadyWatchWaitingSentence(_ n: Int) -> String {
        AppStrings.ios_app_watchsteadywatchwaitingsentence_native("\(n)")
    }

    static func watchSteadyPhoneSyncingSentence(_ n: Int) -> String {
        AppStrings.ios_app_watchsteadyphonesyncingsentence_native("\(n)")
    }

    static func watchPresenceLastHeard(relative: String) -> String {
        AppStrings.ios_app_watchpresencelastheard("\(relative)")
    }

    static func watchTodayHandedLine(_ n: Int) -> String {
        AppStrings.ios_app_watchtodayhandedline_native("\(n)")
    }

    static func watchSteadyDetailsSummary(watchWaiting: Int, phoneWaiting: Int) -> String {
        AppStrings.ios_app_watchsteadydetailssummary("\(watchWaiting)", "\(phoneWaiting)")
    }

    static let reinstallNoticeTitle = AppStrings.ios_app_reinstallnoticetitle()
    static let reinstallNoticeBody = AppStrings.ios_app_reinstallnoticebody()
    static let reinstallNoticeKeep = AppStrings.ios_app_reinstallnoticekeep()
    static let reinstallNoticeForget = AppStrings.ios_home_reinstallnoticeforget()

    static let recentEmpty = AppStrings.ios_app_recentempty()
    static let recentFailed = AppStrings.ios_app_recentfailed()
    private static let recentUnavailablePaired = AppStrings.ios_app_recentunavailablepaired()
    private static let recentUnavailableUnpaired = AppStrings.ios_app_recentunavailableunpaired()

    /// The recent list is read from the journal, so without a connection there is nothing to read.
    static func recentUnavailable(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.recentUnavailablePaired : Self.recentUnavailableUnpaired
    }
    private static let notConnectedRowAffordancePaired = AppStrings.ios_app_notconnectedrowaffordancepaired()
    private static let notConnectedRowAffordanceUnpaired = AppStrings.ios_app_notconnectedrowaffordanceunpaired()

    static func notConnectedRowAffordance(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.notConnectedRowAffordancePaired : Self.notConnectedRowAffordanceUnpaired
    }
    static let whatItAdds = AppStrings.ios_app_whatitadds()
    static let pendingSeam = AppStrings.ios_app_pendingseam()
    static let audioEnrollmentValue = AppStrings.ios_app_audioenrollmentvalue()
    static let audioEnrollmentValuePaired = AppStrings.ios_app_audioenrollmentvaluepaired()

    static func audioEnrollmentValue(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.audioEnrollmentValuePaired : Self.audioEnrollmentValue
    }
    static let turnOnAudio = AppStrings.ios_intents_turnonaudio()
    static let importerWhatItAdds = AppStrings.ios_sourcevocabularyswift_addspdfsaudioandtext()
    static let importFilesRow = AppStrings.ios_app_importfilesrow()
    static let importFilesHint = AppStrings.ios_app_importfileshint()
    static let onThisPhone = AppStrings.ios_app_onthisdevice()
    // The row that opens the list, named for what it shows rather than for the
    // section it sits in.
    static let onThisPhoneOpenAction = AppStrings.ios_app_onthisphoneopenaction()
    static let greetingMorning = AppStrings.ios_app_greetingmorning()
    static let greetingAfternoon = AppStrings.ios_app_greetingafternoon()
    static let greetingEvening = AppStrings.ios_app_greetingevening()
    static let dayLocalityNoJournal = AppStrings.ios_app_notpaired()
    static let notPaired = AppStrings.ios_app_notpaired()
    static let journalConnected = AppStrings.ios_app_journalconnected()
    static let journalOffline = AppStrings.ios_app_journaloffline()
    static let dayToday = AppStrings.ios_app_daytoday()
    static let onThisPhoneScope = AppStrings.ios_app_onthisphonescope()
    static let onThisPhoneScopeConnected = AppStrings.ios_app_onthisphonescopeconnected()
    static let onThisPhoneScopeOfflinePaired = AppStrings.ios_app_onthisphonescopeofflinepaired()

    /// The import pane's line about what's on this device, true to whether a journal is paired.
    static func onThisPhoneScope(isJournalPaired: Bool, isConnected: Bool) -> String {
        guard isJournalPaired else { return Self.onThisPhoneScope }
        return isConnected ? Self.onThisPhoneScopeConnected : Self.onThisPhoneScopeOfflinePaired
    }
    static let onThisPhoneEmpty = AppStrings.ios_app_onthisphoneempty()
    static let onThisPhoneTruthLine = AppStrings.ios_app_onthisphonetruthline()
    static let onThisPhoneConnectJournalButton = AppStrings.ios_app_onthisphoneconnectjournalbutton()
    static let onThisPhoneAllQuietHeadline = AppStrings.ios_app_onthisphoneallquietheadline()
    static let onThisPhoneAllQuietBody = AppStrings.ios_app_onthisphoneallquietbody()
    static let onThisPhoneNotBackedUp = AppStrings.ios_app_onthisphonenotbackedup()
    static let onThisPhoneTurnOnSourceButton = AppStrings.ios_app_onthisphoneturnonsourcebutton()
    static let migrationStageOnThisPhone = AppStrings.ios_app_onthisdevice()
    static let migrationStageOnItsWay = AppStrings.ios_location_onitsway()
    static let migrationStageInYourJournal = AppStrings.ios_app_inyourjournal()
    static let migrationHeadlineUpToDate = AppStrings.ios_app_migrationheadlineuptodate()
    static let syncingPulse = AppStrings.ios_app_syncingtoyourjournal()
    static let syncedHeadline = AppStrings.ios_app_syncedheadline()
    static let syncedBody = AppStrings.ios_app_syncedbody()
    /// Something shared will not reach the journal. The pill and the widgets use the headline.
    /// The day line says which day, and it clears once that status has been looked at.
    static let journalGapHeadline = AppStrings.ios_app_journalgapheadline()
    static let journalGapToday = AppStrings.ios_app_journalgaptoday()
    static let journalGapYesterday = AppStrings.ios_app_journalgapyesterday()
    static let journalGapUndated = AppStrings.ios_app_journalgapundated()

    static func journalGapOn(weekday: String) -> String {
        AppStrings.ios_app_journalgapon("\(weekday)")
    }

    static func journalGapSince(earliest: String) -> String {
        AppStrings.ios_app_journalgapsince("\(earliest)")
    }
    static let offlineSafeLine = AppStrings.ios_app_onthisdevice()
    static let magicMomentShownHeadline = AppStrings.ios_app_magicmomentshownheadline()
    static let magicMomentShownBody = AppStrings.ios_app_magicmomentshownbody()
    static let magicMomentShownBodyPaired = AppStrings.ios_app_magicmomentshownbodypaired()

    static func magicMomentShownBody(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.magicMomentShownBodyPaired : Self.magicMomentShownBody
    }
    static let magicMomentShownSecondary = AppStrings.ios_app_magicmomentshownsecondary()
    static let magicMomentPendingHeadline = AppStrings.ios_app_magicmomentpendingheadline()
    static let magicMomentPendingBody = AppStrings.ios_app_magicmomentpendingbody()
    static let yourJournalSection = AppStrings.ios_liveactivity_yourjournalsection()
    static let details = AppStrings.ios_app_details()
    static let notProvided = AppStrings.ios_watch_notprovided()
    static let originAppNotProvided = AppStrings.ios_app_originappnotprovided()
    static let rawOriginalUnavailable = AppStrings.ios_app_raworiginalunavailable()
    static let openJournalLink = AppStrings.ios_app_openjournallink()
    static let openInJournal = AppStrings.ios_app_openinjournal()
    static let journalTunnel = AppStrings.ios_app_journaltunnel()
    static let transferRateLabel = AppStrings.ios_app_transferratelabel()
    static let transferRateIdle = AppStrings.ios_app_transferrateidle()
    static let lastSyncedLabel = AppStrings.ios_app_lastsyncedlabel()
    static let checkConnection = AppStrings.ios_app_checkconnection()
    static let probeReachable = AppStrings.ios_app_reachable()
    static let probeNotReachable = AppStrings.ios_app_notreachable()
    static let onThisPhoneJournalHintSaved = AppStrings.ios_app_onthisphonejournalhintsaved()
    static let onThisPhoneJournalHintLocationSaved = AppStrings.ios_app_onthisphonejournalhintlocationsaved()
    static let onThisPhoneJournalHintPending = AppStrings.ios_app_onthisphonejournalhintpending()
    static let onThisPhoneJournalHintUnreachable = AppStrings.ios_app_onthisphonejournalhintunreachable()
    static let onThisPhoneJournalHintLocationUnreachable = AppStrings.ios_app_onthisphonejournalhintlocationunreachable()
    static let onThisPhoneDropFromPhone = AppStrings.ios_app_onthisphonedropfromphone()
    static let onThisPhoneDropConfirmTitle = AppStrings.ios_app_onthisphonedropconfirmtitle()
    static let onThisPhoneFileLabel = AppStrings.ios_app_onthisphonefilelabel()
    static let onThisPhoneWhenLabel = AppStrings.ios_app_onthisphonewhenlabel()
    static let onThisPhoneObservationsLabel = AppStrings.ios_app_onthisphoneobservationslabel()
    static let onThisPhoneSourceLabel = AppStrings.ios_intents_onthisphonesourcelabel()
    static let onThisPhoneFailureReasonLabel = AppStrings.ios_app_onthisphonefailurereasonlabel()
    static let onThisPhoneFailureStatusLabel = AppStrings.ios_app_status()
    static let onThisPhoneObserverAudioSourceLabel = AppStrings.ios_app_audio()
    static let onThisPhoneWatchAudioSourceLabel = AppStrings.ios_app_onthisphonewatchaudiosourcelabel()
    static let onThisPhoneFailureRowHint = AppStrings.ios_app_onthisphonefailurerowhint()
    static let audioPlaybackObserverActiveHint = AppStrings.ios_app_audioplaybackobserveractivehint()
    static let audioPlaybackPlayLabel = AppStrings.ios_app_audioplaybackplaylabel()
    static let audioPlaybackPauseLabel = AppStrings.ios_app_audioplaybackpauselabel()
    static let audioPlaybackHint = AppStrings.ios_app_audioplaybackhint()
    static let connectDoorOwnTitle = AppStrings.ios_app_yourownjournal()
    static let connectDoorOwnSubtitle = AppStrings.ios_app_connectdoorownsubtitle()
    // VPX: functional placeholders pending product voice review.
    static let pairingLinked = AppStrings.ios_app_pairinglinked()
    static let pairingAlreadyConnected = AppStrings.ios_app_pairingalreadyconnected()
    static let pairingReconnected = AppStrings.ios_app_pairingreconnected()
    static let pairingStillTrying = AppStrings.ios_app_pairingstilltrying()
    static let journalMarkConfirmQuestion = AppStrings.ios_app_journalmarkconfirmquestion()
    static let journalMarkConfirmSubtext = AppStrings.ios_app_journalmarkconfirmsubtext()
    static let journalMarkConfirmButton = AppStrings.ios_app_journalmarkconfirmbutton()
    static let journalMarkMismatchButton = AppStrings.ios_app_journalmarkmismatchbutton()
    static let awaitingMarkConfirmationLine = AppStrings.ios_app_awaitingmarkconfirmationline()
    static let awaitingMarkConfirmationSubline = AppStrings.ios_app_awaitingmarkconfirmationsubline()
    static let confirmTheMarkAction = AppStrings.ios_app_confirmthemarkaction()
    static let journalMarkConfirmedLine = AppStrings.ios_pairing_confirmed_generic()
    static let journalMarkConnecting = AppStrings.ios_app_connecting()
    static let journalMarkMismatchTitle = AppStrings.ios_app_notpaired()
    static let journalMarkMismatchBody = AppStrings.ios_sourcevocabularyswift_nothingthisdevicehaskept()
    static let journalMarkAnswerNotSaved = AppStrings.ios_sourcevocabularyswift_couldntsaveyouranswertry()
    static let journalMarkTeardownFailed = AppStrings.ios_sourcevocabularyswift_couldntdisconnectthisdeviceyet()
    static let journalShelfDeviceCertificateLabel = AppStrings.ios_sourcevocabularyswift_thisdevicescertificate()
    static let journalMarkMismatchScanAgain = AppStrings.ios_app_journalmarkmismatchscanagain()
    static let journalMarkMismatchEmailSupport = AppStrings.ios_app_journalmarkmismatchemailsupport()
    static let journalMarkCouldNotVerifyTitle = AppStrings.ios_app_journalmarkcouldnotverifytitle()
    static let journalMarkCouldNotVerifyBody = AppStrings.ios_app_journalmarkcouldnotverifybody()
    static let journalMarkCouldNotVerifyContinue = AppStrings.ios_app_journalmarkcouldnotverifycontinue()
    static let journalMarkCouldNotVerifyCancel = AppStrings.ios_app_journalmarkcouldnotverifycancel()
    static let journalMarkCouldNotVerifyContinueAccessibility = AppStrings.ios_app_journalmarkcouldnotverifycontinueaccessibility()
    static let journalMarkCouldNotVerifyCancelAccessibility = AppStrings.ios_app_journalmarkcouldnotverifycancelaccessibility()
    static let rePairLine = AppStrings.ios_app_repairline()
    static let rePairAction = AppStrings.ios_sourcevocabulary_repair()
    static let journalLivesTitle = AppStrings.ios_app_journallivestitle()
    static let journalLivesOwnTitle = AppStrings.ios_app_yourownjournal()
    static let journalLivesOwnBody = AppStrings.ios_app_journallivesownbody()
    static let journalLivesConnectAction = AppStrings.ios_app_journallivesconnectaction()
    static let journalLivesRepairAction = AppStrings.ios_sourcevocabulary_repair()
    // The setup doors: one view behind every no-journal entry (home pill, shelf, iPad pane,
    // status, welcome, the journal pane). The lead follows the mark, so "it" is your journal.
    static let journalSetupLead = AppStrings.ios_sourcevocabularyswift_todayitlivesona()
    static let journalSetupNewTitle = AppStrings.ios_sourcevocabularyswift_setupajournal()
    static let journalSetupOpenPage = AppStrings.ios_sourcevocabularyswift_openthesetuppage()
    static let journalSetupShareLink = AppStrings.ios_sourcevocabularyswift_sendyourselfthelink()
    static let journalSetupHaveOneTitle = AppStrings.ios_sourcevocabularyswift_ialreadyhaveone()
    static let journalSetupHaveOneSubline = AppStrings.ios_sourcevocabularyswift_scanitspairingcode()
    static let journalSetupDataLine = AppStrings.ios_sourcevocabularyswift_whatyousharestayson()

    static func journalLivesAction(isPaired: Bool) -> String {
        isPaired ? journalLivesRepairAction : journalLivesConnectAction
    }

    static func transferRateValue(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB]
        return AppStrings.ios_transfer_rate(formatter.string(fromByteCount: Int64(bytesPerSecond)))
    }

    static let drop = AppStrings.ios_app_drop()
    static let cancel = AppStrings.ios_migration_picker_cancel()
    static let undo = AppStrings.ios_app_undo()
    static let turnOn = AppStrings.ios_app_turnon()
    static let pause = AppStrings.ios_photolibrary_pause()
    static let resume = AppStrings.ios_photolibrary_resume()

    static func offSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.offSubtextPaired : Self.offSubtextUnpaired
    }

    static func enrollingSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.enrollingSubtextPaired : Self.enrollingSubtextUnpaired
    }

    static func onThisPhoneAgedBacklog(count: Int) -> String {
        if count == 1 {
            return AppStrings.ios_app_onthisphoneagedbacklog_native()
        }
        return AppStrings.ios_sourcevocabularyswift_memoriesareonthisdevice_native("\(count)")
    }

    static func onThisPhoneLocationRowLabel(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabulary_n710(count, "\(count)")
    }

    static func onThisPhoneDropSnackbar(descriptor: String) -> String {
        AppStrings.ios_app_onthisphonedropsnackbar("\(descriptor)")
    }

    static func onThisPhoneDropAudioDescriptor(duration: String) -> String {
        AppStrings.ios_app_ofaudio("\(duration)")
    }

    static func onThisPhoneDropLocationDescriptor(count: Int) -> String {
        AppStrings.ios_app_onthisphonedroplocationdescriptor_native("\(count)")
    }

    static let onThisPhoneDropScreencastDescriptor = AppStrings.ios_app_onthisphonedropscreencastdescriptor()

    static func onThisPhoneNavigationTitle(source: String, shortTime: String?) -> String {
        guard let shortTime else { return source }
        return AppStrings.ios_frame_sourcevocabulary_n729("\(source)", "\(shortTime)")
    }

    static func onThisPhoneAudioSummary(duration: String) -> String {
        AppStrings.ios_app_ofaudio("\(duration)")
    }

    static func onThisPhoneLocationSummary(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabulary_n737(count, "\(count)")
    }

    static func onThisPhoneObservedSummary(relativeDay: String?, shortTime: String?) -> String {
        guard let datePhrase = self.onThisPhoneDatePhrase(relativeDay: relativeDay, shortTime: shortTime) else {
            return AppStrings.ios_app_onthisdevice()
        }
        return AppStrings.ios_app_onthisphoneobservedsummary("\(datePhrase)")
    }

    static func onThisPhoneShareSummary(originApp: String?, relativeDay: String?, shortTime: String?) -> String {
        let origin = originApp.flatMap { $0.isEmpty ? nil : $0 }
        let datePhrase = self.onThisPhoneDatePhrase(relativeDay: relativeDay, shortTime: shortTime)
        switch (origin, datePhrase) {
        case (.some(let origin), .some(let datePhrase)):
            return AppStrings.ios_app_onthisphonesharesummary2("\(origin)", "\(datePhrase)")
        case (.some(let origin), .none):
            return AppStrings.ios_app_onthisphonesharesummary("\(origin)")
        case (.none, .some(let datePhrase)):
            return datePhrase
        case (.none, .none):
            return Self.notProvided
        }
    }

    /// The file row. An unknown size is left out rather than spelled "not provided".
    static func onThisPhoneFileDetail(filename: String, size: String?) -> String {
        guard let size else { return filename }
        return AppStrings.ios_frame_sourcevocabulary_n765("\(filename)", "\(size)")
    }

    static func onThisPhoneFailureAttemptStatus(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabulary_n769(count, "\(count)")
    }

    static func onThisPhoneFailureRetryableMessage(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabulary_n774(count, "\(count)")
    }

    /// For an item the journal turned away that is not sent again on every reconnect.
    static let onThisPhoneRefusalPacedMessage = AppStrings.ios_app_onthisphonerefusalpacedmessage("\(tryNow)")

    static func onThisPhoneFailurePermanentMessage(reason: String) -> String {
        AppStrings.ios_app_onthisphonefailurepermanentmessage("\(reason)")
    }

    static let onThisPhoneFailureReasonNetwork = AppStrings.ios_app_onthisphonefailurereasonnetwork()
    static let onThisPhoneFailureReasonTimeout = AppStrings.ios_app_onthisphonefailurereasontimeout()
    static let onThisPhoneFailureReasonServer = AppStrings.ios_app_onthisphonefailurereasonserver()
    static let onThisPhoneTryNowFailed = AppStrings.ios_app_onthisphonetrynowfailed()
    static let onThisPhoneFailureReasonUnknown = AppStrings.ios_app_onthisphonefailurereasonunknown()

    static func onThisPhoneFailureLastTried(datePhrase: String) -> String {
        AppStrings.ios_app_onthisphonefailurelasttried("\(datePhrase)")
    }

    static func onThisPhoneFixCount(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabulary_n796(count, "\(count)")
    }

    static func migrationHeadlineSyncing(count: Int) -> String {
        AppStrings.ios_plural_sourcevocabulary_n801(count, "\(count)")
    }

    static func lastActiveLine(relative: String) -> String {
        AppStrings.ios_app_lastactiveline("\(relative)")
    }

    static func migrationStageCount(_ count: Int, stage: String) -> String {
        AppStrings.ios_frame_sourcevocabulary_n806("\(count)", "\(stage)")
    }

    private static func onThisPhoneDatePhrase(relativeDay: String?, shortTime: String?) -> String? {
        guard let relativeDay else { return nil }
        guard let shortTime else { return relativeDay }
        return AppStrings.ios_app_at("\(relativeDay)", "\(shortTime)")
    }
}

#if !os(watchOS) && !SOLSTONE_LIVE_ACTIVITY_WIDGET
extension SourceVocabulary {
    nonisolated static func onThisPhoneDropConfirmMessage(sendState: OnThisPhoneSendState) -> String {
        switch sendState {
        case .savedOnThisPhone, .sending, .needsAttention:
            return AppStrings.ios_app_onthisphonedropconfirmmessage2()
        case .inYourJournal:
            return AppStrings.ios_app_onthisphonedropconfirmmessage()
        }
    }

    nonisolated static func onThisPhoneSourceName(for sourceKind: OnThisPhoneSourceKind) -> String {
        switch sourceKind {
        case .audio:
            AppStrings.ios_app_audio()
        case .location:
            AppStrings.ios_location_sourcedisplayname()
        case .screencast:
            AppStrings.ios_brand_broadcastname()
        // Shared and picked items both arrive through import, so they carry its name.
        case .share:
            Self.importTitle
        case .calendar:
            Self.calendarTitle
        case .obsidian:
            Self.obsidianTitle
        }
    }
}
#endif
