import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "Fantastty" / "Info.plist"
PROJECT_SPEC = ROOT / "project.yml"
XCODE_PROJECT = ROOT / "Fantastty.xcodeproj" / "project.pbxproj"
APP_COMMANDS = ROOT / "Fantastty" / "App" / "AppCommands.swift"
APP_ENTRYPOINT = ROOT / "Fantastty" / "App" / "MickeyTermApp.swift"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "build-and-release.yml"
GENERATE_APPCAST_SCRIPT = ROOT / "scripts" / "generate-sparkle-appcast.sh"
GITHUB_ACTIONS_DOC = ROOT / "doc" / "GITHUB_ACTIONS_SETUP.md"
README = ROOT / "README.md"


class SparkleReleaseConfigTests(unittest.TestCase):
    def test_app_declares_github_releases_appcast_and_public_key(self):
        result = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(INFO_PLIST)],
            text=True,
            capture_output=True,
            check=True,
        )
        info = json.loads(result.stdout)

        self.assertEqual(
            info.get("SUFeedURL"),
            "https://github.com/blaine/fantastty/releases/latest/download/appcast.xml",
        )

        public_key = info.get("SUPublicEDKey")
        self.assertIsInstance(public_key, str)
        self.assertRegex(public_key, r"^[A-Za-z0-9+/]{43}=$")

    def test_project_links_sparkle_package(self):
        spec = PROJECT_SPEC.read_text()
        self.assertIn("packages:", spec)
        self.assertIn("Sparkle:", spec)
        self.assertIn("url: https://github.com/sparkle-project/Sparkle", spec)
        self.assertIn("from: 2.9.3", spec)
        self.assertIn("package: Sparkle", spec)
        self.assertIn("product: Sparkle", spec)

        project = XCODE_PROJECT.read_text()
        self.assertIn("XCRemoteSwiftPackageReference", project)
        self.assertIn("repositoryURL = \"https://github.com/sparkle-project/Sparkle\";", project)
        self.assertIn("productName = Sparkle;", project)

    def test_swiftui_app_exposes_standard_sparkle_update_action(self):
        app = APP_ENTRYPOINT.read_text()
        commands = APP_COMMANDS.read_text()

        self.assertIn("import Sparkle", app)
        self.assertIn("SPUStandardUpdaterController", app)
        self.assertIn("updaterController.updater", app)

        self.assertIn("import Sparkle", commands)
        self.assertIn("CommandGroup(after: .appInfo)", commands)
        self.assertIn("Check for Updates...", commands)
        self.assertIn("SPUUpdater", commands)

    def test_release_workflow_generates_and_uploads_sparkle_appcast(self):
        workflow = RELEASE_WORKFLOW.read_text()

        self.assertIn("SPARKLE_EDDSA_PRIVATE_KEY", workflow)
        self.assertIn("Generate Sparkle appcast", workflow)
        self.assertIn("scripts/generate-sparkle-appcast.sh", workflow)
        self.assertIn("appcast.xml", workflow)
        self.assertIn("gh release upload", workflow)

    def test_appcast_script_uses_secret_key_and_release_asset_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            dmg = tmp_path / "Fantastty-v9.9.9.dmg"
            dmg.write_text("fake dmg")
            appcast = tmp_path / "appcast.xml"
            captured_key = tmp_path / "captured-key"
            captured_archive = tmp_path / "captured-archive"
            fake_generate_appcast = tmp_path / "generate_appcast"
            fake_generate_appcast.write_text(
                f"""#!/bin/sh
set -eu
output=""
download_prefix=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ed-key-file)
      key_file="$2"
      if [ "$key_file" = "-" ]; then
        cat >"{captured_key}"
      fi
      shift 2
      ;;
    --download-url-prefix)
      download_prefix="$2"
      shift 2
      ;;
    -o)
      output="$2"
      shift 2
      ;;
    *)
      archive_dir="$1"
      shift
      ;;
  esac
done
archive="$(find "$archive_dir" -name '*.dmg' -type f | head -1)"
basename "$archive" >"{captured_archive}"
cat >"$output" <<EOF
<rss><channel><item><enclosure url="${{download_prefix}}$(basename "$archive")"/></item></channel></rss>
EOF
""",
            )
            fake_generate_appcast.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "DMG_NAME": dmg.name,
                    "GITHUB_REF_NAME": "v9.9.9",
                    "SPARKLE_EDDSA_PRIVATE_KEY": "secret-key",
                    "SPARKLE_GENERATE_APPCAST": str(fake_generate_appcast),
                    "SPARKLE_APPCAST_OUTPUT": str(appcast),
                    "SPARKLE_UPDATES_DIR": str(tmp_path / "updates"),
                }
            )

            subprocess.run([str(GENERATE_APPCAST_SCRIPT)], cwd=tmp_path, env=env, check=True)

            self.assertEqual(captured_key.read_text(), "secret-key")
            self.assertEqual(captured_archive.read_text().strip(), dmg.name)
            self.assertIn(
                "https://github.com/blaine/fantastty/releases/download/v9.9.9/Fantastty-v9.9.9.dmg",
                appcast.read_text(),
            )

    def test_release_docs_explain_sparkle_secret_and_feed(self):
        setup_doc = GITHUB_ACTIONS_DOC.read_text()
        readme = README.read_text()

        self.assertIn("SPARKLE_EDDSA_PRIVATE_KEY", setup_doc)
        self.assertIn("SUPublicEDKey", setup_doc)
        self.assertIn("releases/latest/download/appcast.xml", setup_doc)
        self.assertIn("Check for Updates", readme)


if __name__ == "__main__":
    unittest.main()
