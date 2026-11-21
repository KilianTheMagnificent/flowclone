#!/usr/bin/env python3
"""Write the public copy of the source: only the listed paths, as committed, checked for private data.

    python3 tools/export_public.py "<checkout of the public repository>"

The public repository is a separate one with its own history; this repository's history and
its docs/ folder (install logs, notes on the maintainer's own dictations) are never published.
The script replaces the checkout's files, keeps its .git, and stops if anything private would
go out. It does not commit or push.
"""
from __future__ import annotations
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Everything else stays private. Add a path here only after reading the file for personal data.
PUBLIC_PATHS = [
    "Sources", "Tests", "Package.swift", "Package.resolved", "build.sh", "test.sh",
    "app", "assets", "tools", "spikes/say8.wav", "docs/meeting-notes/google-sign-in.md",
    "README.md", "LICENSE", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", ".gitignore",
]

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})\b")
PUBLIC_EMAIL_DOMAINS = {
    "example.com", "users.noreply.github.com",
    "group.calendar.google.com", "resource.calendar.google.com",
}
HOME_PATH = re.compile(r"/Users/(?!example\b|someone\b|Shared\b)[A-Za-z0-9._-]+")
MARKDOWN_LINK = re.compile(r"\]\(([^)#\s]+)(?:#[^)]*)?\)")


def private_findings(root: Path) -> list[str]:
    """Personal email addresses, home-folder paths and links to files that are not published."""
    findings = []
    for path in sorted(p for p in root.rglob("*") if p.is_file() and ".git" not in p.relative_to(root).parts):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue  # binary assets: icons, sounds
        name = path.relative_to(root)
        for number, line in enumerate(text.splitlines(), 1):
            for match in EMAIL.finditer(line):
                if match.group(1).lower() not in PUBLIC_EMAIL_DOMAINS:
                    findings.append(f"{name}:{number}: email address {match.group(0)}")
            for match in HOME_PATH.finditer(line):
                findings.append(f"{name}:{number}: home folder path {match.group(0)}")
            if path.suffix == ".md":
                for match in MARKDOWN_LINK.finditer(line):
                    target = match.group(1)
                    if "://" in target or target.startswith("mailto:"):
                        continue
                    if not (path.parent / target).exists():
                        findings.append(f"{name}:{number}: link to a file that is not published: {target}")
    return findings


def uncommitted(root: Path, paths: list[str]) -> list[str]:
    out = subprocess.run(["git", "status", "--porcelain", "--", *paths],
                         cwd=root, capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line.strip()]


def export(root: Path, destination: Path, paths: list[str]) -> int:
    """Replace `destination`'s files (not its .git) with `paths` as committed at HEAD."""
    root, destination = root.resolve(), destination.resolve()
    if destination == root or root in destination.parents or destination in root.parents:
        raise ValueError("the public checkout must be outside this repository")
    if destination.exists() and any(destination.iterdir()) and not (destination / ".git").exists():
        raise ValueError(f"{destination} is not empty and is not a git checkout; refusing to replace its files")
    dirty = uncommitted(root, paths)
    if dirty:
        raise ValueError("commit these first, the public copy is made from HEAD:\n  " + "\n  ".join(dirty))
    destination.mkdir(parents=True, exist_ok=True)
    for child in destination.iterdir():
        if child.name == ".git":
            continue
        shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
    with tempfile.NamedTemporaryFile(suffix=".tar") as archive:
        subprocess.run(["git", "archive", "--format=tar", "-o", archive.name, "HEAD", "--", *paths],
                       cwd=root, check=True)
        subprocess.run(["/usr/bin/tar", "-xf", archive.name, "-C", str(destination)], check=True)
    return sum(1 for p in destination.rglob("*") if p.is_file() and ".git" not in p.relative_to(destination).parts)


def scan_secrets(destination: Path) -> None:
    gitleaks = shutil.which("gitleaks")
    if not gitleaks:
        raise ValueError("gitleaks is not installed (brew install gitleaks); the public copy must be scanned")
    result = subprocess.run([gitleaks, "dir", str(destination), "--no-banner", "--redact"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError("gitleaks found secrets:\n" + (result.stdout + result.stderr).strip())


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    destination = Path(sys.argv[1]).expanduser()
    try:
        count = export(ROOT, destination, PUBLIC_PATHS)
        findings = private_findings(destination)
        if findings:
            raise ValueError("private data in the public copy:\n  " + "\n  ".join(findings))
        scan_secrets(destination)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"Public export stopped: {error}")
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                          capture_output=True, text=True, check=True).stdout.strip()
    print(f"Public copy written to {destination}: {count} files from {head}, no private data or secrets found.")
    print("Not committed or pushed. Review `git status` there, then commit.")


if __name__ == "__main__":
    main()
