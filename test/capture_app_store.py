#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
"""Capture synthetic App Store candidates on disposable simulators."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid


def run(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, timeout=180).stdout.strip()


def sim(*args):
    return run("xcrun", "simctl", *args)


def capture(device, output, name):
    path = output / (name + ".jpg")
    sim("io", device, "screenshot", "--type=jpeg", str(path))
    properties = run("sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path))
    metadata = dict(line.strip().split(": ", 1) for line in properties.splitlines()[1:])
    expected = {"iphone": (1320, 2868), "ipad": (2064, 2752), "watch": (422, 514)}[output.name]
    actual = (int(metadata["pixelWidth"]), int(metadata["pixelHeight"]))
    if actual != expected or metadata["hasAlpha"] != "no":
        raise ValueError(f"{path}: expected opaque {expected}, got {metadata}")
    (output / (name + ".json")).write_text(run("axe", "describe-ui", "--udid", device) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived", default="DerivedData")
    parser.add_argument("--output", default="build/app-store-shots")
    parser.add_argument("--family", choices=["all", "iphone", "ipad", "watch"], default="all")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    products = Path(args.derived).resolve() / "Build/Products"
    families = [
        ("iphone", "iPhone-17-Pro-Max", "iOS-26-5", "Debug-iphonesimulator/solstone-swift.app"),
        ("ipad", "iPad-Pro-13-inch-M5-12GB", "iOS-26-5", "Debug-iphonesimulator/solstone-swift.app"),
        ("watch", "Apple-Watch-Ultra-3-49mm", "watchOS-26-5", "Debug-watchsimulator/SolstoneWatch.app"),
    ]
    for family, kind, runtime, relative_app in families:
        if args.family not in ("all", family):
            continue
        app = products / relative_app
        with (app / "Info.plist").open("rb") as source:
            bundle = plistlib.load(source)["CFBundleIdentifier"]
        folder = output / family
        folder.mkdir(exist_ok=True)
        device = sim("create", "app-store-" + uuid.uuid4().hex[:12],
                     "com.apple.CoreSimulator.SimDeviceType." + kind,
                     "com.apple.CoreSimulator.SimRuntime." + runtime)
        try:
            sim("boot", device)
            sim("bootstatus", device, "-b")
            run("open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", device)
            if family != "watch":
                sim("ui", device, "appearance", "light")
                sim("status_bar", device, "override", "--time", time.strftime("%H:41"), "--batteryState", "charged",
                    "--batteryLevel", "100", "--wifiMode", "active", "--wifiBars", "3",
                    "--cellularMode", "active", "--cellularBars", "4")
            sim("install", device, str(app))
            time.sleep(30)  # Let first-boot system notifications finish before opening the app.
            if family == "watch":
                states = [("01-capturing", []), ("02-saved-for-phone", ["--screenshot-saved"])]
                common = ["--app-store-screenshots"]
            else:
                states = [("01-home", ["--ui-test-open-pane=source:audio"]),
                          ("02-audio", ["--ui-test-open-pane=source:audio"]),
                          ("03-memory-detail", ["--ui-test-open-pane=import"]),
                          ("04-on-this-device", ["--ui-test-open-pane=import"])]
                common = ["--ui-test", "--app-store-screenshots", "--ui-test-no-journal", "--ui-test-seed-audio-magic",
                          "--ui-test-seed-audio-magic-duration=185", "--ui-test-observer-recorder"]
            for index, (name, flags) in enumerate(states):
                if index:
                    sim("terminate", device, bundle)
                sim("launch", device, bundle, *common, *flags)
                time.sleep(10)  # Allow the launch and SwiftUI presentation to settle.
                if name in ("01-home", "02-audio"):
                    run("axe", "tap", "--udid", device, "--id", "source.listen", "--post-delay", "3")
                if name == "01-home":
                    if family == "iphone":
                        run("axe", "tap", "--udid", device, "--id", "BackButton", "--post-delay", "3")
                    else:
                        run("axe", "tap", "--udid", device, "--id", "dayHome.importEntry", "--post-delay", "3")
                        run("axe", "tap", "--udid", device, "--id", "import.onThisDeviceEntry", "--post-delay", "3")
                if name in ("03-memory-detail", "04-on-this-device"):
                    run("axe", "tap", "--udid", device, "--id", "import.onThisDeviceEntry", "--post-delay", "3")
                if name == "03-memory-detail":
                    run("axe", "tap", "--udid", device, "--id",
                        "onThisPhone.row.transfer:mobile-segment:A4C3E712-809A-578F-83ED-C903935D5B14:audio",
                        "--post-delay", "3")
                capture(device, folder, name)
                print(f"captured {family}/{name}.jpg", flush=True)
        except Exception:
            # Keep diagnostic evidence before removing this disposable simulator.
            sim("io", device, "screenshot", "--type=jpeg", str(folder / "failed-capture.jpg"))
            (folder / "failed-launch.log").write_text(sim(
                "spawn", device, "log", "show", "--last", "2m", "--style", "compact",
                "--predicate", 'process == "solstone-swift" OR process == "SolstoneWatch"'))
            raise
        finally:
            # Only this invocation's newly-created UUID is ever shut down or removed.
            try:
                sim("shutdown", device)
            finally:
                sim("delete", device)


if __name__ == "__main__":
    main()
