# Journal gap notice

One store and one reader. Kind comes from the outcome, never the reason code. A loss is material that existed and will not reach the journal. A diagnostic is a fault, or a publish of audio that did exist as a recording. Legacy is an imported interruption record. Empty files and absent files are not losses. The notice reads losses only.

## Existed

No decoder. No `AVURLAsset`. No `classifyAudioContainer`. Do not scan `*.sb-*` sidecars. The file the delete names is the only file. A 0-byte part stays not existed even when a sibling sidecar holds bytes (`ScreencastBroadcastAudioWriter` writes the part URL the delete names).

Pure helpers, tested without a writer. Walk top-level ISO-BMFF boxes: an 8-byte header, or 16 bytes when the size field is 1. Leading `ftyp`, then `free` / `skip` / `wide`, then `moov` when it sits before the first `mdat` or `moof`, are the header. Payload is the sum of `mdat` contents (box size minus its header). A `moof` is not payload. A walk that fails, or a file that ends mid-box, is undelimited.

File size 0 is not existed. That is the empty file every live `AVAssetWriter` leaves on the output URL. `writeFtypOnlyAudio` is 24 bytes, one `ftyp`, payload 0: not existed. A bare `ftyp` of any size is not existed. The phone writer's `ftyp` is 28 bytes.

Phone `audio.m4a` existed when the phase is `.completed` or `.faulted` and `acceptedFrames > 0`, or when `mdat` payload is at least 4 bytes, or when the walk is undelimited and the file size is greater than 0. A `.writing` receipt contributes 0 frames even when the stored number is non-zero. An absent receipt contributes 0 frames. The measured minimum complete AAC sample at 16 kHz, mono, 32 kbps is 4 bytes. The unfinished phone file after the writer is released (48 bytes: `ftyp` 28 + `wide` 8 + `mdat` 12, payload 4) is existed. The finished zero-PCM container's priming samples are payload and count as existed. The diagnostic fixtures are the header-only file and the ftyp-only file, not that container. When the header cannot be delimited, existed means larger than the empty file from that writer, and the empty file is 0 bytes. A walk that succeeds with `mdat` payload under 4 and no accepted frames is not existed. A bare `ftyp` delimits and is not existed.

Screen `mp4` and screen-audio `m4a` existed when `mdat` payload is at least 1 byte. Undelimited and size greater than 0: existed. Payload 0: not existed.

`.completed` with 0 frames stays `.retryableUnresolved` (`MobileSegmentUploader.deriveAudioArtifact`, `Sources/MobileSegment/MobileSegmentUploader.swift:1081`). The file stays. No event, including when the bytes would otherwise count.

`fileSize == nil` is not 0. `finalizeActiveSegment` today treats a nil size as 0 and deletes (`MobileSegmentUploader.swift:737`). Leave the promoted `audio.m4a` in place and write no event.

## Store

Directory: `AppGroupContainer.rootURL()/JournalEvents/`. Not inside `MobileSegment`. Not in Caches. The app and the broadcast extension both use it. The extension already has the app group (`SolstoneBroadcastExtension/SolstoneBroadcastExtension.entitlements`). `clearPairing` does not delete the directory. Pruning deletes only files inside it.

The store and the box walker live in app sources and are listed on the broadcast extension target in `project.yml`, next to `ScreencastBroadcastAudioWriter.swift`. The extension does not take the uploader.

One file per event, one file per seen mark. Atomic replace of that file only: write a temp in the same directory, then replace.

| Path | Role |
| --- | --- |
| `losses/<segmentUUID>-<source>.json` | Loss. Key is segment + source. A second write leaves the first row. `foundAt` stays. |
| `diagnostics/<segment or none>-<source>-<reason>.json` | Diagnostic or legacy. Key is kind + segment + source + reason. The same key updates that file only: count, first, last, aggregated detail. |
| `seen/<event id>.json` | Seen mark. The event id is the loss file's stable key (`<segmentUUID>-<source>`). Marking seen never writes an event file. A diagnostic's seen mark, used when the journal changes, uses that diagnostic file's stable key. |
| `gate.json` | First open time. Absent means closed. |
| `import.json` | Absent means not run. `complete` carries N and M. `failed` carries a reason. |
| `journal-identity.json` | The `journalVersionMetadataIdentity(for:)` string, or `unknown`. |
| `aside/` | Undecodable bytes, moved here under a new name. Never overwritten. |

A loss and a diagnostic for the same segment are two files. A loss does not remove a diagnostic. A diagnostic never removes a loss.

Record fields: id, kind (`loss`, `diagnostic`, `legacy`), source (`audio`, `screencast`, `screen-audio`), reason, segment id or none, `foundAt`, `lastAt`, `captureAt` or none, count, detail. Legacy counts as a diagnostic for the cap and is never a notice. Writers pass the segment's `startedAt` as `captureAt` when they have it, and none when they do not.

Decode failure after a successful read: move the file to `aside/` under a new name, log a diagnostic line, keep going. `Data(contentsOf:)` throwing is not corruption. Any read error, including protected data (`NSFileReadNoPermissionError`, Cocoa 257) and POSIX `EACCES`, leaves the file in place and omits it from that read. A later read that succeeds returns it. No seen mark is written for a file this read could not read. If the directory cannot be listed, the store is unreadable: the notice shows nothing, the diagnostics section says the journal events could not be read, and no seen mark is written.

## Writers

`recordLoss` throws. The caller deletes or retires only after it returns. A throw leaves the file or the segment where it is.

`recordDiagnostic` does not throw into a publish, an upload, a delete, or a fault. The caller logs and continues. A failed diagnostic write still deletes on a delete path and still publishes on a publish path.

While `gate.json` is absent, `recordLoss` also writes that loss's seen file. After `gate.json` exists, it does not. The check is the presence of `gate.json` at the moment of that write. No scan at open time. The extension does not create `gate.json`.

Collapse is the diagnostic update. The same kind, source, reason, and segment update one file. No segment collapses only with no segment. Detail sums interruption duration, and counts configuration-change restart successes and failures. `foundAt` stays. `lastAt` moves. Count increments. A day of began/ended every 30 seconds is two rows, because the reasons differ. A writer fault and a later publish are two diagnostic rows even when the reason text matches. The latch-fault file is `diagnostics/<segment>-audio-<reason>-fault.json`. The publish file is `diagnostics/<segment>-audio-<reason>.json`. Repeated faults collapse on the fault file. Repeated publishes collapse on the publish file. The diagnostics text prints the reason code, not the `-fault` suffix.

## Gate

A pass is `MobileSegmentUploader.resumeFromDisk` returning without having seen `Task.isCancelled`. `MobileSegmentEngine.resumeFromDisk` (`Sources/MobileSegment/MobileSegmentEngine.swift:72`) is that function. Callers:

- Launch maintenance: `resumeMobileSegments` (`Sources/SolstoneSwiftApp.swift:652`), and `migrateLegacyMobileItems` (`MobileSegmentUploader.swift:1419`), which ends in the same function (`:1431`).
- `bootstrapTransfer`'s reconcile (`SolstoneSwiftApp.swift:1157`).
- `driveUploadDrain` (`Sources/Background/BackgroundDrainCoordinator.swift:44`), used by finish-syncing (`SolstoneSwiftApp.swift:602`), the foreground drain (`:625`), and the background drain (`:997`).

Any one non-cancelled completion opens the gate. `guardStorageAvailable` failing (`MobileSegmentUploader.swift:807`) does not. Opening is idempotent: write `gate.json` with the first open time only if the file is absent.

Cancelled exits return the way `:811` does: refresh counts, return, do not open the gate. That includes the pending-loop `break`s at `:830` and `:832`. Today those breaks leave the loop and fall through to the normal return at `:841`. They must not. The same early return applies to a cancel inside import and inside `performReconcileActiveSegments` (`:2091`, `:2130`). The `catch` at `:836` (`mobile segment resume failed stage=resume`) falls through and does open the gate.

On `--ui-test`, launch maintenance does not run (`shouldRunLaunchMaintenance`, `SolstoneSwiftApp.swift:146`) and the background drain returns before `driveUploadDrain` (`:971`). Bootstrap's reconcile is the pass that opens the gate.

Import runs at the start of the pass, where `backfillAudioInterruptionsIfNeeded` is now (`:810`), after storage is available and after `ensureRoot`. Import failure is stored, logged, and does not throw out of the pass. The gate still opens. A cancel during import writes neither `complete` nor the gate, and returns like `:811`. The next launch retries while `import.json` is not `complete`. A complete import is not repeated. Calling import twice in a test adds nothing.

Delete `backfillAudioInterruptionsIfNeeded`, `hasBackfilledAudioInterruptions`, and the `.backfilled` marker (`MobileSegmentStore.swift:335`).

Sequence. Scene `.active` starts a pass. Scene `.background` cancels launch maintenance (`SolstoneSwiftApp.swift:966`). A pass that saw `Task.isCancelled` returns without the gate. The next `.active` runs another pass (`LaunchMaintenanceCoordinator.swift:40`, because `hasCompleted` is still false). That later return, if it did not see `Task.isCancelled`, writes `gate.json` once. The `catch` at `:836` is enough. A second completion finds `gate.json` and does not rewrite it.

## Import

Read, and delete nothing, under the App Group `MobileSegment` root and under Caches `MobileSegment`:

- `interruptions/audio/*.json`
- Empty tombstones whose reason is `audio_undecodable_container`
- Manifests in active, pending, and failed whose `audio.reason` is that string

Tombstones stay. Caches files stay. The import does not delete the Caches root.

Kind `legacy`. Keep the original reason and time (`recordedAt` becomes `foundAt` and `lastAt`; `captureAt` is none). Identity is `legacy|<segment>|<reason>|<recordedAt>`. The same identity from a tombstone and an interruption file is one row. A file that does not decode is skipped, M increments, a diagnostic line is logged, and the file stays. N is how many rows this run wrote.

`import.json`: absent means not run; `complete` with N and M; `failed` with a reason. Production code stops calling `writeAudioInterruption` and `writeAudioInterruptionAtomic`. A legacy fixture writes the JSON file itself.

## Pairing

Seed `journal-identity.json` on first use, when the file is absent, from the current pairing, or `unknown` when there is none. Do this from app startup after the pairing is loaded (`SolstoneSwiftApp` builds `AppConfig` before the scene). Do not do it from `clearPairing`. A later startup does not rewrite a file that is already there.

`finishPairingClear` (`Sources/Services/AppConfig.swift:203`) keeps wiping `journalVersionMetadata` (`JournalVersionMetadata.clear`, `Sources/Services/JournalVersionMetadata.swift:106`) and must not touch `journal-identity.json` or `JournalEvents/`.

On `reflectCommittedPairing` (`AppConfig.swift:145`) and `applyMigratedPairing` (`:154`): if the stored identity is `unknown` or equal to `journalVersionMetadataIdentity(for:)`, store the new string and mark nothing. If it is a different known identity, mark every event seen (every loss, and every diagnostic and legacy row), then store the new string.

## Retention

30 days from `foundAt`. Caps: 500 losses, 1000 diagnostics including legacy. Oldest first. An unseen loss whose found day is today or one of the previous 6 local calendar days is never removed, by age or by the cap. Nothing outside `JournalEvents/` is removed. Run prune after a write and before a notice read.

The window is `startOfDay(found) >= startOfDay(now)` minus 6 calendar days, via `Calendar.date(byAdding: .day, value: -6, to: startOfDay(now))`. Not `addingTimeInterval`. Use the owner's calendar and time zone.

## Notice reader

One function. The result is the unseen losses when the gate is open, the store is readable, and the found day is in the window. Otherwise the result is absent and the pill stays on today's caught-up / connected branch. Recompute the window when the scene becomes active (`SolstoneSwiftApp.swift:911`), even if no file changed. The open status keeps its captured lines until the next visit. The pill and the widgets follow this function.

Day line, from the capture day of those losses only:

- Any nil `captureAt`, or any capture day more than 6 calendar days ago: `some of what you shared didn't reach it.`
- One capture day, today: `some of what you shared today didn't reach it.`
- One capture day, yesterday: `some of what you shared yesterday didn't reach it.`
- One capture day, 2 through 6 days ago: `some of what you shared on <weekday> didn't reach it.`
- More than one capture day, all inside 6 days: `some of what you shared since <earliest> didn't reach it.` The earliest word is `yesterday` or the weekday. Never `since today`. Never `on today`.

Weekday spelling is a fixed English list indexed by the calendar's weekday component: index 1 `sunday` through index 7 `saturday`. Do not use `weekdaySymbols`.

Locked headline, pill and widgets: `there's a gap in your journal`.

Both strings live in `SourceVocabulary` where `audioInterruptedHeadline` and `audioInterruptedLine` are now (`Sources/SourceVocabulary.swift:562`). Delete those two from `Sources/` and from every extension that compiles that file (the share extension and the live-activity widget). No string catalog in the tree contains them. `CHANGELOG.md` history may keep them (`CHANGELOG.md:118`). Accessibility label equals the visible text. Do not set a different label.

## Surfaces

Replace the `.audioInterrupted` branch in place. Rename the pill case `journalGap`. Same slot in `HomeStatusPillState.resolve` (`Sources/Home/HomeStatusPill.swift:30`): paired, connected idle / waiting / transferring, not stalled, not awaiting the mark, no backlog. Otherwise the existing state wins. The dot stays `.secondary` (`:139`) and `shouldPulse` stays false (`:86`). The connection row stays `connected` (`StatusPane.swift:250`).

Status (`StatusPaneLead.resolve`, `Sources/Home/StatusPane.swift:177`): when the pill is `journalGap`, the lead is the headline plus the day line, and the beside-notice is not drawn. When the pill is another state and the reader still has losses, the headline plus the day line sit beside that lead. With nothing waiting, the gap replaces `all caught up` (`SourceVocabulary.syncedHeadline`) rather than sitting next to it.

On this device: the gap replaces the up-to-date headline only (`onThisPhoneHeadline` role `.upToDate`, and the empty `.allQuiet` branch). Same two strings. No other on-this-device row changes.

Rename the `audioInterrupted` accessibility identifiers to `journalGap` in the pill's UI-test state name, the status notice, and the on-this-device notice.

## Visit

State lives in a model owned by the shell, not in view identity. Rotation recreates the status view and must not start or end a visit. Do not end a visit from `onDisappear`.

A status surface that is already visible before any loss exists does not capture an empty visit. The visit starts when that visible surface first has losses to show, and those ids are marked. A loss that arrives after a non-empty capture stays unseen until the next visit. Foreground, pill selection, and leaving and returning start a new visit. Rotation and `onDisappear` do not.

A visit starts when the status content becomes visible in the foreground and has losses to show, when the scene becomes active while that content is visible and has losses to show, when on-this-device is showing the notice, or when the status pill is selected again (`RootShellView.openStatus`, `:472`).

Phone status is the sheet `isStatusPresented` (`RootShellView.swift:487`, `presentedPane == .status`). iPad status is the detail pane. The paired default is `.status` (`ShellNavModel.defaultPane`, `Sources/Home/ShellNavModel.swift:60`). On-this-device is `OnThisPhoneView`, pushed by the view-destination link in `ImportView.swift:104`. Give that push a navigation-path value so the model can see it leave. `onDisappear` is not that signal.

At the start of a visit, if the gate is open and the surface has losses to show, mark seen exactly the loss ids the notice is displaying. A closed gate, an empty window, or a surface that is already visible before any loss exists marks nothing and does not freeze an empty set. The first moment the visible surface is showing losses, with the gate open, captures that set and marks it. Those ids stay on screen until the next visit, including after the seen files exist, so the open status keeps the headline and the day line while the pill and the widgets follow the live reader. A loss written after that non-empty capture is shown and is not marked until the next visit.

A new visit replaces the captured set with a fresh read. End the visit when the phone sheet binding goes false, or when the resolved pane root and `paneStack` no longer show status, or when on-this-device leaves its navigation path. Selecting the status pill again is a new visit. Scene inactive does not end a visit. Scene active while the content is still visible starts one if none is in progress, and does not replace a set already captured.

A failed seen write leaves that loss unseen. A seen file survives relaunch.

iPad sequence, paired, seeded loss. The default detail is already visible before bootstrap's reconcile returns, so the reader is absent and nothing is marked. After the gate opens, the seed writes the loss, and the detail shows the notice. That is the visit: mark that loss, keep it on screen. Leaving the detail ends the visit. Returning starts a new visit, the reader is empty, and the detail shows caught up.

## Widgets

Keep `AppGroupMirror.Snapshot.currentSchemaVersion` at 1 (`Sources/Services/AppGroupMirror.swift:31`). Add `journalGap: Bool`. A missing key decodes false. Stop encoding and reading `audioInterrupted`. A snapshot that only has the old key is not a gap. `maximumAge` stays 60 seconds (`:32`).

Symbol `calendar.badge.minus` on the gap presentation. If that symbol is absent from the SDK, use `minus.circle`. Remove `waveform.badge.exclamationmark` with the old case (`Sources/Widgets/ObserverStatusPresentation.swift:46`). Rename the case `journalGap`. Same precedence each presentation already has. Small and medium keep the needs-attention check ahead of the gap. Circular gains no needs-attention branch (`:129`).

`DayHomeView.appGroupSnapshotInputs` (`Sources/Home/DayHomeView.swift:270`) includes the reader's flag in place of `hasAudioInterruption`, and the existing `.task(id:)` (`:240`) rewrites `observer-status.json`. No new writer. `ObserverCaptureControlMirrorWriter` and `ObserverCaptureIntent` (`Sources/AppIntents/ObserverCaptureIntent.swift:98`) copy `journalGap` instead of the old bool.

## Paths

Implement this table exactly.

1. `removeAudioArtifactPermanent` (`MobileSegmentUploader.swift:959`) from the three `deriveAudioArtifact` arms. Absent receipt, reason `audio_undecodable_container` (`:1038`). `.writing`, reason `audio_capture_unfinished` (`:1058`). `.faulted`, receipt reason or `audio_writer_failed` (`:1074`). Loss if existed, diagnostic if not. Loss is written before `removeIfExists`. A loss throw skips the delete. Diagnostic failure still deletes.
2. Publish arms. `.writing` or `.faulted` with usable duration (`:1052`, `:1068`). `.completed` mismatch, reason `audio_writer_duration_mismatch` (`:1090`). Diagnostic, then publish. No deletion twin for the mismatch. `.completed` with a permanent, missing, zero, or transient inspection stays `.retryableUnresolved` (`:1097`). Diagnostic failure still publishes.
3. `PhoneAudioFragmentWriter.latchFault` (`Sources/Observer/PhoneAudioFragmentWriter.swift:558`). Diagnostic at fault time, keyed by segment, source `audio`, and the fault reason. A failed diagnostic write does not block the fault. `handlePhoneAudioFault` (`Sources/Observer/ObserverManager.swift:498`) does not write a second event. A later loss is the other file.
4. `resolveFinalizeFailure` screencast arm (`MobileSegmentUploader.swift:1214`), reason `screencast_removed`. One `screencast` event if either `screen.mp4` or the part existed (loss), or a diagnostic if a file was present and not existed. Absent files: no event. A loss throw deletes neither.
5. `finalizeActiveSegment` (`:613`) and `performReconcileActiveSegments` (`:2273`) delete `screen.mp4.part` when `probeContainerDuration` is nil or not greater than 0. The probe stays the delete trigger. Existed decides the kind. Source `screencast`, reason `screencast_unplayable_part`. Loss before delete. A present empty or header-only file: diagnostic, then delete. Absent: no event. A loss throw does not delete.
6. The same function, `screen-audio.m4a.part` (`:731`), same rule, source `screen-audio`. Promoted `audio.m4a` is removed only when the size is known and 0 (`:762`): diagnostic if the file is present, then delete. Size nil: leave it, no event.
7. `.missingFile` (`:1001`) then `audio_no_local_data` (`:1230`) before upload or retire. Loss if a completed or faulted receipt has `acceptedFrames > 0`. Diagnostic if there is no receipt or zero frames. A loss throw does not upload and does not retire (`:1266`, `:1284`). The reconcile arm that only marks `.failedToFinalize` (`:2185`, or the 60-second deferral at `:2181`) writes no event.
8. `dropSegment` (`:1292`). No event. An empty `audio_undecodable_container` tombstone is not a notice.
9. `redactScreencastFacet` (`:1313`), including a following retire. No event.
10. `retireDeliveredResidue` (`:1885`), `retireDeliveredResidue(segmentID:)` (`:1899`), and `writeUploadedTombstone` (`:1307`). No event.
11. `retireTransferOwnedResidue` (`:1905`), enqueue `store.remove` (`:1873`), temp cleanup (`:1858`, `:2044`, `:2054`), and `quarantinePendingDirectory` (`:2064`). No event.
12. `migrateRoot` / `migrateRootItem` (`MobileSegmentStore.swift:438`, `:515`). No event. The import does not delete the Caches root.
13. Guarded rollback `store.remove` (`MobileSegmentEngine.swift:871`) when there is no audio file, no receipt, and no lease. No event. The `catch` at `:954` is the same remove without that proof. Apply the proof. If the directory cannot be listed, do not remove. If a phone-audio lease is held, do not remove. If audio, screen, or screen-audio existed, one loss per existed source, then remove. A loss throw does not remove. If nothing existed and the proof holds (no audio file, no receipt, no lease), remove with no event. A present audio file or receipt that did not exist blocks that remove and writes no event. A present screen file that did not exist does not block it and writes no event.
14. `recordAudioFinalized` when `duration < 0.1` (`MobileSegmentUploader.swift:230`). The threshold stays 0.1 (`MobileSegmentEngine.swift:185`, `:814`, `:832`). Duration is `acceptedFrames / 16000`. Loss if existed, before the delete. A loss throw does not delete and does not write the `noArtifact` outcome. Not existed: diagnostic, then delete, then the `noArtifact` outcome. The move onto canonical `audio.m4a` (`:246`) is the file that stays. No event for that replace.
15. `ScreencastBroadcastWriter.open` (`SolstoneBroadcastExtension/ScreencastBroadcastWriter.swift:55`) and `ScreencastBroadcastAudioWriter.open` (`Sources/MobileSegment/ScreencastBroadcastAudioWriter.swift:45`) delete an existing part. Video `finish` deletes the part when `acceptedFrameCount == 0` (`ScreencastBroadcastWriter.swift:141`). Audio `finish` does not delete. Loss if that part existed, before the delete. Present but not existed: diagnostic, then delete. Absent: no event. A loss throw does not delete. These writes use `JournalEvents` in the extension process.
16. `preserveAndCancel` (`PhoneAudioFragmentWriter.swift:428`) and the `.retained` move onto `audio.m4a` (`deriveAudioArtifact`, `:994`). No event.
17. A directory whose only entry is a stale `screen.live.json` (`:2119`), and the lease sweep (`:2079`). No event.
18. `quarantineObserverResidue` (`Sources/MobileSegment/MobileSegmentTransferSpoolMigrator.swift:177`), the zero-byte legacy `m4a` delete (`:210`), `deleteBackgroundBodies` (`:160`), and the cache-root remove (`:59`). No event. Not a notice and not a diagnostic.
19. Location removals (`MobileSegmentUploader.swift:1487`, `:1492`, `:1622`, `:1655`) and every watch delete, including `WatchTransferSpoolMigrator`. No event. Do not change `WatchCaptureTerminalReason.audioInterrupted` or watch copy.

`finalizePart`'s `replaceItemAt` of an existing final (`Sources/MobileSegment/MobileSegmentScreencastShared.swift:178`) is no event. The part becomes the final of the same segment. `moveOrReplaceItem` and `copyOrReplaceItem` (`MobileSegmentStore.swift:396`, `:404`) are no event when they are that kind of replace. The empty-directory `store.remove` after a media event (`MobileSegmentUploader.swift:773`, `:1284`) is no extra event.

## Observer faults

Keep every existing `os.Logger` line. Add a line only where the event has none today: interruption began, interruption ended with its duration, and a configuration-change restart that succeeded. Also append a `DiagnosticLog` line, category `.diagnostics`, for each reason below. The store row is the same write.

| Reason | Where | Detail |
| --- | --- | --- |
| `observer_interruption_began` | `handleInterruption` `.began` (`ObserverManager.swift:393`) | None. New log line. |
| `observer_interruption_ended` | `handleInterruption` `.ended` (`:399`) | The duration. Collapse sums it. New log line. Today the duration is computed (`:404`) and not logged. |
| `observer_interruption_end_never_delivered` | `armInterruptionDeadline` (`:439`) | Existing log line. |
| `observer_tap_write_stall` | `watchdogTick` (`:476`) | Existing log line. |
| `observer_media_services_reset` | `handleEngineFault` (`.mediaServicesReset`, `:384`) | Existing log line. |
| `observer_configuration_change` | `handleEngineFault` (`.configurationChange`, `:370`) | One row. Detail counts restart success and failure. Success is a new log line. Failure keeps `observer: engine restart failed` (`:379`). |
| Writer fault reason | `latchFault` only | The existing writer reason. Segment set. Source `audio`. |

No segment on the session-level rows. Source `audio` for all of them. A configuration change that only sets `configChangedDuringPause` does not increment the restart counts until `restart()` returns or throws.

## Diagnostics text

`DiagnosticLog.snapshot(tunnel:syncState:)` (`Sources/Diagnostics/DiagnosticLog.swift:101`) gains a section. `DiagnosticsView.copySnapshot` (`:209`), `StatusPane.copySnapshot` (`Sources/Home/StatusPane.swift:842`), and `exportFileURL` (`DiagnosticLog.swift:190`) already share `snapshot`, so all three get the section.

Last 30 days, newest first. Each line: local `yyyy-MM-dd HH:mm:ss`, kind, source, reason, the first 8 characters of the segment id when there is one, capture time when known, `seen` or `unseen`. Then one import line: `Import: not run`, `Import: complete, N imported, M skipped`, or `Import: failed, <reason>`. A fault-then-loss segment prints both rows. An unreadable store prints one line that the journal events could not be read, and does not invent an import status.

## Roots

Remove the nil defaults that select Caches:

- `MobileSegmentStore.init` (`Sources/MobileSegment/MobileSegmentStore.swift:23`)
- `MobileSegmentUploader.init` (`Sources/MobileSegment/MobileSegmentUploader.swift:131`)
- `LiveObserverRecorder.init` (`Sources/Observer/ObserverRecorder.swift:115`)
- `ObserverManager.init` (`Sources/Observer/ObserverManager.swift:88`)
- `LocationManager.init` (`Sources/Location/LocationManager.swift:71`)
- `ScreencastManager` convenience init (`Sources/Screencast/ScreencastManager.swift:519`)

Every call site, including tests, passes a root. `makeObserverRecorder()` (`SolstoneSwiftApp.swift:1219`) passes the App Group `JournalEvents` directory. No fallback remains. Constructing the store or the recorder with no root does not compile.

Call sites that omit a root today: `Tests/ObserverRecorderTests.swift:304`, `:315`, `:340`; `Tests/DynamicTypeSmokeTests.swift:181`, `:204`; `Tests/ScreencastManagerTests.swift:402`; `Tests/ScreencastManagerLifecycleTests.swift:68`.

## Seed and shots

Keep the flag `--ui-test-seed-audio-interruption` (`Sources/UITestSupport/OnThisPhoneUITestSeeder.swift:25`). It no longer writes an interruption json. The seeder's reset (`:163`) also removes `JournalEvents`. After the gate opens the first time on that launch, the flag writes one unseen audio loss with `foundAt` and `captureAt` of now, so the line is `some of what you shared today didn't reach it.`

`dayHome.surface` (`Sources/Home/DayHomeView.swift:222`) can appear before bootstrap's reconcile returns. The shot waits for the surface and for the gap headline.

Makefile target `gap-shots`, copied from `primer-shots` (`Makefile:292`): one UI test class, `-resultBundlePath build/gap-shots.xcresult`, `-destination '$(SIM_DESTINATION)'`. Class `JournalGapShotTests`. Four attachments, each after the surface wait, `lifetime = .keepAlways`:

1. Home with the gap pill.
2. Status showing the notice.
3. That status dismissed and opened again, showing caught up.
4. A second launch without the flag, home, caught-up pill. The second launch does not reset `JournalEvents`, so the seen file from the visit remains.

iPad: a test in `UITests/PadSplitShellUITests.swift` beside the existing class, skipped unless the window is pad-shaped (`isPadShapedWindow`), so the phone lane skips it and `make ci-ipad` runs it. Launch with `--ui-test` and `--ui-test-seed-audio-interruption`. That launch seeds a pairing (`ContentView.swift:242`) and the paired default detail is status. The detail shows the notice, then leaving that detail and returning shows caught up.

## Tests to add or rewrite

Do not write them yet.

- One test per path-table row. Include the `.writing` zero-frame file with payload past the header (loss; the 48-byte shape, payload 4), faulted zero-frame ftyp-only (diagnostic), absent-receipt ftyp-only (diagnostic), completed zero-frame header-only (no loss, file remains, `.retryableUnresolved`), the same reason as a loss when deleted and a diagnostic when published, missing audio with and without accepted frames, each screen and screen-audio deletion and its empty twin, and the no-event rows (owner removal, owner screen removal, delivered residue, migration).
- Fault then unreadable delete keeps both rows (diagnostic and loss) and the pill shows the gap. Fault then publish with the same reason keeps two diagnostic rows: the latch-fault file and the publish file. Repeated faults collapse on the fault file. Repeated publishes collapse on the publish file. A different publish reason keeps its own publish file.
- The recorder's fault file is under the App Group directory the app passes. Constructing the store or the recorder with no root does not compile.
- A loss-write failure leaves the file or the segment. A second pass after a recorded loss and a surviving file does not add a second loss. A diagnostic-write failure still publishes and still deletes on a delete path.
- Pill, day line (today, yesterday, weekday, since, undated), a found-today capture from 9 days ago, an unseen loss outside the window, a DST boundary via `date(byAdding: .day)`, no pulse, accessibility label equal to the visible text, and a foreground clock change with no store write.
- Seen: the exact ids, a mid-visit loss stays unseen, a visit before the gate marks nothing, a visit before any loss does not freeze an empty set, relaunch, a failed seen write, a loss from another writer during the mark, foreground, and the pill selected again.
- Upgrade: both `MobileSegment` directories plus the old backfill evidence, a second run adds nothing, one malformed file increments M and stays, a failed import does not hold the gate, Caches files remain, a loss written while `gate.json` is absent is seen, a cancel then a later completion opens once, the `catch` at `:836` opens, and a loss after open shows.
- Pairing: the same journal marks nothing, a different known journal marks every event seen, and a first launch seeded `unknown` then the same journal again marks nothing.
- Retention and collapse, including the in-window unseen loss the cap cannot drop, and a day of interruption began/ended collapsing to two rows.
- Widget: `journalGap` present, field absent decodes false, the old key alone is ignored, precedence matches each presentation, and `observer-status.json` is rewritten after seen.
- A corrupt file is set aside and a new loss still shows. A read error sets nothing aside, writes no seen mark, and a later read returns the same rows.
- Snapshot text contains both rows of a fault-then-loss segment, the import line, and the collapsed fault.

Rewrite these. They assert `.audioInterrupted`, `audioInterruptionCount`, an interruption file after a publish, or the old headline. None of them require the old headline when rewritten.

`Tests/AudioInterruptionStatusTests.swift`: `testUnreadableAudioRetirementIsAnInterruptionThatSurvivesRestart`, `testUnreadableAudioBesideLocationStaysAnInterruptionAfterTheQueueDrains`, `testEmptyRetirementsWithNoRecordedAudioAreNotInterruptions`, `testRecordingStaysWhenItsInterruptionCannotBeRecorded`, `testEarlierUnreadableAudioRecordsAreCarriedForwardOnce`, `testPillShowsTheInterruptionOnlyWhereItWouldOtherwiseClaimCaughtUp`, `testPaneKeepsTheNoticeBesideOtherFacts`, `testOnThisDeviceDoesNotSayEverythingArrived`, `testWidgetsShowTheInterruptionInPlaceOfCaughtUp`, `testWidgetSnapshotCarriesTheInterruptionAcrossWriters`.

`Tests/MobileSegmentReconcileTests.swift`: `testResumeReconcileTransientUnreadableAudioRetainsFile`, `testActiveAgedSegmentWithMalformedReceiptParksToFailedAndRecoversCleanly`.

`Tests/MobileSegmentFinalizeResolverTests.swift`: `testRecoveredPrefixKeepsInterruptionAndCorrectTransferDuration`, `testInjectedInspectDurationsBehavior`, `testReceiptParsingAndValidationScenarios`, `testEvidenceWriteFailureRecoversCleanly`, `testMismatchWrittenBeforePublicationThrowsAndRecovers`, `testGenerated60sControlPublishesWithoutInterruption`, `testTransientInspectIsNotMismatchAndDefers`, `testFaultedReceiptWithReasonAudioWriterFailed`, `testCompletedReceiptPermanentInspectDefersWithoutInterruption`.

`Tests/PhoneAudioWriterCompositionTests.swift`: `testOwnershipAcquiredDuringInspectionDefersOnlyTheOwnedSegment`, `testRecoveryRestoresPrefixRetainedAcrossCancellationExit`.

`Tests/AppGroupMirrorTests.swift` and `Tests/ObserverCaptureControlMirrorWriterTests.swift` pass `audioInterrupted: false`. Update them to `journalGap`.

Watch `.audioInterrupted` tests stay: `Tests/WatchStatusContextTests.swift`, `Tests/WatchPipelineReducerTests.swift`, `Tests/WatchCaptureTests.swift`, `Tests/WatchNoticePolicyTests.swift`, `Tests/PhoneWatchSourceStateMappingTests.swift`.

## Changelog

Under `## [Unreleased]` `### Fixed`, the bullet is exactly:

`- after a problem with audio, the status said "audio was interrupted" and kept saying it. now, when something you shared won't reach your journal, the status says there's a gap and which day, and it clears once you've looked at it.`

## Out of scope

Watch losses, share and photo failures, location, the owner's deletion of a segment or of screen content, the failed-segment list, tombstones under `tombstones/uploaded` and `tombstones/empty` except the legacy copy of `audio_undecodable_container`, any other pill state, the waiting count, the confirm-the-mark flow, new settings, telemetry.

## Order

1. Box walker and `JournalEvents` store, including seen, gate, import marker, identity file, aside, and prune.
2. Gate and import inside `resumeFromDisk`. Cancelled breaks return like `:811`. Delete the backfill.
3. Path table, including the extension target membership and the engine `catch`.
4. Observer diagnostic rows and the three new log lines.
5. Required roots. No Caches fallback.
6. Reader, copy, pill, status, on-this-device, visit model.
7. Widget field and the snapshot task.
8. Pairing identity, startup seed, and the two pairing updates.
9. Seed flag, `gap-shots`, the iPad test, and the changelog bullet.

## Current lines the decisions override

- `MobileSegmentUploader.swift:830` and `:832` break and then return at `:841`. A cancel there must return like `:811` and must not open the gate.
- `MobileSegmentUploader.swift:737` deletes the promoted file when the size cannot be read. A nil size leaves the file and writes no event.
- `MobileSegmentEngine.swift:954` removes the candidate with no proof. The `catch` uses the proof in path 13.
- `MobileSegmentScreencastShared.swift:178` replaces an existing final. That replace is no event.
