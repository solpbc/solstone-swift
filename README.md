# solstone-swift

Native iOS app for [solstone](https://solpbc.org) — the private, AI-powered personal journal from sol pbc.

Hybrid shell (native SwiftUI + embedded WKWebView portal) with voice-first interaction. Forked from `extro-phone`. The shell, tunnel, voice stack, and build system are the same proven plumbing; what's added here is solstone-specific — journal-aware voice persona, mobile portal content, APNs for daily briefings, observer pipeline, Sense tab, onboarding.

## Status

Pre-alpha. Bootstrapped 2026-04-19. MVP under active development — see `cpo/specs/in-flight/mobile-ux-native-ios-android.md` in the extro org for the approved spec and `vpe/workspace/solstone-mobile-mvp-tracking.md` for wave-by-wave progress.

## Install

iOS development runs on macOS (`pro5e.local`). On Linux you can read code and write hop scopes; builds go through the Mac hopper.

Prerequisites on the Mac:
- Xcode 26+ with iOS 26+ SDK
- `brew install xcsift xcodegen`
- `pipx install pymobiledevice3`
- Apple Developer membership (Team ID configured in `project.yml`)

```
make install   # xcodegen + SPM resolve
```

## Run

```
make sim           # build + launch simulator
make sim-json      # structured xcsift build (preferred for agents)
make deploy        # build + install to iPhone
make logs          # device syslog tail
```

Full target list: `make help`.

## Test

```
make test
make test-one TEST=ClassTests/testMethod
```

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE).

Copyright (c) 2026 sol pbc
