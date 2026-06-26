#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_path(root: Path, relative: str, field: str) -> Path:
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        fail(f"unsafe {field} path in manifest: {relative}")
    return root / path


def verify(app: Path) -> None:
    resources = app / "Contents" / "Resources" / "RemoteEngine"
    manifest_path = resources / "manifest.json"
    if not manifest_path.is_file():
        fail(f"missing remote helper manifest: {manifest_path}")

    try:
        manifest = json.loads(manifest_path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"invalid remote helper manifest JSON: {exc}")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or not artifacts:
        fail("remote helper manifest does not declare artifacts")

    for label, entry in sorted(artifacts.items()):
        if not isinstance(entry, dict):
            fail(f"remote helper artifact {label} is not an object")
        for key in ("os", "arch", "helper", "helper_sha256", "library", "library_sha256"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                fail(f"remote helper artifact {label} is missing {key}")

        helper = artifact_path(resources, entry["helper"], f"{label}.helper")
        library = artifact_path(resources, entry["library"], f"{label}.library")
        if not helper.is_file():
            fail(f"missing remote helper artifact {label}: {helper}")
        if not library.is_file():
            fail(f"missing remote helper library {label}: {library}")
        if sha256(helper) != entry["helper_sha256"]:
            fail(f"remote helper artifact checksum mismatch for {label}")
        if sha256(library) != entry["library_sha256"]:
            fail(f"remote helper library checksum mismatch for {label}")

    print(f"remote-engine-app-artifacts: ok app={app} artifacts={len(artifacts)}")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: verify_app_artifacts.py /path/to/Fantastty.app", file=sys.stderr)
        return 2
    verify(Path(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
