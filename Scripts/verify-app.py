#!/usr/bin/env python3
"""Verify the packaged test app on macOS; emit measured build metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise SystemExit(f"App verification failed: {message}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    require(app.name == "且听.app", "the downloadable app must be named 且听.app")
    require(info["CFBundleName"] == "且听" and info["CFBundleDisplayName"] == "且听",
            "Finder, Dock and app-menu names must be 且听")
    require(info["CFBundleExecutable"] == "Kumone", "preserve the internal executable name")
    require(info["LSMinimumSystemVersion"] == "26.0", "Info.plist deployment target must be 26.0")
    require(info["CFBundleIdentifier"] == "com.hoviksinn.kumone.test", "test Bundle ID required")
    require(info.get("KumoneDisableUpdates") is True, "updater must be disabled")
    require(info.get("SUEnableAutomaticChecks") is False, "automatic checks must be disabled")
    require(info.get("SUAllowsAutomaticUpdates") is False, "automatic installs must be disabled")
    require("SUFeedURL" not in info and "SUPublicEDKey" not in info, "upstream update metadata found")
    require(info.get("CFBundleIconName") == "AppIcon", "the compiled app icon must be configured")
    icon_resources = app / "Contents/Resources"
    require((icon_resources / "Assets.car").is_file()
            and (icon_resources / "Assets.car").stat().st_size > 0,
            "actool did not compile the QieTing app icon")
    icon_source = icon_resources / "AppIcon.icon"
    with (icon_source / "icon.json").open() as handle:
        icon_manifest = json.load(handle)
    icon_layers = [layer["image-name"] for group in icon_manifest["groups"]
                   for layer in group["layers"]]
    require(icon_layers and all(name.endswith(".svg")
                               and (icon_source / "Assets" / name).is_file()
                               for name in icon_layers),
            "the app icon must use the editable QieTing vector artwork")

    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    load_commands = command("otool", "-l", str(executable))
    version = re.search(r"\bcmd LC_BUILD_VERSION\b.*?\bminos ([\d.]+)", load_commands, re.S)
    require(version is not None, "main executable has no LC_BUILD_VERSION")
    require(tuple(map(int, version[1].split("."))) in ((26, 0), (26, 0, 0)),
            f"main executable minos is {version[1]}, expected 26.0")

    binaries = []
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if "Mach-O" in command("file", "-b", str(path)):
            arches = command("lipo", "-archs", str(path)).split()
            require(arches == ["arm64"], f"{path.relative_to(app)} contains {arches}")
            binaries.append({"path": str(path.relative_to(app)), "architectures": arches})
    require(any(item["path"] == str(executable.relative_to(app)) for item in binaries),
            "main executable was not identified as Mach-O")
    kernels = app / "Contents/MacOS/mlx.metallib"
    require(kernels.is_file() and kernels.stat().st_size > 0, "MLX Metal kernels are missing")
    report = {
        "app_name": info["CFBundleDisplayName"],
        "app_bundle": app.name,
        "executable_name": info["CFBundleExecutable"],
        "icon_layers": icon_layers,
        "icon_assets_bytes": (icon_resources / "Assets.car").stat().st_size,
        "bundle_id": info["CFBundleIdentifier"],
        "minimum_system_version": info["LSMinimumSystemVersion"],
        "executable_minos": version[1],
        "updates_disabled": True,
        "git_commit": info["KumoneGitCommit"],
        "app_file_bytes": sum(p.stat().st_size for p in app.rglob("*")
                              if p.is_file() and not p.is_symlink()),
        "executable_bytes": executable.stat().st_size,
        "metallib_bytes": kernels.stat().st_size,
        "metallib_sha256": hashlib.sha256(kernels.read_bytes()).hexdigest(),
        "mach_o_binaries": binaries,
        "scope": "Main executable targets macOS 26.0; vendored helper deployment floors are unchanged.",
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
