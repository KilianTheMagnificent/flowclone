"""The public copy holds only the listed paths and nothing personal."""
from __future__ import annotations
import subprocess
import tempfile
import unittest
from pathlib import Path

import export_public


def git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", *args],
                   cwd=cwd, check=True, capture_output=True)


class PublicExportTests(unittest.TestCase):
    def make_source(self, directory: Path) -> Path:
        source = directory / "private"
        (source / "Sources").mkdir(parents=True)
        (source / "docs").mkdir()
        (source / "Sources/App.swift").write_text("let greeting = \"hello\"\n")
        (source / "README.md").write_text("# App\n")
        (source / "docs/install-log.md").write_text("installed for the owner\n")
        (source / "PLAN.md").write_text("private plan\n")
        git(source, "init", "-q")
        git(source, "add", "-A")
        git(source, "commit", "-q", "-m", "first")
        return source

    def test_only_listed_paths_are_exported_and_stale_files_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            source = self.make_source(d)
            public = d / "public"
            (public / ".git").mkdir(parents=True)
            (public / ".git/keep").write_text("history")
            (public / "old.swift").write_text("removed upstream")
            (public / "olddir").mkdir()
            (public / "olddir/file").write_text("removed upstream")

            count = export_public.export(source, public, ["Sources", "README.md"])

            self.assertEqual(count, 2)
            self.assertEqual((public / "Sources/App.swift").read_text(), "let greeting = \"hello\"\n")
            self.assertTrue((public / "README.md").is_file())
            self.assertFalse((public / "docs").exists())
            self.assertFalse((public / "PLAN.md").exists())
            self.assertFalse((public / "old.swift").exists())
            self.assertFalse((public / "olddir").exists())
            self.assertEqual((public / ".git/keep").read_text(), "history")

    def test_export_is_made_from_committed_files_only(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            source = self.make_source(d)
            (source / "Sources/App.swift").write_text("let greeting = \"not committed\"\n")
            with self.assertRaisesRegex(ValueError, "commit these first"):
                export_public.export(source, d / "public", ["Sources", "README.md"])
            # A change outside the published paths does not block it.
            git(source, "checkout", "--", "Sources/App.swift")
            (source / "PLAN.md").write_text("still private, still changing\n")
            export_public.export(source, d / "public", ["Sources", "README.md"])

    def test_export_refuses_a_folder_it_should_not_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            source = self.make_source(d)
            documents = d / "documents"
            documents.mkdir()
            (documents / "thesis.txt").write_text("not ours to delete")
            with self.assertRaisesRegex(ValueError, "not a git checkout"):
                export_public.export(source, documents, ["Sources"])
            self.assertEqual((documents / "thesis.txt").read_text(), "not ours to delete")
            for inside in (source, source / "Sources", d):
                with self.assertRaisesRegex(ValueError, "outside this repository"):
                    export_public.export(source, inside, ["Sources"])
            self.assertTrue((source / "PLAN.md").is_file())

    def test_personal_data_and_dangling_links_are_found(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            (root / "docs/setup.md").write_text("ok\n")
            (root / "clean.swift").write_text(
                "let a = \"andre@example.com\"\n"
                "let b = \"/Users/example/Applications/FlowClone.app\"\n"
                "let c = \"137663596+KilianTheMagnificent@users.noreply.github.com\"\n"
                "let d = \"team@group.calendar.google.com\"\n"
                "@MainActor func run() {}\n")
            (root / "README.md").write_text(
                "[setup](docs/setup.md) [site](https://example.org/a.md) [top](#install)\n")
            (root / "icon.bin").write_bytes(b"\xff\xfe\x00someone" + b"@" + b"gmail.com")
            self.assertEqual(export_public.private_findings(root), [])

            (root / "leak.swift").write_text(
                "// tested by " + "someone" + "@" + "gmail.com\n"
                "let log = \"/Users/" + "realname" + "/Library/Logs/FlowClone.log\"\n")
            (root / "README.md").write_text("[notes](docs/TODO.md)\n")
            findings = export_public.private_findings(root)
            self.assertEqual(len(findings), 3)
            self.assertIn("README.md:1: link to a file that is not published: docs/TODO.md", findings)
            self.assertTrue(any("leak.swift:1: email address" in f for f in findings))
            self.assertTrue(any("leak.swift:2: home folder path /Users/" + "realname" in f for f in findings))

    def test_every_published_path_exists(self):
        for path in export_public.PUBLIC_PATHS:
            self.assertTrue((export_public.ROOT / path).exists(), path)
        for private in ("docs", "docs/TODO.md", "AGENTS.md", "PLAN.md", "REDTEAM.md", "spikes"):
            self.assertNotIn(private, export_public.PUBLIC_PATHS)


if __name__ == "__main__":
    unittest.main()
