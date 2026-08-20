# solstone-swift

Native iOS app for solstone — the private, AI-powered journal from sol pbc. Native SwiftUI observer + importer + control center that syncs to the owner's solstone journal over a private loopback tunnel. Universal iPhone + iPad. Bundle ID: `app.solstone.swift`.

## Principles

- **Privacy is an architecture decision.** Observations sync only to the owner's journal server, never to sol pbc. No analytics, no crash reporting, no telemetry. No phone-home.
- **Agent-native.** All builds, tests, deploys, and diagnostics happen through Makefile targets — no freeform `xcodebuild` / `simctl` / `devicectl` composition. `make sim-json` pipes through xcsift for structured JSON errors an agent can parse.
- **Swift 6 language mode, strict (complete) concurrency.** `@MainActor` by default. `nonisolated` where it belongs, including the `WKNavigationDelegate` callbacks in `Sources/Portal/InAppJournalView.swift`. Never `nonisolated(unsafe)` — fix the isolation. `@Observable`, not `ObservableObject`. `NavigationStack`, not `NavigationView`. `async/await`, no completion handlers.
- **`os.Logger` only.** `.info` / `.error` / `.debug` survive from any thread. `print()` and `NSLog()` silently drop from background threads/queues — don't use them. Subsystem: `app.solstone.swift`.
- **Universal always.** Universal iPhone + iPad, size-class-aware SwiftUI. No iPhone-only hardcoding.
- **KISS / YAGNI.** Build for the wave's scope; don't add speculative machinery, options, or fallbacks for cases that don't exist yet. No backwards-compatibility shims — update call sites directly when you rename or move something.
- **Verify before you claim.** Recall is a hypothesis — verify journal/convey API + journal-web contracts and SDK shapes against the live source, and exercise the real serialization boundary in tests rather than mocking both sides.

## Architecture

Native SwiftUI observer + importer + control center. The phone observes mic audio, location, screen via a ReplayKit broadcast extension, an Omi BLE pendant, and a paired Apple Watch, bundles observations into 5-minute segments, and uploads to the owner's journal over the tunnel. Owner-directed imports arrive via the system share-sheet extension.

Local-first observation works unpaired. Captured data is held durably on-phone and drains to the journal once a pairing + tunnel exist. `AppConfig`'s `isPaired` (`Sources/Services/AppConfig.swift`) gates journal features, never observation.

The UI shell has no tab bar. `Sources/ContentView.swift` gates on `onboardingFlow.isCompleted`, then renders `RootShellView` (`Sources/RootShellView.swift`), a `NavigationStack` over `DayHomeView` (`Sources/DayHomeView.swift`). The sources control center (`SourcesView`, `Sources/SourcesView.swift`), the embedded journal web view (`InAppJournalView`, `Sources/Portal/InAppJournalView.swift`), and more (`MoreView`, `Sources/MoreView.swift`) are presented as sheets / navigation destinations, not tabs.

Capture pipelines:
- `Sources/Observer/` — audio recorder/manager.
- `Sources/Transfer/` — durable shared transfer spool, dispatch engine, transport, retry pacing, and per-source status mirror.
- `Sources/MobileSegment/` — `Sources/MobileSegment/MobileSegmentEngine.swift`, `Sources/MobileSegment/MobileSegmentStore.swift`, and `Sources/MobileSegment/MobileSegmentUploader.swift` are the 5-minute segment core.
- `Sources/Location/` — `Sources/Location/LocationManager.swift`.
- `Sources/Screencast/` — `Sources/Screencast/ScreencastManager.swift` is the ReplayKit control side; the broadcast extension writes into the active segment through the app group.
- `Sources/Omi/` — `Sources/Omi/OmiSourceManager.swift` for the BLE pendant.
- `Sources/WatchCapture/` + `Watch/Sources/` — Apple Watch companion, both halves.
- `Sources/ShareImport/` + `SolstoneShareExtension/` (`SolstoneShareExtension/ShareViewController.swift`) — share-sheet staging, app adoption, and transfer handoff.

Embedded journal web: `Sources/Portal/InAppJournalView.swift` is a plain `WKWebView` with `WKNavigationDelegate` callbacks only. There are no script message handlers and no URL-scheme handler. There is no JavaScript bridge; native ↔ journal communication is HTTP over the loopback port.

Transport / tunnel: SPLTunnel is consumed from the `spl-swift` Swift package pinned at `v0.3.2` in `project.yml`, product `SPLTunnel`. It provides pairing crypto, relay dial over WebSocket, inner mTLS TLS 1.3 with a client cert + CA pinning, a framed multiplexer, and a loopback proxy. `TunnelManager` (`Sources/Tunnel/TunnelManager.swift`, `final class TunnelManager`) is the connection state machine over single-shot sessions — connect watchdog, liveness probe, backoff, and `PathMonitor` reactions. The tunnel exposes `http://127.0.0.1:<ephemeral port>`; everything app-side speaks plain HTTP to that loopback port. No SSH — the tunnel is mTLS with a framed multiplexer.

## Build

Uses Makefile targets only. Never invoke `xcodebuild` directly.

```
make install       # xcodegen generate + SPM resolve
make sim           # simulator build
make sim-json      # build with structured xcsift JSON errors (agent-preferred)
make sim-launch    # build + install + launch on simulator
make deploy        # build + install to iPhone
make cycle         # build + deploy + launch with console (blocks)
make test          # all tests
make test-build    # build tests only (produces .xctestrun)
make test-fast     # run tests without rebuilding
make ci            # canonical pre-ship gate: assertions + iOS lane + watchOS lane
make ci-watch      # watchOS test lane on an ephemeral watchOS simulator
make clean         # remove build artifacts
```

`make test-fast` is an inner-loop target. Run `make test-build` immediately before it, or use `make test` for a full clean validation pass.

**`make ci` is the canonical gate; run it before merging any branch to main.** It runs the brand/accessibility/tap-target/casing assertions (cheap, fail-fast), then the full iOS test lane followed by the watchOS test lane. A green `make ci` means both lanes passed; `make sim-json` is only the faster inner-loop build check, not a substitute for the gate.

**Local DerivedData** (`./DerivedData/`, gitignored) — NEVER delete, breaks SPM cache.

**xcsift** — `brew install xcsift`. `make sim-json` pipes build output through it for structured errors.

## Dependencies

- `solpbc/spl-swift` (product `SPLTunnel`) — SPL tunnel package pinned at `exactVersion: 0.3.2`; provides pairing, relay, inner mTLS, mux, and loopback transport.
- `apple/swift-crypto` (product `Crypto`) — used directly by `Sources/MobileSegment/MobileSegmentUploader.swift` and declared explicitly on the app and test targets.
- `alta/swift-opus` (product `Opus`) — Opus decode for the BLE pendant audio; used in `Sources/Omi/OmiOpusAudioDecoder.swift`.

## Swift 6 concurrency

- Types are `@MainActor`-isolated by default. Mark `nonisolated` explicitly; the `WKNavigationDelegate` callbacks in `Sources/Portal/InAppJournalView.swift` are `nonisolated`.
- Never `nonisolated(unsafe)` — fix isolation instead.
- All `Sendable` conformance explicit.

## Logging

- Always `os.Logger`. All levels surface in `log collect` (sudo). `.debug` is silent on `devicectl --console` and `pymobiledevice3 syslog` — that's fine for production, use `log collect` for post-hoc.
- `print()` / `NSLog()` silently drop from background threads/queues — do not use them in production code.
- Subsystem: `app.solstone.swift`.

## Safety rails

- **Never run `security` keychain commands without operator approval.** `make signing-check` and `make unlock` are approved read-only targets. No `set-key-partition-list`, `delete-*`, or `dump-keychain` without asking.
- **Never force-push a branch someone else might be working on.**
- **Don't delete `DerivedData/`** — breaks SPM cache resolution.
- **All product changes go through Makefile targets.** Don't compose `xcodebuild` / `devicectl` / `simctl` by hand.

## Agent skills (install on the Mac)

- **xcsift** — `brew install xcsift` then `xcsift install-claude-code`
- **AXe** — `brew tap cameroncooke/axe && brew install axe` then `axe init --client claude`
- **Swift Concurrency** — `AvdLee/Swift-Concurrency-Agent-Skill`
- **SwiftUI Pro** — `twostraws/swiftui-agent-skill`

## Brand

- Follow lowercase-first UI copy in visible product text.
- Exceptions are limited to HIG cancel/destructive labels, `accessibilityHint` / `accessibilityLabel`, third-party proper nouns, protocol and URL literals, and AM/PM or date abbreviations.
- Canonical brand source is sol pbc's internal brand canon, kept outside this repo.
- Sync shipped brand assets with `make brand-sync` (set `BRAND_DIR=/path/to/brand` to point at the canon).
- `Tests/BrandColorTests.swift` is the tripwire for canonical `solOrange`, `solGold`, `orangeInk`, and `AccentColor`.
- Keep `Sources/Design/Colors.swift` numeric triples locked; update brand assets through `make brand-sync`, not ad hoc edits.
- Owner-visible copy must avoid surveillance verbs (capture / record / recording / watch / monitor / track / collect) and the labels keeper / assistant / server / service. Non-UI Apple framework names and internal implementation identifiers (e.g. `AVAudioSession.Category`, `requestRecordPermission`, `UNUserNotificationCenter`, `LiveObserverRecorder`, `recordAudioFinalized`) are fine — keep them out of user-visible strings.
