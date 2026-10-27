"""Run the publication CLI against a fake gh that implements atomic Contents PUT.

No network or GitHub authentication is used. Fixtures keep the real approved
icon and normal project entitlements when these tests run in an applied repo.
"""

import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("rain_publication", ROOT / "tools/avkit/publish-source.py")
PUBLISH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLISH)
SOURCE = PUBLISH.SOURCE
REPOSITORY = "example/reynard-browser"
BUILD = "20261026183000"
TAG = "rain-build-" + BUILD
DATE = "2026-10-26T18:30:00Z"

FAKE_GH = r'''
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
from urllib.parse import unquote

state_path = Path(os.environ["RAIN_TEST_GH_STATE"])
state = json.loads(state_path.read_text())
arguments = sys.argv[1:]
state.setdefault("commands", []).append(arguments)

def save():
    state_path.write_text(json.dumps(state))

def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()

def respond(status, body):
    print(f"HTTP/2.0 {status} Test")
    print("Content-Type: application/json\n")
    print(json.dumps(body))
    save()
    if status not in (200, 201):
        print("Synthetic API failure: SECRET_MUST_NOT_BE_PRINTED", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(0)

if arguments[0] == "api":
    method = arguments[arguments.index("--method") + 1]
    endpoint = arguments[-1]
    payload = json.load(sys.stdin) if "--input" in arguments else None
    response = state.get("apiOverrides", {}).get(method + " " + endpoint)
    if response:
        respond(response["status"], response.get("body", {}))
    prefix = "repos/" + state["repository"]
    if not endpoint.startswith(prefix):
        respond(404, {})
    path = endpoint[len(prefix):].lstrip("/")
    if method == "GET" and path == "":
        respond(200, {"private": state.get("private", False)})
    if method == "GET" and path.startswith("releases/tags/"):
        tag = unquote(path.rsplit("/", 1)[1])
        release = state["releases"].get(tag)
        respond(200 if release else 404, release or {})
    if method == "GET" and path == "git/ref/heads/rain-source":
        respond(200 if state.get("branchExists") else 404,
                {"ref": "refs/heads/rain-source", "object": {"sha": "b" * 40}})
    if method == "POST" and path == "git/refs":
        if state.get("branchExists") or payload != {"ref": "refs/heads/rain-source", "sha": "a" * 40}:
            respond(422, {})
        state["branchExists"] = True
        state["files"] = dict(state.get("baseFiles", {}))
        state.setdefault("mutations", []).append({"kind": "create_ref"})
        respond(201, {"ref": "refs/heads/rain-source", "object": {"sha": payload["sha"]}})
    if path.startswith("contents/"):
        name = unquote(path[len("contents/"):].split("?", 1)[0])
        if method == "GET":
            ref = unquote(path.split("?ref=", 1)[1])
            files = state.get("files", {}) if ref == "rain-source" else state.get("baseFiles", {})
            encoded = files.get(name)
            if encoded is None:
                respond(404, {})
            data = base64.b64decode(encoded)
            respond(200, {"type": "file", "name": name, "path": name, "encoding": "base64",
                          "size": len(data), "sha": blob_sha(data), "content": encoded + "\n"})
        if method == "PUT":
            state.setdefault("putPayloads", []).append({"name": name, **payload})
            if state.get("failPut") == name:
                respond(500, {})
            if state.get("concurrentSource") and name == "source.json":
                state["files"][name] = state.pop("concurrentSource")
            current = state.get("files", {}).get(name)
            if payload.get("branch") != "rain-source" or not state.get("branchExists"):
                respond(422, {})
            if current is not None and payload.get("sha") != blob_sha(base64.b64decode(current)):
                respond(409, {})
            if current is None and "sha" in payload:
                respond(409, {})
            data = base64.b64decode(payload["content"], validate=True)
            state.setdefault("snapshots", []).append(dict(state.get("files", {})))
            state.setdefault("files", {})[name] = payload["content"]
            state.setdefault("mutations", []).append({"kind": "put", "name": name,
                                                      "previousSHA": payload.get("sha")})
            respond(200 if current is not None else 201,
                    {"content": {"path": name, "sha": blob_sha(data)}, "commit": {"sha": "c" * 40}})
    respond(404, {})
elif arguments[:2] == ["release", "download"]:
    tag = arguments[2]
    name = arguments[arguments.index("--pattern") + 1]
    target = Path(arguments[arguments.index("--dir") + 1]) / name
    source = state.get("downloads", {}).get(tag + "/" + name)
    save()
    if not source:
        raise SystemExit(1)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
else:
    save()
    raise SystemExit("Unexpected fake gh command; publication must not upload/delete release assets")
'''


class PublicationChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name)
        self.ipa = self.path / "Rain.ipa"
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for path, identifier in {SOURCE.APP_PATH: SOURCE.BUNDLE_ID, **SOURCE.EXTENSIONS}.items():
                info = {"CFBundleIdentifier": identifier, "CFBundleVersion": BUILD,
                        "CFBundleShortVersionString": "0.19.0", "MinimumOSVersion": "15.0",
                        "CFBundleExecutable": "Executable"}
                if path == SOURCE.APP_PATH:
                    info.update({"CFBundleDisplayName": "Rain", "ReynardURLScheme": "reynard-avkit",
                                 "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "NativeVideoAppIcon"}}})
                archive.writestr(path + "/Info.plist", plistlib.dumps(info))
                archive.writestr(path + "/Executable", b"fixture binary")
        self.manifest = {
            "artifact": self.ipa.name, "version": "0.19.0", "buildVersion": BUILD,
            "bundleIdentifier": SOURCE.BUNDLE_ID, "minimumOSVersion": "15.0",
            "sourceCommit": "a" * 40, "size": self.ipa.stat().st_size,
            "sha256": hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
        }
        self.manifest_path = self.path / "Rain.build.json"
        self.manifest_path.write_text(json.dumps(self.manifest))
        self.output = self.path / "output/source.json"
        self.summary = self.path / "summary.md"
        self.asset = {"name": self.ipa.name, "state": "uploaded", "size": self.manifest["size"],
                      "digest": "sha256:" + self.manifest["sha256"],
                      "browser_download_url": SOURCE.release_url(REPOSITORY, TAG, self.ipa.name)}
        self.manifest_asset = {"name": "Rain.build.json", "state": "uploaded", "size": self.manifest_path.stat().st_size,
                               "digest": "sha256:" + hashlib.sha256(self.manifest_path.read_bytes()).hexdigest(),
                               "browser_download_url": SOURCE.release_url(REPOSITORY, TAG, "Rain.build.json")}
        self.state = {"repository": REPOSITORY, "releases": {TAG: {
            "tag_name": TAG, "draft": False, "published_at": DATE, "assets": [self.asset, self.manifest_asset]}},
            "downloads": {}, "files": {}, "branchExists": False}
        self.state_path = self.path / "gh-state.json"
        bin_directory = self.path / "bin"
        bin_directory.mkdir()
        executable = bin_directory / "gh"
        executable.write_text("#!" + sys.executable + "\n" + FAKE_GH)
        executable.chmod(0o755)
        self.environment = {**os.environ, "PATH": str(bin_directory) + os.pathsep + os.environ.get("PATH", ""),
                            "RAIN_TEST_GH_STATE": str(self.state_path), "GITHUB_STEP_SUMMARY": str(self.summary),
                            "PYTHONDONTWRITEBYTECODE": "1"}

    def run_publisher(self, extra=()):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run([sys.executable, "-B", str(ROOT / "tools/avkit/publish-source.py"),
                                 "--repository", REPOSITORY, "--tag", TAG,
                                 "--ipa", str(self.ipa), "--manifest", str(self.manifest_path),
                                 "--output", str(self.output), *extra], env=self.environment,
                                capture_output=True, text=True)
        self.state = json.loads(self.state_path.read_text())
        return result

    def remote_file(self, name):
        encoded = self.state["files"].get(name)
        return base64.b64decode(encoded) if encoded is not None else None

    def set_remote_file(self, name, data):
        self.state["files"][name] = base64.b64encode(data).decode()

    def add_previous(self):
        previous = SOURCE.make_source(self.ipa, self.manifest, REPOSITORY, TAG, date=DATE)
        version = previous["apps"][0]["versions"][0]
        version["buildVersion"] = str(int(BUILD) - 1)
        version["downloadURL"] = SOURCE.release_url(REPOSITORY, "rain-build-" + version["buildVersion"], self.ipa.name)
        self.state["branchExists"] = True
        self.set_remote_file("source.json", json.dumps(previous).encode())
        self.set_remote_file("Rain.png", PUBLISH.ICON.read_bytes())
        return previous

    def assert_feed_untouched(self, previous):
        self.assertEqual(self.remote_file("source.json"), previous)
        self.assertFalse(self.state.get("mutations"))

    def test_first_publication_creates_branch_and_exact_icon_then_feed_last(self):
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state["mutations"], [{"kind": "create_ref"},
            {"kind": "put", "name": "Rain.png", "previousSHA": None},
            {"kind": "put", "name": "source.json", "previousSHA": None}])
        self.assertEqual(self.remote_file("Rain.png"), PUBLISH.ICON.read_bytes())
        self.assertEqual(self.remote_file("source.json"), self.output.read_bytes())
        feed = json.loads(self.output.read_text())
        self.assertEqual(feed["apps"][0]["versions"][0]["date"], DATE)
        self.assertEqual(feed["apps"][0]["versions"][0]["sha256"], self.manifest["sha256"])
        self.assertFalse(any(command[0] != "api" for command in self.state["commands"]))

    def test_update_is_one_atomic_compare_and_swap_and_keeps_history(self):
        self.add_previous()
        previous = self.remote_file("source.json")
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        versions = json.loads(self.output.read_text())["apps"][0]["versions"]
        self.assertEqual([entry["buildVersion"] for entry in versions], [BUILD, str(int(BUILD) - 1)])
        self.assertEqual(self.state["mutations"], [{"kind": "put", "name": "source.json",
                                                  "previousSHA": PUBLISH.blob_sha(previous)}])
        self.assertEqual(len(self.state["snapshots"]), 1)
        self.assertEqual(base64.b64decode(self.state["snapshots"][0]["source.json"]), previous)
        self.assertEqual(self.state["putPayloads"][0]["sha"], PUBLISH.blob_sha(previous))
        self.assertFalse(any("--clobber" in command or "DELETE" in command for command in self.state["commands"]))

    def test_failed_atomic_put_preserves_previous_bytes_and_local_output(self):
        self.add_previous()
        previous = self.remote_file("source.json")
        self.output.parent.mkdir()
        self.output.write_bytes(b"previous local output")
        self.state["failPut"] = "source.json"
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assert_feed_untouched(previous)
        self.assertEqual(self.output.read_bytes(), b"previous local output")
        self.assertNotIn("SECRET_MUST_NOT_BE_PRINTED", result.stderr)

    def test_concurrent_newer_source_cannot_be_overwritten_with_stale_sha(self):
        previous = self.add_previous()
        version = previous["apps"][0]["versions"][0]
        version["buildVersion"] = str(int(BUILD) + 1)
        version["downloadURL"] = SOURCE.release_url(REPOSITORY, "rain-build-" + version["buildVersion"], self.ipa.name)
        concurrent = json.dumps(previous).encode()
        self.state["concurrentSource"] = base64.b64encode(concurrent).decode()
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 409", result.stderr)
        self.assert_feed_untouched(concurrent)
        self.assertFalse(self.output.exists())

    def test_retry_retains_one_entry_and_same_release_date(self):
        self.add_previous()
        feed = SOURCE.make_source(self.ipa, self.manifest, REPOSITORY, TAG, date=DATE)
        self.set_remote_file("source.json", json.dumps(feed).encode())
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        versions = json.loads(self.output.read_text())["apps"][0]["versions"]
        self.assertEqual([entry["buildVersion"] for entry in versions], [BUILD])
        self.assertEqual(versions[0]["date"], DATE)

    def test_remote_digest_size_url_and_incomplete_upload_fail_before_writing(self):
        self.add_previous()
        previous = self.remote_file("source.json")
        original = copy.deepcopy(self.asset)
        for field, value in [("digest", "sha256:" + "0" * 64), ("size", 1),
                             ("browser_download_url", "https://example.com/app.ipa"), ("state", "starter")]:
            with self.subTest(field=field):
                self.state["releases"][TAG]["assets"] = [{**original, field: value}]
                result = self.run_publisher()
                self.assertNotEqual(result.returncode, 0)
                self.assert_feed_untouched(previous)

    def test_missing_digest_downloads_and_checks_published_ipa(self):
        del self.asset["digest"]
        self.state["downloads"][TAG + "/Rain.ipa"] = str(self.ipa)
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(command[:2] == ["release", "download"] for command in self.state["commands"]))

    def test_remote_manifest_must_match_before_feed_update(self):
        self.add_previous()
        previous = self.remote_file("source.json")
        self.manifest_asset["digest"] = "sha256:" + "0" * 64
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rain.build.json SHA-256", result.stderr)
        self.assert_feed_untouched(previous)

    def test_manifest_digest_fallback_download_is_verified(self):
        self.manifest_asset["digest"] = None
        self.state["downloads"][TAG + "/Rain.build.json"] = str(self.manifest_path)
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        downloads = [command for command in self.state["commands"] if command[:2] == ["release", "download"]]
        self.assertEqual(downloads[0][downloads[0].index("--pattern") + 1], "Rain.build.json")

    def test_corrupt_download_preserves_previous_feed(self):
        self.add_previous()
        previous = self.remote_file("source.json")
        self.asset["digest"] = None
        corrupt = self.path / "corrupt.ipa"
        corrupt.write_bytes(b"different published IPA")
        self.state["downloads"][TAG + "/Rain.ipa"] = str(corrupt)
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assert_feed_untouched(previous)

    def test_only_404_is_treated_as_a_missing_branch_or_file(self):
        for endpoint in ["git/ref/heads/rain-source", "contents/source.json?ref=" + "a" * 40]:
            for status in [401, 403, 429, 500]:
                with self.subTest(endpoint=endpoint, status=status):
                    self.state["apiOverrides"] = {f"GET repos/{REPOSITORY}/{endpoint}": {"status": status}}
                    result = self.run_publisher()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"HTTP {status}", result.stderr)
                    self.assertNotIn("SECRET_MUST_NOT_BE_PRINTED", result.stderr)
                    self.assertFalse(self.state.get("mutations"))

    def test_missing_build_or_asset_and_private_repository_make_no_writes(self):
        release = self.state["releases"].pop(TAG)
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.get("mutations"))
        self.state["releases"][TAG] = {**release, "assets": []}
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.get("mutations"))
        self.state["releases"][TAG] = release
        self.state["private"] = True
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public", result.stderr)
        self.assertFalse(self.state.get("mutations"))

    def test_invalid_local_hash_or_changed_icon_makes_no_github_calls(self):
        self.manifest_path.write_text(json.dumps({**self.manifest, "sha256": "0" * 64}))
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.get("commands"))
        self.manifest_path.write_text(json.dumps(self.manifest))
        icon = self.path / "changed.png"
        icon.write_bytes(b"cropped or changed icon")
        result = self.run_publisher(["--icon", str(icon)])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.get("commands"))

    def test_bad_feed_rollback_and_changed_existing_icon_are_rejected_before_writes(self):
        original = self.add_previous()
        for mutation in [lambda data: data.update(identifier="other-source"),
                         lambda data: data["apps"][0]["versions"][0].update(
                             buildVersion=str(int(BUILD) + 1), downloadURL=SOURCE.release_url(
                                 REPOSITORY, "rain-build-" + str(int(BUILD) + 1), self.ipa.name))]:
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(original)
                mutation(changed)
                self.set_remote_file("source.json", json.dumps(changed).encode())
                previous = self.remote_file("source.json")
                result = self.run_publisher()
                self.assertNotEqual(result.returncode, 0)
                self.assert_feed_untouched(previous)
        self.set_remote_file("source.json", json.dumps(original).encode())
        self.set_remote_file("Rain.png", b"another icon")
        previous = self.remote_file("source.json")
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Published icon differs", result.stderr)
        self.assert_feed_untouched(previous)

    def test_failed_first_icon_creation_never_attempts_feed_put(self):
        self.state["failPut"] = "Rain.png"
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state["mutations"], [{"kind": "create_ref"}])
        self.assertIsNone(self.remote_file("source.json"))
        self.assertEqual([entry["name"] for entry in self.state["putPayloads"]], ["Rain.png"])

    def test_summary_has_encoded_stable_source_and_phone_update_instructions(self):
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.summary.read_text()
        encoded = summary.split("sidestore://source?url=", 1)[1].split(")", 1)[0]
        self.assertTrue(encoded.startswith("https%3A%2F%2F"))
        self.assertEqual(unquote(encoded), f"https://raw.githubusercontent.com/{REPOSITORY}/rain-source/source.json")
        for text in ["same Apple Account", "keep both app extensions", "Run workflow", "Keep the app installed",
                     "/actions/workflows/rain-build.yml"]:
            self.assertIn(text, summary)


if __name__ == "__main__":
    unittest.main()
