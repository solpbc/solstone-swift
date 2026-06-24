# Lode L3 Watch Relay Design

## Scope

L3 adds a durable watchOS-to-iOS relay for finalized watch capture segments over
WatchConnectivity. The guarantee is app-level, not WCSession-completion-level:
the watch keeps each segment until the iPhone has durably staged it and sends an
ACK back with `transferUserInfo`.

This is a design-only document. It is based on the current source topology:

- `solstone-swift` includes `Sources` except `Sources/SPLTunnel`, so iOS tests can
  reach `Sources/WatchCapture` and `Sources/WatchConnectivity`.
- `SolstoneWatch` currently includes `Watch/Sources`, `Sources/WatchCapture`,
  selected observer/service/source files, but not `Sources/WatchConnectivity`.
- `WatchCaptureEngine` writes finalized segments to `.queued` in
  `finalize(segment:audioDuration:end:)` and `recoverUnclean(_:)`; no relay
  exists today.

## Settled Decisions Checked Against Source

### Source Placement

Add shared relay implementation under `Sources/WatchCapture/`:

- `WatchSegmentBundleCodec.swift`
- `WatchRelaySender.swift`
- `WatchRelayReceiver.swift`

Keep the injectable WC protocol and live wrapper in
`Sources/WatchConnectivity/WatchConnectivitySession.swift`. Add that directory
to the watch target source list.

No existing files need to move. `Watch/Sources/WatchSessionDelegate.swift` should
be deleted when the watch side is refactored onto the shared wrapper, because
`Watch/Sources` is a broad source entry and an unused raw-WC delegate would still
compile.

Exact `project.yml` change:

- Under `targets.SolstoneWatch.sources`, add `Sources/WatchConnectivity` after
  `Sources/WatchCapture`.

The current `LiveWatchConnectivitySession` has iOS-only delegate methods:

- `sessionDidBecomeInactive(_:)`
- `sessionDidDeactivate(_:)`

These must be wrapped in `#if os(iOS)` before the watch target compiles
`Sources/WatchConnectivity`. If `sessionWatchStateDidChange(_:)` is ever added,
it also needs `#if os(iOS)`. The local Xcode 26.5 SDK headers mark those methods
`__WATCHOS_UNAVAILABLE`. The same headers expose `transferFile`, `transferUserInfo`,
`session(_:didReceive file:)`, and `session(_:didReceiveUserInfo:)` on both iOS
and watchOS, so the core relay API survives the shared target change.

### Important Correction

The settled direction says the sender should pick segments whose state is not
`.acked` or `.safeToDelete`. That does not survive contact with the current
capture lifecycle: `.captured` and `.persisted` are active or pre-final segment
states, and `scanManifests()` can see them while a session is running. The sender
must not bundle or transfer those states.

The safe L3 eligibility rule is:

- Transfer eligible: `.queued` and `.transferring`.
- Cleanup eligible: `.acked` and `.safeToDelete`.
- Not relay eligible: `.captured`, `.persisted`, `.finalized`.

`reconcileOnLaunch()` already converts `.captured`/`.persisted` through recovery
and `.finalized` to `.queued`; the sender should rely on that path rather than
transferring pre-final data.

## WatchConnectivity Protocol

Extend `WatchConnectivitySession` with only the durable primitives L3 needs:

- `func transferFile(_ url: URL, metadata: [String: Any])`
- `func transferUserInfo(_ userInfo: [String: Any])`
- `var onReceiveFile: ((URL, [String: Any]) -> Void)? { get set }`
- `var onReceiveUserInfo: (([String: Any]) -> Void)? { get set }`

The protocol remains `@MainActor`. These methods are fire-and-forget. Sender
logic never deletes local source data because a WC transfer completion callback
fires.

`LiveWatchConnectivitySession` implements the WC delegate callbacks using the
existing nonisolated-to-main-actor pattern. The file receive path has one critical
extra rule: `WCSessionFile.fileURL` is owned by the system only during the delegate
callback. The nonisolated `session(_:didReceive file:)` must synchronously take
ownership before it hops actors:

1. Create a scratch directory under `NSTemporaryDirectory()/WatchConnectivityInbox/`.
2. Move the incoming `file.fileURL` to a unique scratch file in that directory.
3. Copy the metadata dictionary into a stable local value.
4. Hop to `Task { @MainActor ... }` and call `onReceiveFile(stableURL, metadata)`.

If the move fails, log and do not call `onReceiveFile`; no ACK can be sent because
the receiver never had a durable payload. The `WatchRelayReceiver` owns deletion
of the scratch file after it stages, rejects, or fails the payload.

`session(_:didReceiveUserInfo:)` similarly hops to `@MainActor` and calls
`onReceiveUserInfo`.

ACK payload shape is:

- `type`: `"watch_segment_ack"`
- `id`: segment UUID string

ACK transport is `transferUserInfo`, because it is durable, FIFO, and delivered
opportunistically after either app exits.

## Bundle Codec

`WatchSegmentBundleCodec` is a small binary property-list codec in
`Sources/WatchCapture/`.

Encode input is a segment directory plus `WatchCaptureStorage`. It reads existing
files through `WatchFileWriting` and builds a `[String: Data]` dictionary keyed
by on-disk filename:

- `manifest.json` always required
- `audio.m4a` if present
- `location.jsonl` if present

It serializes the dictionary with `PropertyListSerialization` using binary plist
format. The sender writes bundle files under:

- `WatchCapture/.relay-bundles/<uuid>.watchrelay`

The `.relay-bundles` directory is hidden so current `scanManifests()` does not
see it. The sender removes any stale bundle for the same UUID before writing a
fresh one. The sender keeps the bundle until ACK cleanup, because WCSession owns
the transfer schedule and L3 must not depend on transfer-completion timing.

Decode input is a bundle file and destination directory. It reads the plist,
requires `manifest.json`, and writes each Data value back to the reconstructed
segment directory via `WatchFileWriting`. If the metadata UUID and manifest UUID
do not match, decoding fails and the receiver does not ACK.

Transfer metadata is property-list-serializable and used only for fast dedupe and
logging before unpacking:

- `id`: UUID string
- `day`: manifest day
- `segment`: manifest segment
- `duration`: Double
- `started_at`: ISO-8601 string
- `sensors`: `[String]` of `WatchSensor.rawValue`
- `partial`: Bool
- `lost`: Bool
- `gap`: Bool
- `fix_count`: Int

## Watch Relay Sender

`WatchRelaySender` is `@MainActor` and lives in `Sources/WatchCapture/`.

It owns:

- `WatchCaptureStorage`
- `any WatchConnectivitySession`
- `maxInFlight = 1`
- optional `onStateChanged` callback for watch presentation refresh

Cap rationale: watch segments are low-frequency five-minute chunks, FIFO order is
easy to reason about, and one distinct in-flight segment makes the exactly-once
logic obvious. The cap can be raised later by changing the named constant and the
drain loop.

Drain algorithm:

1. `scanManifests()` for FIFO day/segment order.
2. First advance cleanup states:
   - `.acked` -> write `.safeToDelete` -> delete segment directory.
   - `.safeToDelete` -> delete segment directory.
3. Count distinct `.transferring` segment IDs as in flight.
4. If a `.transferring` segment exists, re-bundle and call `transferFile` for the
   earliest one, then return. This is the idempotent resend path for lost ACKs or
   app relaunch.
5. If no `.transferring` exists, take the earliest `.queued` segment if below
   `maxInFlight`.
6. Persist `.transferring` before calling `transferFile`.
7. Build or refresh the transfer bundle.
8. Call `transferFile(bundleURL, metadata:)`.

The sender deliberately does not use `.delivered`. WC `didFinishFileTransfer` is
not the receiver's durable commit signal, and L3 never gates deletion on it. The
honest chain is:

`.queued` -> `.transferring` -> `.acked` -> `.safeToDelete` -> directory deleted

This deviates from the original scope's enumerated `delivered -> acked` path and
needs explicit Jer ratification.

ACK handling:

1. `onReceiveUserInfo` filters for `type == "watch_segment_ack"`.
2. Find the manifest by UUID through `scanManifests()`.
3. If found and not already `.safeToDelete`, write `.acked`.
4. Write `.safeToDelete`.
5. Delete the segment directory with `WatchFileWriting.removeItem(at:)`.
6. Delete the matching `.relay-bundles/<uuid>.watchrelay`.
7. Notify presentation and drain the next queued segment.

Crash handling:

- Crash after `.transferring` write but before transfer: relaunch drain re-bundles
  and sends the same UUID.
- Crash after transfer but before ACK: relaunch drain re-sends the same UUID.
- Crash after `.acked` but before delete: cleanup pass advances to
  `.safeToDelete` and deletes.
- Crash after `.safeToDelete` but before delete: cleanup pass deletes.

Drain triggers:

- `WatchCaptureEngine.finalize(...)`: after the `.queued` manifest write and
  `queuedCount` increment.
- `WatchCaptureEngine.recoverUnclean(_:)`: after the `.queued` manifest write and
  `queuedCount` increment.
- `WatchCaptureEngine.reconcileOnLaunch()`: after the scan/recovery loop and
  before/with the presentation notification.
- `WatchSessionModel`: when reachability changes to true.
- Watch app launch: after activation/reconciliation wiring is installed.

The engine should not import WatchConnectivity directly. Add an injected
`onRelayDrainRequested` main-actor closure or equivalent hook; the watch glue
wires it to `WatchRelaySender.drain()`.

## iPhone Relay Receiver And L4 Contract

`WatchRelayReceiver` is `@MainActor` and lives in `Sources/WatchCapture/`.

Default staging root:

- `AppGroupContainer.rootURL()/WatchRelay/staging/`

Committed entry layout:

- `WatchRelay/staging/<uuid>/manifest.json`
- `WatchRelay/staging/<uuid>/audio.m4a` if present
- `WatchRelay/staging/<uuid>/location.jsonl` if present

Incoming decode layout:

- `WatchRelay/staging/.incoming/<uuid>/...`

Receive flow:

1. Read `id` from metadata. If missing or invalid, delete scratch and do not ACK.
2. If `staging/<uuid>/` already exists, this is a duplicate. Delete scratch,
   send ACK again with `transferUserInfo`, create no second entry, and return.
3. Remove any stale `staging/.incoming/<uuid>/`.
4. Decode the bundle into `staging/.incoming/<uuid>/`.
5. Atomically move `staging/.incoming/<uuid>/` to `staging/<uuid>/`. This move is
   the durable commit point.
6. Only after that move succeeds, send ACK with `transferUserInfo`.
7. Delete the WC scratch bundle file.

Failure handling: if metadata validation, decode, or commit move fails, log via
`os.Logger`, delete scratch, and do not ACK. The watch keeps or resends the
segment.

L4 contract:

`WatchRelay/staging/<uuid>/` presence means the watch segment is durably staged on
the iPhone. The directory contains the reconstructed segment files. L3 never
deletes committed staging entries. L4 consumes this directory as its pending
source.

## Owner Presentation

Extend `WatchCaptureOwnerPresentation` minimally from one count to relay-state
counts:

- `queuedCount`
- `transferringCount`
- `handedOffCount` for `.acked` plus `.safeToDelete`

Keep the existing attention gate: relay status text is nil when
`status.needsAttention` is true.

Priority and copy:

1. If `transferringCount > 0`: `pendingText` is `"sending to your iphone"`.
2. Else if `handedOffCount > 0`: `pendingText` is `"handed to your iphone"`.
3. Else if `queuedCount > 0`: `pendingText` is `"saved on your watch"`.
4. Else nil.

`pendingDetailText` keeps the existing queued detail:

- If not needs-attention and either queued or transferring work exists:
  `"waiting for your iphone"`.
- Otherwise nil.

`WatchCaptureEngine` needs a count refresh path because `WatchRelaySender` mutates
manifests after capture finalization. Use a disk-backed count refresh from
`scanManifests()` after sender transitions so presentation cannot drift.

## Watch App Refactor

Clean break from raw WCSession:

- Replace raw `WCSession?` and `WatchSessionDelegate?` in
  `Watch/Sources/WatchSessionModel.swift` with `any WatchConnectivitySession`.
- Delete `Watch/Sources/WatchSessionDelegate.swift`.
- `WatchSessionModel` owns the shared session and `WatchRelaySender`; it handles
  activation and reachability, and calls sender drain on reachability true.
- `WatchCaptureModel` should be initialized with the same `WatchCaptureStorage`
  and sender hook, rather than constructing isolated storage that the sender
  cannot see.
- `Watch/Sources/SolstoneWatchApp.swift` currently creates independent
  `WatchSessionModel()` and `WatchCaptureModel()` state values. It must become
  the composition point for one shared `WatchCaptureStorage`, one
  `LiveWatchConnectivitySession`, one `WatchRelaySender`, one session model, and
  one capture model.
- `Watch/Sources/WatchHomeView.swift` can keep reading `model.isReachable`; its
  call site changes only if the model initializer changes.

Source tension to account for during implementation: the current storage is
hidden inside `WatchCaptureModel`, so the settled "WatchSessionModel owns sender"
choice requires lifting storage construction to `SolstoneWatchApp` or adding an
explicit composition factory.

## iOS App Wiring

Use one shared live session for `WatchLink` and `WatchRelayReceiver`.

Near `Sources/SolstoneSwiftApp.swift:234`, instantiate:

- `LiveWatchConnectivitySession`
- `WatchRelayReceiver(session: sameSession)`
- `WatchLink(session: sameSession, receiver: receiver)`

`WatchLink` stores the receiver strongly so its callbacks stay installed. The app
continues to call `watchLink.activate()`. `WatchLink` remains responsible for
activation/reachability state; `WatchRelayReceiver` owns file staging and ACKs.

## Mock Extension

Extend `Tests/Mocks/MockWatchConnectivitySession.swift` with:

- `transferredFiles: [(URL, [String: Any])]`
- `transferredUserInfos: [[String: Any]]`
- `onReceiveFile`
- `onReceiveUserInfo`
- `transferFile(_:metadata:)` appends to `transferredFiles`
- `transferUserInfo(_:)` appends to `transferredUserInfos`
- `deliverFile(_:metadata:)` calls `onReceiveFile`
- `deliverUserInfo(_:)` calls `onReceiveUserInfo`

Dropped ACK simulation does not require a special mock flag; the test simply does
not ferry the receiver's `transferredUserInfos` back to the sender.

## Test Plan

All relay tests are iOS unit tests using `@testable import solstone_swift`, temp
directories, the extended mock session, the real bundle codec, and real iPhone
staging. The test ferries the sender's real transferred bundle URL and metadata
into the receiver mock, then optionally ferries ACK userInfo back.

Never lose:

- Create one queued segment in real `WatchCaptureStorage`.
- Sender drains and records one `transferFile`.
- Do not deliver ACK.
- Assert the original segment directory still exists and manifest is not
  `.acked` or `.safeToDelete`.
- Simulate relaunch with a new sender over the same storage.
- Drain again and assert the same UUID transfers again.
- Assert no delete path exists from simulated send/finish alone.

Never duplicate:

- Sender transfers one queued segment.
- Receiver stages it and sends ACK.
- Drop ACK by not delivering userInfo to sender.
- Trigger sender resend of the same UUID.
- Receiver sees existing `staging/<uuid>/`, creates no second entry, and sends ACK
  again.
- Deliver ACK and assert watch deletes source while iPhone has exactly one staged
  UUID directory.

Backlog drain:

- Create N queued segments where N is greater than `maxInFlight`.
- Start with mock unreachable, then emit reachable true and drain.
- Repeatedly ferry one file to receiver and one ACK back to sender.
- Assert all N UUIDs appear under staging, all watch source dirs are deleted, and
  at no point more than one distinct segment manifest is `.transferring`.

Presentation:

- Cover queued, transferring, acked, safeToDelete, and needs-attention gating.
- Assert exact strings:
  - `"saved on your watch"`
  - `"waiting for your iphone"`
  - `"sending to your iphone"`
  - `"handed to your iphone"`

Build validation after implementation:

- `make sim-json`
- `make watch-sim-json`
- focused iOS tests for watch relay/capture/link
- `make ci` before merge

## Risks And Review Gate Items

- Jer must ratify skipping `.delivered`. The design intentionally treats WC
  transfer completion as insufficient for deletion.
- Jer must ratify the corrected sender eligibility rule. Transferring
  `.captured` or `.persisted` would be unsafe with the current engine.
- The watch composition refactor is required because storage currently lives
  inside `WatchCaptureModel`; sender and engine must share the same storage.
- The live wrapper must synchronously move incoming WC files before actor hopping.
  Missing that detail creates a data-loss bug.
- L4 must treat `WatchRelay/staging/<uuid>/` as append-only input owned by L4
  after commit; L3 will not clean those committed staging dirs.
