# Finalize-Failure Resolver Design

Current source anchors are against HEAD `9618d6da89a2e69e1e18c2dbce615ec27007e59f`.

## Decisions

### 1. Tombstone taxonomy

Use the existing tombstone kind `empty`.

- `MobileSegmentStore.ensureRoot()` already creates `tombstones/empty/` at `Sources/MobileSegment/MobileSegmentStore.swift:42`.
- Existing `empty` reasons are `no_artifacts` at `Sources/MobileSegment/MobileSegmentUploader.swift:490` and `screencast_removed` at `Sources/MobileSegment/MobileSegmentUploader.swift:626`.
- Existing `uploaded` reason is `delivered` at `Sources/MobileSegment/MobileSegmentUploader.swift:1199` and `Tests/MobileSegmentMigrationTests.swift:129`.
- New reason: `unrecoverable_lost_data`.

AC2 should assert the distinction by reading the JSON tombstone file at:

- `store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(segmentID.uuidString).json")`

Decode it as `MobileSegmentTombstone` and assert:

- `reason == "unrecoverable_lost_data"`
- `reason != "no_artifacts"`

Rejected alternative: a distinct tombstone kind, such as `unrecoverable`, would make directory counts trivial but would require new `ensureRoot` subdirectory wiring and new migration awareness. KISS wins here: `kind: "empty"` plus a non-colliding reason is enough to distinguish "no artifacts ever" from "had data but could not recover it".

### 2. Directory-aware location recovery

Extract a directory-parameterized core from `recordLocationFinalized(:262-300)`.

Current lifecycle coupling:

- `Sources/MobileSegment/MobileSegmentUploader.swift:268`: `let directory = self.activeDirectory(segmentID: segmentID)`

Confirmed: no other active-only call is in the location recovery helpers the resolver will touch. `writeLocationArtifactOutcome(:776-796)`, `recoverLocationLive(:820-849)`, and `writeLocationRemoved(:759-774)` are already directory-aware. The current problem is `recoverLocationLive(:846)` calls the active-only `recordLocationFinalized`.

Add this exact core signature near the existing method:

- `func recordLocationFinalized(segmentID: UUID, directory: URL, batch: LocationSegmentBatch, endedAt: Date) throws`

Keep the existing active-path API as a wrapper:

- `func recordLocationFinalized(segmentID: UUID, batch: LocationSegmentBatch, endedAt: Date) throws`

The wrapper computes `self.activeDirectory(segmentID:)` and calls the directory-aware core. Update `recoverLocationLive(:846)` to call the new core with its `directory` parameter. That makes `recoverLocationLive` reusable by both active reconcile and failed-pile resolution without duplicate recovery code.

### 3. Transient-vs-corrupt classification

Location resolution order is recover-before-discard:

1. If canonical `location.jsonl` exists, call `writeLocationArtifactOutcome(:776-796)` and resolve to `.finalizedArtifact`.
2. Else if `location.part.jsonl` exists, call `recoverLocationLive(:820-849)`.
3. Else write `.removed` with reason `location_no_local_data`.

Throw classification:

| Site | Current line | Classification | Action |
| --- | --- | --- | --- |
| `store.readData(at: partURL)` | `MobileSegmentUploader.swift:827` | transient I/O | Propagate. Leave in `failed/`; retry next pass. |
| `recoverLiveLocation` enum errors | `MobileSegmentLocationWriter.swift:327-375`, `440-445` | unrecoverable corrupt live data | Current helper catch at `MobileSegmentUploader.swift:831-840` writes `.removed` reason `location_live_corrupt`. |
| `recoverLiveLocation` raw `DecodingError` from known-record decodes | `MobileSegmentLocationWriter.swift:339`, `350`, `354` | unrecoverable corrupt live data | Same helper catch writes `.removed`. |
| `writeLocationRemoved` after corrupt recovery | `MobileSegmentUploader.swift:833-839`, `759-774` | transient persistence if it throws | Propagate. Do not tombstone until outcome persistence succeeds. |
| `recordLocationFinalized` storage guard | `MobileSegmentUploader.swift:267` | transient/environmental | Propagate. |
| `recordLocationFinalized` manifest read | `MobileSegmentUploader.swift:269` | transient I/O/decode | Eliminated from failed core if the core takes `directory`; otherwise propagate. |
| `MobileSegmentLocationWriter.freeze(batch)` | `MobileSegmentUploader.swift:286` | post-recovery serialization, not data corruption | Propagate. Do not redact. |
| `store.writeData(frozen.data, to:)` | `MobileSegmentUploader.swift:288` | transient I/O | Propagate. |
| `store.writeOutcome` finalized artifact | `MobileSegmentUploader.swift:298` | transient persistence | Propagate. |
| trailing `store.readManifest(in: directory)` | `MobileSegmentUploader.swift:847` | transient I/O/decode | Propagate. |

Critical rule: only parser failure inside `recoverLiveLocation` is irreversible. Any throw after recovery succeeded is deferred/transient and must not cause redaction.

For other sources:

- Screencast dead: no recovery. Resolve inline by removing `screen.mp4` and `screen.part.mp4`, then writing `.removed` with reason `screencast_removed`. Do not call `redactScreencastFacet(:604-635)` because it moves, schedules, and tombstones.
- Audio dead: no recovery. Resolve inline by removing `audio.m4a`, then writing `.removed` with reason `audio_no_local_data`.

### 4. Resolver API and wiring

Add this enum near the uploader-only support types:

- `nonisolated enum FinalizeFailureResolution: Equatable, Sendable { case repend, retired, deferred }`

Add this per-segment resolver:

- `func resolveFinalizeFailure(segmentID: UUID, directory: URL, lifecycle: MobileSegmentLifecycle) throws -> FinalizeFailureResolution`

Behavior:

- Read manifest. Any throw propagates to the caller as deferred/transient.
- If `manifest.hasFinalizeFailure == false`, return `.deferred` as a benign no-op race result.
- Resolve each declared `.failedToFinalize` source in order: location, screencast, audio.
- Any transient throw from location recovery or outcome persistence propagates.
- Re-read manifest.
- If any declared source is `.finalizedArtifact`, set `manifest.upload = .pending`, update `updatedAt`, write manifest, move `failed -> pending` only when `lifecycle == .failed`, and return `.repend`.
- Otherwise write `writeTombstone(kind: "empty", reason: "unrecoverable_lost_data")`, remove the segment directory, and return `.retired`.
- Do not call `scheduleUpload` from this method.

Add this batch scanner:

- `func resolveFinalizeFailurePile() async`

Behavior:

- List `store.list(.failed)`.
- Loop per segment with its own `do/catch`.
- Only act on manifests where `manifest.hasFinalizeFailure` is true.
- On `.repend`, call `await scheduleUpload(segmentID: segmentID)`.
- On `.retired` or `.deferred`, do not schedule.
- On any throw, log a concise diagnostic, set `lastError`, and continue. This per-segment isolation deliberately rejects the single-outer-`do/catch` shape in current `retryFailed(:539-559)`.

Wiring:

- `resumeFromDisk(:521-537)`: insert `await resolveFinalizeFailurePile()` immediately after `try await self.reconcileActiveSegments()` at `:525` and before `let pending = try self.store.list(.pending)` at `:526`. The later pending-list scheduling remains idempotent with scanner scheduling because `scheduleUpload` already guards `schedulingSegmentIDs` at `:1100` and transport in-flight state at `:1101`.
- `retryFailed(:539-559)`: call `await resolveFinalizeFailurePile()` at the top, then run the residual failed retry loop. Restructure the residual loop to per-segment `do/catch`. Keep the guard at current `:546`: `guard !manifest.hasFinalizeFailure, manifest.hasArtifact else { continue }`. Rationale: finalize failures were already processed by the scanner; any remaining finalize-failure segment is deferred/transient and should stay in `failed/`.
- `scheduleUpload(:1098-1162)`: do not touch the `isFullyResolved` gate at `:1110-1134`. Replace the silent `return` behavior at `:1136` for `hasFinalizeFailure`. If `manifest.hasFinalizeFailure` is true, call `resolveFinalizeFailure(segmentID:directory:lifecycle:.pending)` in place. If it throws, treat that local branch result as `.deferred` and return, rather than falling into the outer schedule catch that moves to `failed/` as `schedule_failed`. On `.repend`, re-read manifest and fall through to the existing upload-build path. On `.retired` or `.deferred`, return. Preserve the existing `hasArtifact` guard for the non-finalize-failure case.

### 5. Re-entrancy and idempotence

The resolver never calls `scheduleUpload`. Only `resolveFinalizeFailurePile()` schedules after it is outside the `schedulingSegmentIDs` guard. The `scheduleUpload(:1136)` site resolves in place and falls through; it does not recursively call `scheduleUpload`, so the `:1100` guard is not used as a recursion escape hatch.

Idempotence:

- The scanner only acts on `manifest.hasFinalizeFailure` (`MobileSegmentManifest.hasFinalizeFailure` at `Sources/MobileSegment/MobileSegmentModels.swift:218-220`).
- Resolved facets become terminal `.removed` or `.finalizedArtifact`.
- Re-pended survivors no longer have finalize failures, so the scanner will skip them on later passes.
- Retired no-survivor bundles are removed after writing a tombstone, so later scans cannot reprocess them.

## Files and methods to add or modify

### Product source

`Sources/MobileSegment/MobileSegmentUploader.swift`

- Modify `recordLocationFinalized(segmentID:batch:endedAt:)` at `:262-300` into an active wrapper.
- Add `recordLocationFinalized(segmentID:directory:batch:endedAt:) throws` near `:262`.
- Modify `recoverLocationLive(:820-849)` at `:846` to pass its `directory`.
- Add `FinalizeFailureResolution` near `MobileSegmentUploaderError` at `:11-20`.
- Add `resolveFinalizeFailure(segmentID:directory:lifecycle:) throws -> FinalizeFailureResolution` near the location helper cluster after `recoverLocationLive(:820-849)`.
- Add `resolveFinalizeFailurePile() async` near `retryFailed(:539-559)` or near the resolver helper. Prefer near `retryFailed` because it is an entry-point scanner.
- Modify `resumeFromDisk(:521-537)` to call the scanner before listing pending.
- Modify `retryFailed(:539-559)` to call the scanner first and use per-segment catches in the residual loop.
- Modify `scheduleUpload(:1098-1162)`, specifically the guard at `:1136`, to resolve pending finalize failures in place.

No changes expected in `MobileSegmentStore.swift`; existing APIs cover tombstones, list, move, read/write manifest, read/write data, and artifact URLs at `:60-80`, `:136-165`, `:178-187`, `:195-229`, and `:258-265`.

### Tests

Create `Tests/MobileSegmentLiveLocationTestSupport.swift`.

- Extract the live-location fixture helpers currently private in `Tests/MobileSegmentReconcileTests.swift:572-684`: `writeActiveLocation`, `writeActiveLocationPart`, `writeLocationPart`, `writeLocationLiveness`, `locationFix`, and any needed `liveStateLine` composition.
- Make the liveness helper directory-parameterized instead of hardcoding active at `Tests/MobileSegmentReconcileTests.swift:659`, so failed-directory tests can use it.
- Update `MobileSegmentReconcileTests` to use the shared helper, preserving existing active-reconcile coverage.

Create `Tests/MobileSegmentFinalizeResolverTests.swift`.

- Use a focused harness equivalent to `MobileSegmentUploaderTests.makeHarness(:466-487)`.
- Use the transfer cutover harness for enqueue-facing cases, and keep resolver storage fixtures local to the test file unless duplication becomes material.

Update `Tests/MobileSegmentUploaderTests.swift:416-456` string/status grep coverage to include new status reasons `unrecoverable_lost_data`, `location_no_local_data`, and `audio_no_local_data` if they are surfaced through owner-visible failure reason paths.

## Test plan

1. AC1: `testFailedAudioSurvivorDeadLocationRequeuesAudioOnly`
   - Fixture: `failed/` bundle with audio `.finalizedArtifact`, location `.failedToFinalize`, no `location.jsonl`, no `location.part.jsonl`.
   - Assert: location becomes `.removed` reason `location_no_local_data`, segment moves to pending, upload body includes `audio.m4a` only.

2. AC2: `testUnrecoverableLocationOnlyWritesLostDataEmptyTombstone`
   - Fixture: `failed/` location-only bundle with `.failedToFinalize` and corrupt or absent local data.
   - Assert: `tombstones/empty/<segmentID>.json` decodes to `MobileSegmentTombstone.reason == "unrecoverable_lost_data"` and not `no_artifacts`.

3. AC3: `testFailedLiveLocationPartRecoversBeforeDiscarding`
   - Fixture: `failed/` bundle with `location.part.jsonl` seeded through shared live-location helpers and location `.failedToFinalize`.
   - Assert: resolver creates canonical `location.jsonl`, writes `.finalizedArtifact`, clears live files, and uploads recovered location or surviving mixed bundle.

4. AC4: `testScheduleUploadResolvesPendingFinalizeFailureInPlaceWithoutRecursing`
   - Fixture: `pending/` bundle with a survivor artifact plus a finalize-failed source.
   - Assert: the pending scheduling path enters `scheduleUpload(segmentID:)`, resolves in place, sends exactly one request, and does not rely on recursive scheduling.

5. AC5: `testFinalizeFailureResolverIsIdempotentAcrossRepeatedPilePasses`
   - Fixture: one re-pendable failed finalize-failure and one retire-only failed finalize-failure.
   - Assert: repeated resolver passes do not duplicate tombstones, do not resurrect removed dirs, and do not duplicate uploads.

6. AC6: `testFinalizeFailurePileKeepsPoisonFailedAndStillDrainsRecoverableSegment`
   - Fixture: at least two failed finalize-failure segments, one poison segment with unreadable live-location data and one recoverable survivor bundle.
   - Assert: the poison segment stays in `failed/` while the recoverable segment drains in the same pass.

7. AC7: `testRetryFailedStrictlyDecreasesRecoverableFinalizeFailurePile`
   - Fixture: mixed recoverable failed finalize-failure pile with audio-survivor, recovered-location, and location-survivor shapes.
   - Assert: `retryFailed()` strictly decreases `failed/` count and the uploaded multipart sources prove survivors were delivered rather than dropped.

8. AC8: `testFailedLocationSurvivorDeadAudioRequeuesLocationOnly`
   - Fixture: `failed/` bundle with location `.finalizedArtifact`, audio `.failedToFinalize`, no viable audio file.
   - Assert: audio becomes `.removed` reason `audio_no_local_data`, segment moves pending, upload body includes `location.jsonl` only.

Supplemental completeness regression: `testDeadScreencastFacetIsRemovedWithoutTombstoneWhileSurvivorRemains`

- Fixture: failed bundle with audio or location survivor and screencast `.failedToFinalize`.
- Assert: screencast becomes `.removed` reason `screencast_removed`, no empty tombstone is written while a survivor remains, and survivors re-pend.

## Execution sequence

1. Extract the directory-aware `recordLocationFinalized` core and update `recoverLocationLive(:846)`.
2. Add resolver enum and per-segment resolver, using existing directory-aware helpers and inline audio/screencast removal.
3. Add batch scanner and wire `resumeFromDisk`, `retryFailed`, and `scheduleUpload`.
4. Extract live-location test support and add focused resolver tests.
5. Run Makefile validation only: targeted test pass if available through existing targets, otherwise `make test`; run `make ci` before merge.

## Risks and open questions

- The pending `scheduleUpload(:1136)` branch must catch resolver transient throws locally. Letting them fall to the existing outer catch would incorrectly call `movePendingToFailed(..., reason: "schedule_failed")`.
- The unreadable-part transient test needs a reliable fixture on the XCTest platform. A directory at `location.part.jsonl` should make `Data(contentsOf:)` throw while `fileExists` is true, but this should be verified during implementation.
- If test harness duplication becomes noisy in the new resolver test file, extract a small uploader harness support file. Default plan keeps URLProtocol local because current tests already use per-file protocol stubs.
