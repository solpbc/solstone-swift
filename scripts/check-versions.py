#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
"""Check the XcodeGen version source before generation overwrites plists."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VERSIONS = {
    "CFBundleShortVersionString": "MARKETING_VERSION",
    "CFBundleVersion": "CURRENT_PROJECT_VERSION",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def reject_overrides(value, location):
    if isinstance(value, dict):
        for key, child in value.items():
            setting_key = key.split("[", 1)[0]
            require(setting_key not in VERSIONS.values() and setting_key not in
                    {"INFOPLIST_KEY_" + name for name in VERSIONS},
                    f"{location}.{key}: inherit project versions; remove override")
            reject_overrides(child, f"{location}.{key}")
    elif isinstance(value, list):
        for child in value:
            reject_overrides(child, location)


def check():
    with tempfile.TemporaryDirectory(prefix="version-check-") as temporary:
        output = Path(temporary) / "spec.json"
        subprocess.run(
            ["xcodegen", "dump", "--type", "json", "--no-env", "--quiet", "--file", str(output)],
            cwd=ROOT, check=True,
        )
        spec = json.loads(output.read_text())
    settings = spec["settings"]
    base = settings["base"]
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(base["MARKETING_VERSION"])),
            "project MARKETING_VERSION must have three numeric components")
    require(re.fullmatch(r"[1-9][0-9]*", str(base["CURRENT_PROJECT_VERSION"])),
            "project CURRENT_PROJECT_VERSION must be a positive integer")
    reject_overrides({key: value for key, value in settings.items() if key != "base"},
                     "project.settings")
    reject_overrides({key: value for key, value in base.items() if key not in VERSIONS.values()},
                     "project.settings.base")
    reject_overrides(spec.get("settingGroups", {}), "project.settingGroups")
    targets = spec["targets"]
    require(targets, "no targets found")
    checked = 0
    for name, target in targets.items():
        reject_overrides(target.get("settings", {}), f"{name}.settings")
        info = target.get("info")
        if not info:
            require(target["type"].startswith("bundle."), f"{name}: missing versioned info declaration")
            continue
        path = ROOT / info["path"]
        properties = info["properties"]
        for key, setting in VERSIONS.items():
            require(properties.get(key) == f"$({setting})", f"{name}.info.{key}: use $({setting})")
        tracked = subprocess.run(["git", "ls-files", "--", info["path"]], cwd=ROOT,
                                 check=True, capture_output=True, text=True).stdout.strip()
        ignored = subprocess.run(["git", "check-ignore", "-q", "--", info["path"]], cwd=ROOT)
        require(ignored.returncode in (0, 1), f"{info['path']}: cannot determine generated-file status")
        # An ignored, generated plist may still contain the previous generator's
        # defaults on upgrade. Its validated info.properties is the source; the
        # next generation replaces that cache. Tracked/new source plists must pass.
        generated = not tracked and ignored.returncode == 0
        if path.exists() and not generated:
            with path.open("rb") as source:
                plist = plistlib.load(source)
            for key, setting in VERSIONS.items():
                require(plist.get(key) == f"$({setting})", f"{info['path']} {key}: use $({setting})")
        elif not path.exists():
            require(not tracked, f"{info['path']}: tracked plist missing")
        checked += 1
    require(checked > 0, "no versioned bundles checked")
    # Config files may otherwise silently override the inherited version settings.
    config_names = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.xcconfig"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.split("\0")
    config_paths = {ROOT / name for name in config_names if name}
    config_paths.update((ROOT / "config").rglob("*.xcconfig"))
    for path in sorted(config_paths):
        for line in path.read_text().splitlines():
            require(not re.match(r"\s*(?:MARKETING_VERSION|CURRENT_PROJECT_VERSION|"
                                 r"INFOPLIST_KEY_CFBundle(?:ShortVersionString|Version))\s*(?:\[|=)", line),
                    f"{path.relative_to(ROOT)}: version override; edit project.yml settings.base")
    print(f"versions OK: {checked} bundles inherit {base['MARKETING_VERSION']} "
          f"({base['CURRENT_PROJECT_VERSION']}) from project.yml settings.base")


if __name__ == "__main__":
    try:
        check()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"version check failed: {error}", file=sys.stderr)
        sys.exit(1)
