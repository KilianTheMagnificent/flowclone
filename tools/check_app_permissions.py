#!/usr/bin/env python3
"""Reject source or signed bundles missing the permissions used by FlowClone."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="inspect this signed bundle instead of source")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.app:
        info_path = args.app / "Contents/Info.plist"
        result = subprocess.run(
            ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(args.app)],
            capture_output=True, check=True)
        entitlements = plistlib.loads(result.stdout)
    else:
        info_path = root / "app/Info.plist"
        entitlements = plistlib.loads((root / "app/FlowClone.entitlements").read_bytes())
    info = plistlib.loads(info_path.read_bytes())
    missing = []
    for key in ("com.apple.security.device.audio-input",
                "com.apple.security.personal-information.calendars"):
        if entitlements.get(key) is not True:
            missing.append(f"{key} must be true")
    for key in ("NSMicrophoneUsageDescription", "NSCalendarsFullAccessUsageDescription",
                "NSAudioCaptureUsageDescription"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            missing.append(f"{key} must describe the requested access")
    if missing:
        sys.exit("Permission packaging check failed: " + "; ".join(missing))
    print(f"Permission packaging check passed: {args.app or 'source'}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        sys.exit(f"Cannot inspect app permissions: {error}")
