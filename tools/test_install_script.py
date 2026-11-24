"""install.sh puts nothing on the Mac unless the download is FlowClone signed by its maintainer."""
from __future__ import annotations
import functools
import hashlib
import http.server
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

INSTALLER = Path(__file__).resolve().parent.parent / "install.sh"
ASSET = "FlowClone-9.9-2099010101.zip"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "the installer only runs on an Apple Silicon Mac")
class InstallScriptTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.served = self.directory / "served"
        self.applications = self.directory / "Applications"
        self.served.mkdir()
        self.applications.mkdir()
        handler = functools.partial(QuietHandler, directory=str(self.served))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.address = f"http://127.0.0.1:{self.server.server_address[1]}"

    def make_app(self, sign: str | None) -> Path:
        """A stand-in FlowClone.app: unsigned, or signed by somebody who is not the maintainer."""
        app = self.directory / "build/FlowClone-9.9/FlowClone.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        shutil.copy("/usr/bin/true", app / "Contents/MacOS/FlowClone")
        with open(app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.andre.flowclone", "CFBundleExecutable": "FlowClone",
                           "CFBundleVersion": "2099010101", "CFBundlePackageType": "APPL",
                           "LSMinimumSystemVersion": "14.0"}, handle)
        if sign is None:
            subprocess.run(["codesign", "--remove-signature", app / "Contents/MacOS/FlowClone"],
                           check=True, capture_output=True)
        else:
            subprocess.run(["codesign", "--force", "--sign", sign, app], check=True, capture_output=True)
        return app

    def publish(self, app: Path | None, *, digest: str | None = None, name: str = ASSET) -> None:
        assets = []
        if app is not None:
            archive = self.served / name
            subprocess.run(["ditto", "-c", "-k", "--keepParent", app.parent, archive], check=True)
            actual = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
            assets.append({"name": name, "label": None, "digest": digest or actual,
                           "browser_download_url": f"{self.address}/{name}"})
        (self.served / "release.json").write_text(json.dumps({"tag_name": "b2099010101", "assets": assets}))

    def install(self) -> subprocess.CompletedProcess:
        environment = dict(os.environ, FLOWCLONE_RELEASE_API=f"{self.address}/release.json",
                           FLOWCLONE_INSTALL_DIR=str(self.applications), FLOWCLONE_NO_OPEN="1")
        return subprocess.run(["/bin/bash", str(INSTALLER)], env=environment, capture_output=True, text=True)

    def assert_refused(self, result: subprocess.CompletedProcess, reason: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertEqual(list(self.applications.iterdir()), [], "a refused download must leave nothing behind")

    def test_a_build_signed_by_someone_else_is_not_installed(self):
        self.publish(self.make_app(sign="-"))
        self.assert_refused(self.install(), "not signed by FlowClone's maintainer")

    def test_an_unsigned_build_is_not_installed(self):
        self.publish(self.make_app(sign=None))
        self.assert_refused(self.install(), "signature is broken")

    def test_a_download_that_does_not_match_its_checksum_is_not_installed(self):
        self.publish(self.make_app(sign="-"), digest="sha256:" + "0" * 64)
        self.assert_refused(self.install(), "does not match the checksum")

    def test_a_release_without_a_flowclone_download_is_refused(self):
        self.publish(self.make_app(sign="-"), name="Something-else.zip")
        self.assert_refused(self.install(), "no FlowClone download")

    def test_an_empty_release_is_refused(self):
        self.publish(None)
        self.assert_refused(self.install(), "no FlowClone download")

    def test_the_real_release_address_must_be_the_maintainers_repository(self):
        text = INSTALLER.read_text()
        self.assertIn('RELEASES="KilianTheMagnificent/flowclone-updates"', text)
        self.assertIn('"https://github.com/$RELEASES/releases/download/"*) ;;', text)
        self.assertIn('TEAM_ID="36B25Z964W"', text)


if __name__ == "__main__":
    unittest.main()
