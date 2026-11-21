#!/usr/bin/env python3
"""Resolve an unambiguous Keychain code-signing identity for FlowClone's pinned Apple Team."""
from __future__ import annotations
import argparse
import hashlib
import plistlib
from pathlib import Path
import re
import subprocess
import sys


IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$')
PEM_BLOCK = re.compile(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", re.DOTALL)


def extract_ou(rfc2253_subject: str) -> str | None:
    match = re.search(r"(?:^|,)\s*OU=([^,]+)", rfc2253_subject)
    return match.group(1).strip() if match else None


def pem_sha1(pem: str) -> str:
    der = subprocess.run(
        ["/usr/bin/openssl", "x509", "-outform", "DER"],
        input=pem.encode("utf-8"),
        capture_output=True,
        check=True,
    ).stdout
    return hashlib.sha1(der).hexdigest().upper()


def pem_subject(pem: str) -> str:
    out = subprocess.run(
        ["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
        input=pem,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    return out.removeprefix("subject=").strip()


def select_identity(
    identities: list[tuple[str, str, str | None]], expected_team_ou: str
) -> tuple[str, str]:
    """Given (sha1, common_name, team_ou) entries, choose the unambiguous identity for team."""
    matching = []
    seen_sha1 = set()
    for sha1, name, ou in identities:
        upper = sha1.upper()
        if ou == expected_team_ou and upper not in seen_sha1:
            seen_sha1.add(upper)
            matching.append((upper, name))

    if not matching:
        raise ValueError(
            f"No valid Apple signing certificate for Team {expected_team_ou} found in Keychain. "
            f"Build on the Mac that has Team {expected_team_ou}'s signing certificate installed, "
            f"or set FLOWCLONE_SIGN_IDENTITY explicitly."
        )

    dev_id = [item for item in matching if item[1].startswith("Developer ID Application:")]
    if dev_id:
        if len(dev_id) > 1:
            names = ", ".join(f"{s[:10]} ({n})" for s, n in dev_id)
            raise ValueError(
                f"Multiple Developer ID Application certificates for Team {expected_team_ou}: {names}. "
                f"Set FLOWCLONE_SIGN_IDENTITY to choose one."
            )
        return dev_id[0]

    apple_dev = [item for item in matching if item[1].startswith("Apple Development:")]
    pool = apple_dev or matching
    if len(pool) > 1:
        names = ", ".join(f"{s[:10]} ({n})" for s, n in pool)
        raise ValueError(
            f"Multiple signing certificates for Team {expected_team_ou}: {names}. "
            f"Set FLOWCLONE_SIGN_IDENTITY to choose one."
        )
    return pool[0]


def list_keychain_identities() -> list[tuple[str, str, str | None]]:
    listing = subprocess.run(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    candidates = []
    for line in listing.splitlines():
        match = IDENTITY_LINE.match(line)
        if match:
            candidates.append((match.group(1).upper(), match.group(2)))

    results: list[tuple[str, str, str | None]] = []
    for sha1, common_name in candidates:
        certs_out = subprocess.run(
            ["/usr/bin/security", "find-certificate", "-a", "-c", common_name, "-p"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        matched_ou = None
        for pem in PEM_BLOCK.findall(certs_out):
            if pem_sha1(pem) == sha1:
                matched_ou = extract_ou(pem_subject(pem))
                break
        results.append((sha1, common_name, matched_ou))
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-ou", help="expected Apple Team OU (defaults to app/Info.plist)")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    info = plistlib.loads((root / "app/Info.plist").read_bytes())
    team_ou = args.team_ou or info["FlowCloneTeamIdentifier"]
    try:
        sha1, common_name = select_identity(list_keychain_identities(), team_ou)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        sys.exit(str(exc))
    print(f"==> resolved signing identity for Team {team_ou}: {common_name} ({sha1[:10]}…)", file=sys.stderr)
    print(sha1)


if __name__ == "__main__":
    main()
