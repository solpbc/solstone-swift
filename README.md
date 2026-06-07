# solstone-swift

Native iOS app for [solstone](https://solpbc.org), an open source, local-first journal of what you see and hear, for the agents you use. On your machine, always private, only yours.

Hybrid shell (native SwiftUI + embedded WKWebView portal) with voice-first interaction. It brings together a journal-aware voice persona, the mobile portal, APNs daily briefings, the observer pipeline, the Sense tab, and native onboarding over a tunneled connection to your solstone journal.

## Status

Pre-alpha. Bootstrapped 2026-04-19. MVP under active development.

## Install

iOS development runs on macOS. On Linux you can read code and write hop scopes; builds go through the Mac build host.

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
