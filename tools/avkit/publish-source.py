#!/usr/bin/env python3
"""Publish Rain's SideStore source after verifying its immutable IPA release.

Uses gh with the workflow's automatic GITHUB_TOKEN (contents: write). The
source file is changed with GitHub's atomic Contents API and the previous blob
SHA, so a failed request or a concurrent publication cannot delete the feed.
No Apple credentials, certificates, personal tokens or pairing files are used.

API: https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote
import zipfile

SPEC = importlib.util.spec_from_file_location("rain_source", Path(__file__).with_name("source.py"))
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)
ROOT = Path(__file__).resolve().parents[2]
SOURCE_BRANCH = "rain-source"
ICON_NAME = "Rain.png"
APPROVED_ICON_SHA256 = "27577cf8182e80f50bffbaca9b6f181d42affc63ccd0bb887e37bdb5689c399e"
ICON = ROOT / "browser/Reynard/Resources/Assets.xcassets/NativeVideoAppIcon.appiconset/icon.png"


def digest(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def blob_sha(content: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(content)).encode("ascii") + b"\0" + content).hexdigest()


def run_gh(arguments: list[str], operation: str, *, payload: dict | None = None) -> subprocess.CompletedProcess:
    # Do not echo gh's stderr: authentication diagnostics can contain secrets.
    try:
        return subprocess.run(["gh", *arguments], input=json.dumps(payload) if payload is not None else None,
                              capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError(f"GitHub {operation} could not complete") from error


def api(repository: str, endpoint: str, *, method: str = "GET", payload: dict | None = None,
        allow_missing: bool = False) -> dict | None:
    arguments = ["api", "--include", "--method", method, "--hostname", "github.com",
                 "--header", "Accept: application/vnd.github+json"]
    if payload is not None:
        arguments.extend(["--input", "-"])
    arguments.append(f"repos/{repository}/{endpoint}".rstrip("/"))
    result = run_gh(arguments, "API request", payload=payload)
    response = re.match(r"HTTP/\S+\s+(\d{3})[^\r\n]*\r?\n", result.stdout)
    SOURCE.require(response is not None, "GitHub returned no HTTP status; refusing to assume a missing file")
    status = int(response[1])
    if status == 404 and allow_missing and method == "GET":
        return None
    SOURCE.require(result.returncode == 0 and status in ({200} if method == "GET" else {200, 201}),
                   f"GitHub {method} failed (HTTP {status}); source was not replaced by this request")
    parts = re.split(r"\r?\n\r?\n", result.stdout, maxsplit=1)
    SOURCE.require(len(parts) == 2, "GitHub API response is malformed")
    value = json.loads(parts[1])
    SOURCE.require(isinstance(value, dict), "GitHub API response must be an object")
    return value


def get_release(repository: str, tag: str) -> dict:
    release = api(repository, "releases/tags/" + quote(tag, safe=""))
    SOURCE.require(release.get("tag_name") == tag, "GitHub returned a different build release")
    SOURCE.require(release.get("draft") is False, "Build release must already be published")
    SOURCE.require(isinstance(release.get("assets"), list), "GitHub release assets are malformed")
    return release


def find_asset(release: dict, name: str) -> dict | None:
    assets = [asset for asset in release["assets"] if isinstance(asset, dict) and asset.get("name") == name]
    SOURCE.require(len(assets) <= 1, f"Release has duplicate {name} assets")
    return assets[0] if assets else None


def verify_asset(repository: str, tag: str, asset: dict, version: dict, temporary: Path) -> None:
    name = asset["name"]
    SOURCE.require(asset.get("state") == "uploaded", f"Release {name} is not uploaded completely")
    SOURCE.require(type(asset.get("size")) is int and asset["size"] == version["size"],
                   f"Published {name} size does not match the validated local build")
    SOURCE.require(asset.get("browser_download_url") == version["downloadURL"],
                   f"Published {name} URL differs from the immutable build URL")
    remote_digest = asset.get("digest")
    if remote_digest not in (None, ""):
        SOURCE.require(remote_digest == "sha256:" + version["sha256"],
                       f"Published {name} SHA-256 does not match the validated local build")
        return
    result = run_gh(["release", "download", tag, "--repo", "github.com/" + repository,
                     "--pattern", name, "--dir", str(temporary)], "release asset download")
    SOURCE.require(result.returncode == 0, f"GitHub {name} download failed")
    downloaded = temporary / name
    SOURCE.require(downloaded.is_file() and downloaded.stat().st_size == version["size"]
                   and digest(downloaded) == version["sha256"],
                   f"Downloaded published {name} does not match the validated local build")


def get_file(repository: str, name: str, ref: str) -> tuple[bytes, str] | None:
    entry = api(repository, f"contents/{quote(name, safe='')}?ref={quote(ref, safe='')}", allow_missing=True)
    if entry is None:
        return None
    SOURCE.require(entry.get("type") == "file" and entry.get("path") == name
                   and entry.get("encoding") == "base64" and isinstance(entry.get("content"), str),
                   f"Published {name} is not an ordinary readable file")
    try:
        data = base64.b64decode("".join(entry["content"].split()), validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError(f"Published {name} has invalid base64 contents") from error
    SOURCE.require(type(entry.get("size")) is int and entry["size"] == len(data)
                   and entry.get("sha") == blob_sha(data), f"Published {name} failed its Git blob validation")
    return data, entry["sha"]


def put_file(repository: str, name: str, content: bytes, message: str, *, previous_sha: str | None = None) -> None:
    payload = {"message": message, "content": base64.b64encode(content).decode("ascii"), "branch": SOURCE_BRANCH}
    if previous_sha is not None:
        payload["sha"] = previous_sha
    response = api(repository, "contents/" + quote(name, safe=""), method="PUT", payload=payload)
    entry = response.get("content")
    SOURCE.require(isinstance(entry, dict) and entry.get("path") == name and entry.get("sha") == blob_sha(content),
                   f"GitHub did not confirm the expected {name} content; inspect the source branch before retrying")


def step_summary(repository: str, version: dict) -> str:
    source_url = SOURCE.source_url(repository)
    sidestore_url = "sidestore://source?url=" + quote(source_url, safe="")
    workflow_url = f"https://github.com/{repository}/actions/workflows/rain-build.yml"
    return (
        f"## Rain {version['version']} ({version['buildVersion']})\n\n"
        f"[Add this source to SideStore]({sidestore_url}) · [Source JSON]({source_url}) · "
        f"[Download IPA]({version['downloadURL']})\n\n"
        "1. On your iPhone, open the SideStore source link with SideStore installed, or paste the Source JSON URL into SideStore's Sources screen.\n"
        "2. Update the existing Rain or AVKit preview using the same Apple Account and keep both app extensions. Keep the app installed to preserve its data.\n"
        f"3. For future builds, open [the GitHub build workflow]({workflow_url}) on your phone and choose **Run workflow**. After it succeeds, refresh this source in SideStore and update Rain.\n\n"
        "The app and both extensions keep their existing bundle identifiers. Ordinary Reynard stays separate. SideStore signs and refreshes the app on your phone; this workflow never signs it.\n"
    )


def publish(repository: str, tag: str, ipa: Path, manifest_path: Path, output: Path,
            *, icon: Path = ICON, notes_file: Path | None = None) -> dict:
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    notes = notes_file.read_text(encoding="utf-8") if notes_file else ""
    # Reject malformed identities, artifacts or the icon before any API call.
    initial = SOURCE.make_source(ipa, manifest, repository, tag, notes=notes)
    SOURCE.require(output.name == "source.json", "Published feed filename must be source.json")
    approved_icon = icon.read_bytes()
    SOURCE.require(hashlib.sha256(approved_icon).hexdigest() == APPROVED_ICON_SHA256,
                   "The approved icon changed; preserve its full canvas and white border")
    expected = initial["apps"][0]["versions"][0]
    repository_info = api(repository, "")
    SOURCE.require(repository_info.get("private") is False, "SideStore requires this GitHub repository to be public")

    with tempfile.TemporaryDirectory(prefix="rain-source-") as temporary:
        release = get_release(repository, tag)
        asset = find_asset(release, ipa.name)
        SOURCE.require(asset is not None, "The immutable build release has no validated IPA asset")
        verify_asset(repository, tag, asset, expected, Path(temporary))
        manifest_asset = find_asset(release, "Rain.build.json")
        SOURCE.require(manifest_asset is not None, "The immutable build release has no build manifest asset")
        verify_asset(repository, tag, manifest_asset, {
            "size": len(manifest_bytes), "sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "downloadURL": SOURCE.release_url(repository, tag, "Rain.build.json"),
        }, Path(temporary))
        publication_date = SOURCE.release_date(release.get("published_at"))

        branch = api(repository, "git/ref/heads/" + SOURCE_BRANCH, allow_missing=True)
        if branch is not None:
            SOURCE.require(branch.get("ref") == "refs/heads/" + SOURCE_BRANCH,
                           "GitHub returned a different source branch")
        # For a new branch, also validate any files inherited from its base
        # commit before creating the branch. No existing file is overwritten.
        ref = SOURCE_BRANCH if branch is not None else SOURCE.manifest_value(manifest, "sourceCommit", "source_commit")
        previous_file = get_file(repository, "source.json", ref)
        previous = json.loads(previous_file[0]) if previous_file is not None else None
        old_icon = get_file(repository, ICON_NAME, ref)
        if old_icon is not None:
            SOURCE.require(hashlib.sha256(old_icon[0]).hexdigest() == APPROVED_ICON_SHA256,
                           "Published icon differs from the approved icon; refusing to overwrite it")
        source = SOURCE.make_source(ipa, manifest, repository, tag, previous=previous,
                                    date=publication_date, notes=notes)
        candidate = (json.dumps(source, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        SOURCE.require(len(candidate) < 1_000_000, "Source exceeds the supported GitHub Contents API size")

        # Everything above is read-only. A bad build, remote hash, feed history,
        # permissions or icon therefore leaves the hosted feed untouched.
        if branch is None:
            created = api(repository, "git/refs", method="POST", payload={
                "ref": "refs/heads/" + SOURCE_BRANCH,
                "sha": SOURCE.manifest_value(manifest, "sourceCommit", "source_commit"),
            })
            SOURCE.require(created.get("ref") == "refs/heads/" + SOURCE_BRANCH,
                           "GitHub did not confirm creation of the source branch")
        if old_icon is None:
            put_file(repository, ICON_NAME, approved_icon, "Add the approved Rain source icon")
        # A single compare-and-swap write publishes the complete new JSON. The
        # API rejects a stale SHA with HTTP 409; never delete, force, or clobber.
        put_file(repository, "source.json", candidate, f"Publish Rain {expected['buildVersion']}",
                 previous_sha=previous_file[1] if previous_file is not None else None)
        output.parent.mkdir(parents=True, exist_ok=True)
        local_temporary = output.with_name(output.name + ".tmp")
        local_temporary.write_bytes(candidate)
        local_temporary.replace(output)

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as file:
            file.write(step_summary(repository, source["apps"][0]["versions"][0]) + "\n")
    print(f"Published SideStore source: {SOURCE.source_url(repository)}")
    return source


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="Public GitHub OWNER/NAME")
    parser.add_argument("--tag", required=True, help="Existing immutable rain-build-<buildVersion> release")
    parser.add_argument("--ipa", type=Path, default=ROOT / "dist/Rain.ipa")
    parser.add_argument("--manifest", type=Path, default=ROOT / "dist/Rain.build.json")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/source.json")
    parser.add_argument("--icon", type=Path, default=ICON)
    parser.add_argument("--notes-file", type=Path)
    args = parser.parse_args()
    try:
        publish(args.repository, args.tag, args.ipa, args.manifest, args.output,
                icon=args.icon, notes_file=args.notes_file)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"Cannot publish Rain source: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
