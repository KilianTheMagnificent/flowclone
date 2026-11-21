"""Exercise update publication, archive validation, and team-locked signing invariants."""
from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

import resolve_signing_identity
import validate_release_archive


ROOT = Path(__file__).resolve().parent.parent


class UpdatePublicationTests(unittest.TestCase):
    def run_publish(self, visibility="public", repo=None, bridge=False):
        with tempfile.TemporaryDirectory(prefix="flowclone-publish-test-") as directory:
            scratch = Path(directory)
            gh = scratch / "gh"
            gh.write_text("#!/bin/sh\n"
                          'if [ "$1" != api ]; then echo "unexpected GitHub mutation" >&2; exit 99; fi\n'
                          f"printf '%s\\n' '{visibility}'\n")
            gh.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = str(scratch) + os.pathsep + environment["PATH"]
            environment["FLOWCLONE_BUILD_ROOT"] = str(scratch / "build")
            environment.pop("FLOWCLONE_RELEASE_REPO", None)
            environment.pop("FLOWCLONE_PUBLISH_LEGACY_BRIDGE", None)
            if repo:
                environment["FLOWCLONE_RELEASE_REPO"] = repo
            if bridge:
                environment["FLOWCLONE_PUBLISH_LEGACY_BRIDGE"] = "1"
            return subprocess.run(["/bin/bash", str(ROOT / "build.sh"), "publish"],
                                  env=environment, capture_output=True, text=True, timeout=10)

    def test_private_primary_feed_cannot_ship(self):
        result = self.run_publish(visibility="private")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update repository must be public", result.stderr)

    def test_unknown_visibility_cannot_ship(self):
        result = self.run_publish(visibility="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update repository must be public", result.stderr)

    def test_unrelated_destination_cannot_ship_even_with_bridge_flag(self):
        result = self.run_publish(repo="another/repository", bridge=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destination differs", result.stderr)

    def test_legacy_bridge_requires_explicit_switch(self):
        result = self.run_publish(repo="KilianTheMagnificent/flowclone-releases")
        self.assertIn("destination differs", result.stderr)
        allowed = self.run_publish(repo="KilianTheMagnificent/flowclone-releases", bridge=True)
        self.assertIn("expected exactly one staged release zip", allowed.stderr)

    def test_public_primary_feed_proceeds_to_archive_validation(self):
        result = self.run_publish()
        self.assertIn("expected exactly one staged release zip", result.stderr)

    def test_sign_rejects_mismatched_team_or_bundle_before_signing(self):
        with tempfile.TemporaryDirectory(prefix="flowclone-sign-guard-") as directory:
            env = os.environ.copy()
            env["FLOWCLONE_BUILD_ROOT"] = str(Path(directory) / "build")
            env["FLOWCLONE_TEAM_OU"] = "WRONGTEAM9"
            env["FLOWCLONE_SIGN_IDENTITY"] = "stub"
            wrong_team = subprocess.run(["/bin/bash", str(ROOT / "build.sh"), "sign"],
                                        env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(wrong_team.returncode, 0)
            self.assertIn("does not match pinned '36B25Z964W'", wrong_team.stderr)

            env["FLOWCLONE_TEAM_OU"] = "36B25Z964W"
            env["FLOWCLONE_BUNDLE_ID"] = "com.other.app"
            wrong_bundle = subprocess.run(["/bin/bash", str(ROOT / "build.sh"), "sign"],
                                          env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(wrong_bundle.returncode, 0)
            self.assertIn("does not match pinned 'com.andre.flowclone'", wrong_bundle.stderr)


class SigningIdentitySelectionTests(unittest.TestCase):
    def test_extract_ou_parses_rfc2253_subject(self):
        subj = "UID=4W2Q2SKW79,CN=Apple Development: test@example.com (ABC),OU=36B25Z964W,O=Andre Romero,C=US"
        self.assertEqual(resolve_signing_identity.extract_ou(subj), "36B25Z964W")
        self.assertIsNone(resolve_signing_identity.extract_ou("CN=AdHoc"))

    def test_select_identity_filters_team_and_prefers_developer_id(self):
        pool = [
            ("1" * 40, "Apple Development: other@example.com (OTHER)", "OTHERTEAM1"),
            ("a" * 40, "Apple Development: owner@example.com (DEV)", "36B25Z964W"),
            ("b" * 40, "Developer ID Application: Andre Romero (36B25Z964W)", "36B25Z964W"),
        ]
        sha1, name = resolve_signing_identity.select_identity(pool, "36B25Z964W")
        self.assertEqual(sha1, "B" * 40)
        self.assertTrue(name.startswith("Developer ID Application:"))

    def test_select_identity_rejects_missing_or_ambiguous_team_certs(self):
        with self.assertRaisesRegex(ValueError, "No valid Apple signing certificate"):
            resolve_signing_identity.select_identity(
                [("1" * 40, "Apple Development: other@example.com", "OTHERTEAM1")],
                "36B25Z964W",
            )
        with self.assertRaisesRegex(ValueError, "Multiple"):
            resolve_signing_identity.select_identity(
                [
                    ("a" * 40, "Apple Development: one@example.com (1)", "36B25Z964W"),
                    ("b" * 40, "Apple Development: two@example.com (2)", "36B25Z964W"),
                ],
                "36B25Z964W",
            )


class ReleaseArchiveValidatorTests(unittest.TestCase):
    def test_manifest_comparison_ignores_commit_advance_when_inputs_match(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            packaged = d / "packaged.json"
            committed = d / "committed.json"
            files = {"app/Info.plist": "abc123", "Sources/FlowClone/Updater.swift": "def456"}
            packaged.write_text(json.dumps({"schema": 1, "base_commit": "oldhead", "files_sha256": files}))
            committed.write_text(json.dumps({"schema": 1, "base_commit": "newhead", "files_sha256": files}))
            validate_release_archive.compare_manifest_files(committed, packaged)

            tampered = d / "tampered.json"
            tampered.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "base_commit": "newhead",
                        "files_sha256": {**files, "Sources/FlowClone/Updater.swift": "changed"},
                    }
                )
            )
            with self.assertRaisesRegex(ValueError, "source changed after release staging"):
                validate_release_archive.compare_manifest_files(tampered, packaged)

    def test_zip_validator_accepts_normal_zip_and_rejects_traversal_and_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            good = d / "good.zip"
            with zipfile.ZipFile(good, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                zf.writestr("FlowClone-0.3/README.txt", "install instructions")
                zf.writestr("FlowClone-0.3/FlowClone.app/Contents/Info.plist", "<plist/>")
            validate_release_archive.validate_zip_structure(good)

            traversal = d / "traversal.zip"
            with zipfile.ZipFile(traversal, "w") as zf:
                zf.writestr("../escape.txt", "nope")
            with self.assertRaisesRegex(ValueError, "unsafe path"):
                validate_release_archive.validate_zip_structure(traversal)

            duplicate = d / "duplicate.zip"
            with zipfile.ZipFile(duplicate, "w") as zf:
                zf.writestr("FlowClone.app/A.txt", "1")
                zf.writestr("flowclone.app/a.txt", "2")
            with self.assertRaisesRegex(ValueError, "duplicate case-insensitive"):
                validate_release_archive.validate_zip_structure(duplicate)

    def test_secret_scanner_rejects_embedded_anthropic_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            (d / "README.txt").write_text("clean instructions")
            validate_release_archive.scan_extracted_for_secrets(d)

            leaked = d / "FlowClone.app/Contents/Resources/config.txt"
            leaked.parent.mkdir(parents=True)
            # Construct a synthetic test-only token shape at runtime so no literal key lives in source.
            leaked.write_text("prefix-" + "sk-ant-" + ("x" * 24))
            with self.assertRaisesRegex(ValueError, "embedded Anthropic API key"):
                validate_release_archive.scan_extracted_for_secrets(d)

    def test_declared_minimum_macos_must_cover_what_the_executable_needs(self):
        single = """/tmp/FlowClone:
Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 14.0
      sdk 14.0
"""
        universal = single + "/tmp/FlowClone (architecture x86_64):\n    minos 15.2\n      sdk 15.2\n"
        self.assertEqual(validate_release_archive.parse_build_versions(single), ["14.0"])
        self.assertEqual(validate_release_archive.parse_build_versions(universal), ["14.0", "15.2"])

        check = validate_release_archive.check_minimum_system
        check("14.0", ["14.0"], ["arm64"])
        check("14", ["14.0"], ["arm64"])
        check("15.0", ["14.0"], ["x86_64", "arm64"])
        check("26.0", ["15.4"], ["arm64"])  # compared as numbers: 26 is newer than 15
        with self.assertRaisesRegex(ValueError, "needs macOS 15.0 but Info.plist promises 14.0"):
            check("14.0", ["15.0"], ["arm64"])
        with self.assertRaisesRegex(ValueError, "needs macOS 15.2"):
            check("14.0", ["14.0", "15.2"], ["arm64"])
        with self.assertRaisesRegex(ValueError, "must declare LSMinimumSystemVersion"):
            check(None, ["14.0"], ["arm64"])
        with self.assertRaisesRegex(ValueError, "does not state a minimum"):
            check("14.0", [], ["arm64"])
        with self.assertRaisesRegex(ValueError, "no Apple Silicon slice"):
            check("14.0", ["14.0"], ["x86_64"])
        for unreadable in ["", "fourteen", "14.x", "0.0", "14.0.0.0"]:
            with self.assertRaisesRegex(ValueError, "unreadable macOS version"):
                check(unreadable, ["14.0"], ["arm64"])


if __name__ == "__main__":
    unittest.main()
