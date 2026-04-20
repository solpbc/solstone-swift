# solstone-swift

Native iOS app for solstone — the private, AI-powered personal journal from sol pbc. Hybrid SwiftUI shell with embedded WKWebView portal and WebRTC voice. Universal iPhone + iPad. Private repo. Bundle ID: `org.solpbc.solstone-swift`.

*Build conventions follow `cto/standards/project-conventions.md`; engineering philosophy follows `cto/standards/engineering-principles.md`.*

> **Wave 5 — onboarding, pairing, offline, and terminology landed.** The app now gates the shell behind native onboarding, persists pair/session state, surfaces Day-0/Day-1 states, adds a single offline banner plus file-backed portal cache metadata, and enforces the terminology grep in `bash test/assert_terminology.sh`. Existing Wave 4 observer/voice separation remains enforced by the negative assertions in `make integration-test-observer` and `make integration-test-onboarding`.

## Principles

- **Privacy is an architecture decision.** Voice audio flows P2P phone ↔ OpenAI Realtime — acceptable tradeoff for low-latency voice, disclosed clearly. Observer audio goes to the owner's journal server, never sol pbc. No analytics, no crash reporting, no telemetry. No phone-home.
- **Agent-native.** All builds, tests, deploys, and diagnostics happen through Makefile targets — no freeform `xcodebuild` / `simctl` / `devicectl` composition. `make sim-json` pipes through xcsift for structured JSON errors an agent can parse.
- **Swift 6.2 strict concurrency.** `@MainActor` by default. `nonisolated` where it belongs (NIO handlers, WebRTC callbacks, WKScriptMessageHandler). Never `nonisolated(unsafe)` — fix the isolation. `@Observable`, not `ObservableObject`. `NavigationStack`, not `NavigationView`. `async/await`, no completion handlers.
- **`os.Logger` only.** `.info` / `.error` / `.debug` survive from any thread. `print()` and `NSLog()` silently drop from NIO dispatch queues — don't use them. Subsystem: `org.solpbc.solstone-swift`.
- **WKScriptMessageHandler is the only bridge.** URL-scheme handler (`fetch('solstone://…')`) fails cross-origin from the `http://127.0.0.1` portal. Do NOT re-introduce it.
- **Universal always.** `.sidebarAdaptable` on the TabView; size-class-aware SwiftUI. No iPhone-only hardcoding.

## Architecture

Forked from [extro-phone](https://github.com/quartzjer/extro-phone). Three-layer design inherits directly:

1. **Native SwiftUI shell** — `MainTabView` with tabs (Today / Ask / Sense / More), floating voice button overlay, keyboard shortcuts, `.sidebarAdaptable` iPad behavior.
2. **WKWebView portal** — Today and Ask route a shared webview; Sense and More are native. Portal content is served by convey's purpose-built mobile SPA endpoint (co-developed with this app wave-by-wave).
3. **WebRTC voice** — peer connection direct to OpenAI Realtime (raw stasel/WebRTC so `call_id` is controllable), ephemeral keys via the journal server, sideband tool dispatch on the server side.

**Native ↔ web bridge:**
- Native → web: `webView.evaluateJavaScript("window.location.hash = ...")`
- Web → native: `window.webkit.messageHandlers.solstone.postMessage({type, data})` handled by `PortalPage`'s `WKScriptMessageHandler`
- Routes are hash-fragment; sync is bidirectional and idempotent.

**Tunnel** — NIOSSH with Ed25519 keychain keys, LAN-first / WAN-fallback, host-key pinning, keepalive + reconnect. Self-hosted journals go through the tunnel; hosted tier is direct HTTPS.

See `cpo/specs/in-flight/mobile-ux-native-ios-android.md` (approved 2026-04-19) in extro for the full system picture.

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
make clean         # remove build artifacts
```

`make test-fast` is an inner-loop target. Run `make test-build` immediately before it, or use `make test` for a full clean validation pass.

**Local DerivedData** (`./DerivedData/`, gitignored) — NEVER delete, breaks SPM cache.

**xcsift** — `brew install xcsift`. `make sim-json` pipes build output through it for structured errors.

**Signing** — Team `VJ57N4RWDA` (Individual, Jeremie Miller). Device builds require keychain unlock + partition-list one-time on the Mac (`security set-key-partition-list`). Persistent `hopper:build` tmux window keeps the unlock state across commands.

## Dependencies

- `swift-nio-ssh` (Apple) — SSH protocol
- `swift-nio-transport-services` (Apple) — iOS-native NIO transport
- `stasel/WebRTC` — raw WebRTC bindings (chosen over Realtime SDKs so we control `call_id`)

## Swift 6 concurrency

- Types are `@MainActor`-isolated by default. Mark `nonisolated` explicitly (NIO channel handlers, WebRTC callbacks).
- Never `nonisolated(unsafe)` — fix isolation instead.
- `WKScriptMessageHandler` callback is `nonisolated` by design; wrap work in `Task { @MainActor }`.
- All `Sendable` conformance explicit.
- NIO event loops are `Sendable` — safe to share across actors.

## Logging

- Always `os.Logger`. All levels surface in `log collect` (sudo). `.debug` is silent on `devicectl --console` and `pymobiledevice3 syslog` — that's fine for production, use `log collect` for post-hoc.
- `print()` / `NSLog()` silently drop from NIO threads — do not use them in production code.
- Subsystem: `org.solpbc.solstone-swift`.

## Safety rails

- **Never run `security` keychain commands without founder approval.** `make signing-check` and `make unlock` are approved read-only targets. No `set-key-partition-list`, `delete-*`, or `dump-keychain` without asking.
- **Never force-push a branch someone else might be working on.**
- **Never reintroduce the URL scheme handler bridge** — cross-origin policy blocks it from `http://127.0.0.1`. `WKScriptMessageHandler` is the contract.
- **Don't delete `DerivedData/`** — breaks SPM cache resolution.
- **All product changes go through Makefile targets.** Don't compose `xcodebuild` / `devicectl` / `simctl` by hand.

## Known exceptions

- `Sources/Services/SSHTransport.swift` keeps `remoteHubSpawnCommand` with `extro-hub` / `--extro-root`. That path and flag are owned by the journal server repo, not the iOS app. Remove this grep exception only after the server exposes the `solstone-hub` replacement.
- Terminology grep exceptions are limited to non-UI Apple and internal implementation names: `AVAudioSession.Category.record`, `.playAndRecord`, `requestRecordPermission`, `recordPermission`, `AVCaptureMetadataOutput`, `UNUserNotificationCenter`, `ObserverRecorder`, `ObserverRecording`, `LiveObserverRecorder`, `ObserverRecordedChunk`, `IntegrationTestObserverRecorder`, `recordKeepaliveFailure`, and `recordingID`. Keep any new exception out of user-visible copy and add it to `test/assert_terminology.sh` only if it is an API or internal-only identifier.

## Agent skills (install on the Mac)

- **xcsift** — `brew install xcsift` then `xcsift install-claude-code`
- **AXe** — `brew tap cameroncooke/axe && brew install axe` then `axe init --client claude`
- **Swift Concurrency** — `AvdLee/Swift-Concurrency-Agent-Skill`
- **SwiftUI Pro** — `twostraws/swiftui-agent-skill`

## References

- Approved spec: `cpo/specs/in-flight/mobile-ux-native-ios-android.md` (in extro org)
- Master plan: `cpo/workspace/solstone-mobile-master-plan.md`
- Wave tracking: `vpe/workspace/solstone-mobile-mvp-tracking.md`
- Wave 1 grounding: `vpe/workspace/solstone-mobile-mvp-wave-1-grounding.md`
- Remote dev loop: `cto/playbooks/extro-phone-dev-loop.md`
- Architecture guide: `cto/projects/extro-hub/extro-phone-guide.md`
- Upstream source: https://github.com/quartzjer/extro-phone (extro-phone — the fork source)
