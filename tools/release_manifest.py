#!/usr/bin/env python3
"""Record exact release inputs; fixed allowlist excludes credentials and local state."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def manifest(root):
    paths = [*root.glob("Sources/**/*.swift"), *root.glob("Tests/**/*.swift"),
             *root.glob("tools/*.py")]
    paths += [root / name for name in (
        "Package.swift", "Package.resolved", "build.sh", "test.sh", "app/Info.plist",
        "app/FlowClone.entitlements", "app/DISTRIBUTION-README.txt", "app/Parakeet-Ultra-NOTICE.txt", "app/AppIcon.icns", "app/Assets.car",
        "app/StartCue.aiff", "spikes/say8.wav")]
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(paths)}
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    return {"schema": 1, "base_commit": head, "files_sha256": hashes}


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    Path(sys.argv[1]).write_text(json.dumps(manifest(root), sort_keys=True, indent=2) + "\n")
