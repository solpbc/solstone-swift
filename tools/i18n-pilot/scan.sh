#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc

set -euo pipefail
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host"
mkdir -p build/i18n-pilot
xcrun swiftc -I "$toolchain" -L "$toolchain" -Xlinker -rpath -Xlinker "$toolchain" tools/i18n-pilot/SyntaxScan.swift -o build/i18n-pilot/scan
python3 -c 'import pathlib, subprocess; files=sorted(str(p) for root in ["Sources","Tests","Watch","WatchTests","SolstoneShareExtension","SolstoneLiveActivityWidget","SolstoneWatchComplication"] for p in pathlib.Path(root).rglob("*.swift")); subprocess.run(["build/i18n-pilot/scan",*files],check=True,stdout=open("build/i18n-pilot/syntax.json","w"))'
