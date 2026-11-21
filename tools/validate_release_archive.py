#!/usr/bin/env python3
"""Validate staged and published FlowClone releases with recipient-Mac rules."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


MAX_DOWNLOAD_BYTES = 128 * 1024 * 1024
MAX_EXPANDED_BYTES = 512 * 1024 * 1024
ANTHROPIC_KEY_PATTERN = re.compile(rb"sk-ant-[A-Za-z0-9_-]{12,}")


def scan_extracted_for_secrets(extracted_root: Path) -> None:
    """Guarantee no personal Anthropic API key is ever bundled inside a distributed archive."""
    for path in extracted_root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            if ANTHROPIC_KEY_PATTERN.search(path.read_bytes()):
                rel = path.relative_to(extracted_root)
                raise ValueError(f"refusing archive containing an embedded Anthropic API key in {rel}")


def safe_zip_path(path: str) -> bool:
    if path.startswith("/") or "\\" in path or any(ord(ch) < 32 for ch in path):
        return False
    trimmed = path[:-1] if path.endswith("/") else path
    if not trimmed:
        return False
    parts = trimmed.split("/")
    return all(part and part not in (".", "..") for part in parts)


def validate_zip_structure(zip_path: Path) -> None:
    """Mirror Sources/FlowClone/UpdateArchive.swift byte-for-byte."""
    data = zip_path.read_bytes()
    size = len(data)
    if size < 22 or size > MAX_DOWNLOAD_BYTES:
        raise ValueError(f"archive size {size} out of bounds")

    tail_offset = size - min(size, 65_557)
    tail = data[tail_offset:]
    end = None
    for i in range(len(tail) - 22, -1, -1):
        sig = struct.unpack_from("<I", tail, i)[0]
        comment_len = struct.unpack_from("<H", tail, i + 20)[0]
        if sig == 0x06054B50 and i + 22 + comment_len == len(tail):
            end = i
            break
    if end is None:
        raise ValueError("missing or malformed ZIP end-of-central-directory")

    disk_no, dir_disk, disk_count, count, dir_size, dir_offset = struct.unpack_from(
        "<HHHHII", tail, end + 4
    )
    if disk_no != 0 or dir_disk != 0:
        raise ValueError("multi-disk ZIP archives are rejected")
    if not (1 <= count <= 10_000) or disk_count != count:
        raise ValueError(f"invalid ZIP entry count {count}")
    if dir_size > 16 * 1024 * 1024 or dir_offset + dir_size != tail_offset + end:
        raise ValueError("invalid ZIP central directory bounds")

    directory = data[dir_offset : dir_offset + dir_size]
    cursor = 0
    expanded = 0
    seen_names = set()
    for _ in range(count):
        if cursor + 46 > len(directory):
            raise ValueError("truncated central directory entry")
        sig = struct.unpack_from("<I", directory, cursor)[0]
        if sig != 0x02014B50:
            raise ValueError("invalid central directory signature")
        flags, method = struct.unpack_from("<HH", directory, cursor + 8)
        compressed, unpacked = struct.unpack_from("<II", directory, cursor + 20)
        name_len, extra_len, comment_len, entry_disk = struct.unpack_from(
            "<HHHH", directory, cursor + 28
        )
        ext_attr, local_offset = struct.unpack_from("<II", directory, cursor + 38)
        mode = (ext_attr >> 16) & 0o170000
        next_cursor = cursor + 46 + name_len + extra_len + comment_len
        if (
            (flags & 1) != 0
            or method not in (0, 8)
            or mode not in (0, 0o040000, 0o100000)
            or entry_disk != 0
            or name_len == 0
            or next_cursor > len(directory)
        ):
            raise ValueError("unsupported ZIP entry flags, method, or mode (e.g. symlink)")
        name_bytes = directory[cursor + 46 : cursor + 46 + name_len]
        try:
            name = name_bytes.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("non-UTF-8 path in ZIP") from exc
        if not safe_zip_path(name):
            raise ValueError(f"unsafe path in ZIP: {name!r}")
        folded = name.lower()
        if folded in seen_names:
            raise ValueError(f"duplicate case-insensitive path in ZIP: {name!r}")
        seen_names.add(folded)
        expanded += unpacked
        if expanded > MAX_EXPANDED_BYTES:
            raise ValueError("archive expanded size exceeds 512 MB limit")
        if local_offset + 30 > size:
            raise ValueError("local header out of bounds")
        local_sig = struct.unpack_from("<I", data, local_offset)[0]
        local_flags, local_method = struct.unpack_from("<HH", data, local_offset + 6)
        local_name_len, local_extra_len = struct.unpack_from("<HH", data, local_offset + 26)
        body_offset = local_offset + 30 + local_name_len + local_extra_len
        if (
            local_sig != 0x04034B50
            or local_flags != flags
            or local_method != method
            or local_name_len != name_len
            or body_offset + compressed > dir_offset
            or data[local_offset + 30 : local_offset + 30 + name_len] != name_bytes
        ):
            raise ValueError(f"local/central header mismatch for {name!r}")
        cursor = next_cursor
    if cursor != len(directory):
        raise ValueError("trailing bytes in ZIP central directory")


def find_single_app(extracted_root: Path) -> Path:
    """Mirror Updater.findApp(in:) — at most one wrapper folder, no symlinks."""
    top = [p for p in extracted_root.iterdir() if not p.name.startswith(".")]
    entries = list(top)
    for item in top:
        if item.suffix != ".app" and item.name != "__MACOSX":
            if item.is_dir() and not item.is_symlink():
                entries.extend(p for p in item.iterdir() if not p.name.startswith("."))
    apps = []
    for candidate in entries:
        if candidate.suffix == ".app":
            if candidate.name != "FlowClone.app" or not candidate.is_dir() or candidate.is_symlink():
                raise ValueError(f"unexpected application in archive: {candidate}")
            apps.append(candidate)
    if len(apps) != 1:
        raise ValueError(f"archive must contain exactly one FlowClone.app (found {len(apps)})")
    return apps[0]


def version_tuple(text: str) -> tuple[int, ...]:
    parts = text.strip().split(".")
    if not 1 <= len(parts) <= 3 or not all(part.isdigit() for part in parts) or int(parts[0]) <= 0:
        raise ValueError(f"unreadable macOS version {text!r}")
    return tuple(int(part) for part in parts) + (0,) * (3 - len(parts))


def parse_build_versions(vtool_output: str) -> list[str]:
    """Minimum macOS of every slice, from `vtool -show-build` (LC_BUILD_VERSION minos)."""
    return re.findall(r"^\s*minos\s+([0-9.]+)\s*$", vtool_output, flags=re.MULTILINE)


def check_minimum_system(declared: object, binary_minimums: list[str], architectures: list[str]) -> None:
    """The updater installs a build wherever Info.plist says it runs, so that must be true.

    If the executable needs a newer macOS than LSMinimumSystemVersion declares, Macs in
    between would install an update that cannot start.
    """
    if not isinstance(declared, str):
        raise ValueError("Info.plist must declare LSMinimumSystemVersion")
    declared_version = version_tuple(declared)
    if not binary_minimums:
        raise ValueError("executable does not state a minimum macOS version")
    for minimum in binary_minimums:
        if version_tuple(minimum) > declared_version:
            raise ValueError(
                f"executable needs macOS {minimum} but Info.plist promises {declared} — "
                "raise LSMinimumSystemVersion or lower the deployment target"
            )
    if "arm64" not in architectures:
        raise ValueError(f"executable has no Apple Silicon slice (found {' '.join(architectures) or 'none'})")


def validate_minimum_system(app: Path, info: dict) -> None:
    executable = app / "Contents/MacOS" / info.get("CFBundleExecutable", "FlowClone")
    builds = subprocess.run(
        ["/usr/bin/xcrun", "vtool", "-show-build", str(executable)],
        capture_output=True, text=True, check=True,
    ).stdout
    architectures = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(executable)], capture_output=True, text=True, check=True
    ).stdout.split()
    check_minimum_system(info.get("LSMinimumSystemVersion"), parse_build_versions(builds), architectures)


def compare_manifest_files(current_manifest_path: Path, packaged_manifest_path: Path) -> None:
    """Verify every allowlisted release input matches byte-for-byte, even after git commit."""
    current = json.loads(current_manifest_path.read_text())
    packaged = json.loads(packaged_manifest_path.read_text())
    if current.get("files_sha256") != packaged.get("files_sha256"):
        cur_files = current.get("files_sha256", {})
        pkg_files = packaged.get("files_sha256", {})
        changed = sorted(
            k for k in set(cur_files) | set(pkg_files) if cur_files.get(k) != pkg_files.get(k)
        )
        preview = ", ".join(changed[:5]) + ("…" if len(changed) > 5 else "")
        raise ValueError(
            f"source changed after release staging ({preview}) — rebuild before publishing"
        )


def validate_archive(
    zip_path: Path,
    expected_bundle_id: str,
    expected_team_ou: str,
    expected_update_repo: str,
    require_timestamp: bool = True,
    current_manifest_path: Path | None = None,
) -> Path:
    if not zip_path.is_file():
        raise ValueError(f"missing archive: {zip_path}")
    stem = zip_path.stem
    parts = stem.split("-")
    if len(parts) != 3 or parts[0] != "FlowClone" or not parts[2].isdigit() or int(parts[2]) <= 0:
        raise ValueError(f"archive filename must be FlowClone-<version>-<build>.zip: {zip_path.name}")
    expected_ver, expected_build = parts[1], parts[2]

    validate_zip_structure(zip_path)

    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="flowclone-archive-verify-") as tmp:
        extracted = Path(tmp)
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(zip_path), str(extracted)], check=True)
        app = find_single_app(extracted)
        readme = app.parent / "README.txt"
        if not readme.is_file():
            raise ValueError("archive wrapper is missing README.txt for first-time installers")

        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != expected_bundle_id:
            raise ValueError(f"bundle id {info.get('CFBundleIdentifier')!r} != {expected_bundle_id!r}")
        if info.get("FlowCloneTeamIdentifier") not in (None, expected_team_ou):
            raise ValueError(f"bundled team id {info.get('FlowCloneTeamIdentifier')!r} != {expected_team_ou!r}")
        if info.get("FlowCloneUpdateRepository") != expected_update_repo:
            raise ValueError(
                f"archive update feed {info.get('FlowCloneUpdateRepository')!r} != {expected_update_repo!r}"
            )
        if info.get("CFBundleShortVersionString") != expected_ver or info.get("CFBundleVersion") != expected_build:
            raise ValueError(
                f"archive name ({expected_ver} / {expected_build}) != Info.plist "
                f"({info.get('CFBundleShortVersionString')} / {info.get('CFBundleVersion')})"
            )
        if "FlowCloneUpdateToken" in info:
            raise ValueError("refusing archive with embedded FlowCloneUpdateToken")
        validate_minimum_system(app, info)

        scan_extracted_for_secrets(extracted)

        if current_manifest_path is not None:
            compare_manifest_files(
                current_manifest_path, app / "Contents/Resources/BuildManifest.json"
            )

        requirement = (
            f'identifier "{expected_bundle_id}" and anchor apple generic '
            f'and certificate leaf[subject.OU] = "{expected_team_ou}"'
        )
        verify = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", f"-R={requirement}", str(app)],
            capture_output=True,
            text=True,
        )
        if verify.returncode != 0:
            raise ValueError(
                f"signature rejected against recipient designated requirement: {verify.stderr.strip()}"
            )

        sig_details = subprocess.run(
            ["/usr/bin/codesign", "-dvvv", str(app)], capture_output=True, text=True, check=True
        ).stderr
        if require_timestamp and "\nTimestamp=" not in sig_details and not sig_details.startswith("Timestamp="):
            raise ValueError("signature is missing a cryptographic Apple timestamp (--timestamp)")

        perm_check = subprocess.run(
            [sys.executable, str(root / "tools/check_app_permissions.py"), "--app", str(app)],
            capture_output=True,
            text=True,
        )
        if perm_check.returncode != 0:
            raise ValueError(perm_check.stderr.strip() or "permission packaging check failed")

    return zip_path


def verify_published_anonymous_feed(repo: str, zip_path: Path, attempts: int = 5) -> None:
    """Confirm an unauthenticated fresh Mac can read metadata and reach the exact asset."""
    parts = zip_path.stem.split("-")
    if len(parts) != 3:
        raise ValueError(f"unexpected archive name {zip_path.name}")
    expected_tag = f"b{parts[2]}"
    expected_size = zip_path.stat().st_size
    expected_digest = "sha256:" + hashlib.sha256(zip_path.read_bytes()).hexdigest()

    meta_url = f"https://api.github.com/repos/{repo}/releases/latest"
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(
                meta_url,
                headers={
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                    "User-Agent": "FlowClone-ReleaseVerifier",
                },
            )
            with urllib.request.urlopen(req, timeout=20) as resp:
                if resp.status != 200:
                    raise ValueError(f"anonymous latest-release HTTP {resp.status}")
                payload = json.loads(resp.read().decode("utf-8"))
            if payload.get("tag_name") != expected_tag:
                raise ValueError(
                    f"latest release tag is {payload.get('tag_name')!r}, expected {expected_tag!r}"
                )
            assets = [a for a in payload.get("assets", []) if a.get("name") == zip_path.name]
            if len(assets) != 1:
                raise ValueError(f"expected exactly 1 {zip_path.name} asset in {expected_tag}")
            asset = assets[0]
            if asset.get("size") != expected_size:
                raise ValueError(f"published size {asset.get('size')} != local {expected_size}")
            if asset.get("digest") and asset["digest"].lower() != expected_digest:
                raise ValueError(
                    f"published digest {asset.get('digest')} != local {expected_digest}"
                )
            dl_req = urllib.request.Request(
                asset["url"],
                headers={
                    "Accept": "application/octet-stream",
                    "X-GitHub-Api-Version": "2022-11-28",
                    "Range": "bytes=0-21",
                    "User-Agent": "FlowClone-ReleaseVerifier",
                },
            )
            with urllib.request.urlopen(dl_req, timeout=20) as dl_resp:
                if dl_resp.status not in (200, 206):
                    raise ValueError(f"anonymous asset download HTTP {dl_resp.status}")
                if not dl_resp.url.startswith("https://"):
                    raise ValueError("asset redirect did not remain on HTTPS")
                prefix = dl_resp.read(4)
                if prefix != b"PK\x03\x04":
                    raise ValueError("downloaded asset stream does not begin with a ZIP header")
            return
        except (urllib.error.URLError, ValueError, KeyError, json.JSONDecodeError) as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(2)
    raise ValueError(f"anonymous public feed verification failed: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", type=Path, help="path to FlowClone-<version>-<build>.zip")
    parser.add_argument("--bundle-id", help="expected CFBundleIdentifier (defaults to app/Info.plist)")
    parser.add_argument("--team-ou", help="expected Apple Team ID (defaults to app/Info.plist)")
    parser.add_argument("--update-repo", help="expected FlowCloneUpdateRepository (defaults to app/Info.plist)")
    parser.add_argument(
        "--current-manifest",
        type=Path,
        help="compare packaged BuildManifest.json files_sha256 against this manifest JSON",
    )
    parser.add_argument(
        "--allow-untimestamped",
        action="store_true",
        help="allow legacy archives signed before --timestamp was enabled",
    )
    parser.add_argument(
        "--verify-published",
        metavar="OWNER/REPO",
        help="verify anonymous public GitHub feed metadata and asset reachability for this zip",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    source_info = plistlib.loads((root / "app/Info.plist").read_bytes())
    bundle_id = args.bundle_id or source_info["CFBundleIdentifier"]
    team_ou = args.team_ou or source_info["FlowCloneTeamIdentifier"]
    update_repo = args.update_repo or source_info["FlowCloneUpdateRepository"]

    try:
        if args.verify_published:
            verify_published_anonymous_feed(args.verify_published, args.zip)
            print(f"Anonymous public feed verified: {args.verify_published} ({args.zip.name})")
            return
        validate_archive(
            args.zip,
            expected_bundle_id=bundle_id,
            expected_team_ou=team_ou,
            expected_update_repo=update_repo,
            require_timestamp=not args.allow_untimestamped,
            current_manifest_path=args.current_manifest,
        )
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException, ValueError) as exc:
        sys.exit(f"Release archive validation failed: {exc}")
    print(f"Release archive validation passed: {args.zip}")


if __name__ == "__main__":
    main()
