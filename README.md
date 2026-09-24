# solstone-swift

The solstone app for iphone and ipad, and its apple watch app. [solstone](https://solstone.app) is a personal memory platform: the solstone app takes in what you share with it, and all of it goes into your journal (an open source, local-first memory the agents you use can work from). Your journal is always private, only yours.

Built in SwiftUI. You choose what the app takes in (audio, location and screen, and audio from your apple watch). What it takes in goes into the journal you paired it with, in segments of up to 5 minutes. You can also import files into your journal from the system share sheet.

## Status

Open beta. Anyone can join through TestFlight at [solstone.app/beta](https://solstone.app/beta).

## Install

iOS development runs on macOS. On linux you can read and edit code; builds need a mac.

Prerequisites on the mac:
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

Full target list: see the [`Makefile`](Makefile).

## Test

```
make test
make test-one TEST=ClassTests/testMethod
```

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE).

Copyright (c) 2026 sol pbc
