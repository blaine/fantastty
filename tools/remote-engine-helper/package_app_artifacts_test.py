import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "remote-engine-helper" / "package_app_artifacts.sh"
VERIFY_SCRIPT = ROOT / "tools" / "remote-engine-helper" / "verify_app_artifacts.py"
XCODE_PROJECT = ROOT / "Fantastty.xcodeproj" / "project.pbxproj"
REMOTE_ENGINE_CLIENT = ROOT / "Fantastty" / "Models" / "RemoteEngineClient.swift"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "build-and-release.yml"
LOCAL_RELEASE_SCRIPT = ROOT / "scripts" / "build-release.sh"


class PackageAppArtifactsTests(unittest.TestCase):
    def test_packages_linux_and_darwin_arm64_helpers_into_bundle_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            output = tmp_path / "RemoteEngine"
            build_root = tmp_path / "build"
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            self.write_fake_tool(
                fake_bin / "zig",
                """#!/bin/sh
set -eu
prefix=""
target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      prefix="$2"
      shift 2
      ;;
    -Dtarget=*)
      target="${1#-Dtarget=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$prefix/lib" "$prefix/share/pkgconfig"
case "$target" in
  *macos*)
    printf 'fake lib for %s\n' "$target" >"$prefix/lib/libghostty-vt.dylib"
    ;;
  *)
    printf 'fake lib for %s\n' "$target" >"$prefix/lib/libghostty-vt.so.0.1.0"
    ;;
esac
printf 'Name: libghostty-vt\n' >"$prefix/share/pkgconfig/libghostty-vt.pc"
""",
            )
            self.write_fake_tool(
                fake_bin / "go",
                """#!/bin/sh
set -eu
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
mkdir -p "$(dirname "$out")"
printf 'fake helper for %s\n' "${GOARCH:-missing}" >"$out"
""",
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
                    "FANTASTTY_REPO_ROOT": str(ROOT),
                    "FANTASTTY_REMOTE_ENGINE_ARTIFACTS_OUTPUT": str(output),
                    "FANTASTTY_REMOTE_ENGINE_BUILD_ROOT": str(build_root),
                    "FANTASTTY_REMOTE_ENGINE_VERSION": "deadbee",
                }
            )

            subprocess.run([str(SCRIPT)], cwd=ROOT, env=env, check=True)

            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["version"], "deadbee")
            self.assertEqual(set(manifest["artifacts"]), {"linux-amd64", "linux-arm64", "darwin-arm64"})
            self.assertArtifact(output, manifest, "linux-amd64", "linux", "amd64", "lib/libghostty-vt.so.0.1.0")
            self.assertArtifact(output, manifest, "linux-arm64", "linux", "arm64", "lib/libghostty-vt.so.0.1.0")
            self.assertArtifact(output, manifest, "darwin-arm64", "darwin", "arm64", "lib/libghostty-vt.dylib")

    def test_verifies_built_app_remote_engine_resources(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app = tmp_path / "Fantastty.app"
            resources = app / "Contents" / "Resources" / "RemoteEngine"
            resources.mkdir(parents=True)

            helper = resources / "linux-amd64" / "fantastty-helper"
            library = resources / "linux-amd64" / "lib" / "libghostty-vt.so.0.1.0"
            helper.parent.mkdir()
            library.parent.mkdir(parents=True)
            helper.write_text("helper\n")
            library.write_text("library\n")
            manifest = {
                "version": "deadbee",
                "artifacts": {
                    "linux-amd64": {
                        "os": "linux",
                        "arch": "amd64",
                        "helper": "linux-amd64/fantastty-helper",
                        "helper_sha256": self.sha256(helper),
                        "library": "linux-amd64/lib/libghostty-vt.so.0.1.0",
                        "library_sha256": self.sha256(library),
                    }
                },
            }
            (resources / "manifest.json").write_text(json.dumps(manifest))

            subprocess.run([str(VERIFY_SCRIPT), str(app)], cwd=ROOT, check=True)

    def test_verifier_rejects_remote_engine_artifact_without_os(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            app = tmp_path / "Fantastty.app"
            resources = app / "Contents" / "Resources" / "RemoteEngine"
            resources.mkdir(parents=True)

            helper = resources / "linux-amd64" / "fantastty-helper"
            library = resources / "linux-amd64" / "lib" / "libghostty-vt.so.0.1.0"
            helper.parent.mkdir()
            library.parent.mkdir(parents=True)
            helper.write_text("helper\n")
            library.write_text("library\n")
            manifest = {
                "version": "deadbee",
                "artifacts": {
                    "linux-amd64": {
                        "arch": "amd64",
                        "helper": "linux-amd64/fantastty-helper",
                        "helper_sha256": self.sha256(helper),
                        "library": "linux-amd64/lib/libghostty-vt.so.0.1.0",
                        "library_sha256": self.sha256(library),
                    }
                },
            }
            (resources / "manifest.json").write_text(json.dumps(manifest))

            result = subprocess.run(
                [str(VERIFY_SCRIPT), str(app)],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing os", result.stderr)

    def test_fantastty_target_packages_remote_engine_artifacts_when_enabled(self):
        project = XCODE_PROJECT.read_text()

        self.assertIn("Package RemoteEngine Artifacts", project)
        self.assertIn("remote-engine-app-artifacts", project)
        self.assertIn("FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS", project)

        target_start = project.index("CB5692159373E500BD905E3F /* Fantastty */ = {")
        phases_start = project.index("buildPhases = (", target_start)
        phases_end = project.index(");", phases_start)
        phases = project[phases_start:phases_end]
        package_index = phases.index("Package RemoteEngine Artifacts")
        resources_index = phases.index("Resources")
        self.assertLess(package_index, resources_index)

        phase_start = project.index("D4A0C7F0B9E84C109573B4A2 /* Package RemoteEngine Artifacts */ = {")
        phase_end = project.index("};", phase_start)
        phase = project[phase_start:phase_end]
        self.assertNotIn("alwaysOutOfDate = 1", phase)

    def test_release_paths_package_and_verify_remote_engine_artifacts(self):
        workflow = RELEASE_WORKFLOW.read_text()
        self.assertIn("actions/setup-go@v5", workflow)
        self.assertIn("go-version-file: tools/remote-engine-helper/helper/go.mod", workflow)
        self.assertIn("FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS: \"1\"", workflow)
        self.assertIn("make remote-engine-verify-app-artifacts", workflow)

        local_release = LOCAL_RELEASE_SCRIPT.read_text()
        self.assertIn("FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS=1", local_release)
        self.assertIn("remote-engine-verify-app-artifacts", local_release)

    def test_release_workflow_uses_sdk26_and_preserves_xcodebuild_failure(self):
        workflow = RELEASE_WORKFLOW.read_text()

        self.assertIn("xcode-version: '26.2'", workflow)
        self.assertIn("if ! xcodebuild \\", workflow)
        self.assertIn("exit 1", workflow)
        self.assertNotIn("| grep -E '(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)' || true", workflow)

    def test_app_target_gates_sdk26_typed_quic_symbols(self):
        source = REMOTE_ENGINE_CLIENT.read_text()
        absent_sdk26_symbols = [
            "NWParametersBuilder<QUIC>",
        ]
        gated_sdk26_symbols = [
            "NetworkConnection<QUIC>",
            "QUIC.Stream<QUICStream>",
            "QUICStream",
        ]
        typed_start = source.index("@available(macOS 26.0, *)\nprivate final class RemoteEngineTypedQUICConnection")
        typed_end = source.index("\nfinal class RemoteEngineBoundedObjectRetainer", typed_start)
        typed_source = source[typed_start:typed_end]
        non_typed_source = source[:typed_start] + source[typed_end:]

        for symbol in absent_sdk26_symbols:
            symbol_pattern = rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])"
            self.assertIsNone(re.search(symbol_pattern, source))

        for symbol in gated_sdk26_symbols:
            symbol_pattern = rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])"
            self.assertIsNotNone(re.search(symbol_pattern, typed_source))
            self.assertIsNone(re.search(symbol_pattern, non_typed_source))

    def assertArtifact(self, output, manifest, label, os_name, arch, library_suffix):
        entry = manifest["artifacts"][label]
        self.assertEqual(entry["os"], os_name)
        self.assertEqual(entry["arch"], arch)
        helper = output / entry["helper"]
        library = output / entry["library"]
        self.assertEqual(entry["library"], f"{label}/{library_suffix}")
        self.assertTrue(helper.exists())
        self.assertTrue(library.exists())
        self.assertEqual(entry["helper_sha256"], self.sha256(helper))
        self.assertEqual(entry["library_sha256"], self.sha256(library))

    def write_fake_tool(self, path, contents):
        path.write_text(contents)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def sha256(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
