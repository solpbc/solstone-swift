#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
"""Capture the real iOS launch storyboard on disposable iPhone and iPad simulators."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import time
import uuid


def run(*args):
    return subprocess.run(
        args,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        timeout=180,
    ).stdout.strip()


def sim(*args):
    return run("xcrun", "simctl", *args)


def dimensions(path):
    properties = run("sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path))
    metadata = dict(line.strip().split(": ", 1) for line in properties.splitlines()[1:])
    return int(metadata["pixelWidth"]), int(metadata["pixelHeight"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived", default="DerivedData")
    parser.add_argument("--output", default="build/launch-screen-shots")
    args = parser.parse_args()

    app = Path(args.derived).resolve() / "Build/Products/Debug-iphonesimulator/solstone-swift.app"
    with (app / "Info.plist").open("rb") as source:
        bundle = plistlib.load(source)["CFBundleIdentifier"]

    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    families = [
        ("iphone", "iPhone-17-Pro-Max", (1320, 2868)),
        ("ipad", "iPad-Pro-13-inch-M5-12GB", (2064, 2752)),
    ]

    for family, kind, expected in families:
        for appearance in ("light", "dark"):
            device = sim(
                "create",
                "launch-screen-" + uuid.uuid4().hex[:12],
                "com.apple.CoreSimulator.SimDeviceType." + kind,
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            )
            failure = None
            try:
                sim("boot", device)
                sim("bootstatus", device, "-b")
                sim("ui", device, "appearance", appearance)
                sim("install", device, str(app))
                sim("launch", device, bundle, "--ui-test-hold-launch-screen")
                time.sleep(0.6)
                path = output / f"{family}-{appearance}.png"
                sim("io", device, "screenshot", str(path))
                actual = dimensions(path)
                if actual != expected:
                    raise ValueError(f"{path}: expected {expected}, got {actual}")
                print(f"captured {path.name} ({actual[0]}x{actual[1]})", flush=True)
            except Exception as error:
                failure = error
                diagnostic = output / f"{family}-{appearance}-failed.png"
                try:
                    sim("io", device, "screenshot", str(diagnostic))
                except (OSError, subprocess.SubprocessError):
                    pass
                raise
            finally:
                try:
                    sim("shutdown", device)
                except (OSError, subprocess.SubprocessError):
                    pass
                try:
                    sim("delete", device)
                except (OSError, subprocess.SubprocessError):
                    if failure is None:
                        raise


if __name__ == "__main__":
    main()
