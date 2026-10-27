"""Functional checks for release-only merges, using local repositories only."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/avkit/update-upstream.py"


def git(directory: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(directory), *arguments],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


class UpstreamUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="reynard-upstream-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "upstream.git"
        self.upstream = self.root / "upstream"
        self.custom = self.root / "custom"
        self.output = self.root / "github-output"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "init", "-b", "main", str(self.upstream)], check=True, capture_output=True)
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.invalid")):
            git(self.upstream, "config", key, value)
        (self.upstream / "shared.txt").write_text("base\n", encoding="utf-8")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Base")
        git(self.upstream, "tag", "0.18.0")
        git(self.upstream, "remote", "add", "origin", str(self.remote))
        git(self.upstream, "push", "origin", "main", "--tags")
        git(self.remote, "symbolic-ref", "HEAD", "refs/heads/main")
        subprocess.run(["git", "clone", str(self.remote), str(self.custom)], check=True, capture_output=True)
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.invalid")):
            git(self.custom, "config", key, value)
        git(self.custom, "switch", "-c", "native-avkit-video")
        (self.custom / "avkit.txt").write_text("keep custom video changes\n", encoding="utf-8")
        git(self.custom, "add", ".")
        git(self.custom, "commit", "-m", "Custom AVKit changes")
        self.previous_commit = git(self.custom, "rev-parse", "HEAD")
        (self.upstream / "released.txt").write_text("stable release\n", encoding="utf-8")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Stable release")
        self.upstream_commit = git(self.upstream, "rev-parse", "HEAD")
        git(self.upstream, "tag", "-a", "0.19.0", "-m", "Stable annotated release tag")
        (self.upstream / "unreleased.txt").write_text("not released\n", encoding="utf-8")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Unreleased main work")
        git(self.upstream, "push", "origin", "main", "--tags")
        self.remote_head = git(self.remote, "rev-parse", "main")

    def run_update(self, *arguments: str, api: bool = False) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["GITHUB_OUTPUT"] = str(self.output)
        environment["PATH"] = str(self.bin) + os.pathsep + environment["PATH"]
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--upstream-url", str(self.remote),
             *([] if api else ["--tag", "0.19.0"]), *arguments],
            cwd=self.custom, env=environment, capture_output=True, text=True,
        )

    def fake_release(self, **overrides: object) -> None:
        release = {
            "tag_name": "0.19.0", "draft": False, "prerelease": False,
            "published_at": "2026-10-26T15:47:36Z",
        }
        release.update(overrides)
        executable = self.bin / "gh"
        executable.write_text(
            f"#!{sys.executable}\nimport sys\n"
            "assert sys.argv[1:] == ['api', 'repos/minh-ton/reynard-browser/releases/latest']\n"
            f"print({json.dumps(json.dumps(release))})\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)

    def assert_unchanged(self) -> None:
        self.assertEqual(git(self.custom, "rev-parse", "HEAD"), self.previous_commit)
        self.assertEqual(git(self.remote, "rev-parse", "main"), self.remote_head)
        self.assertFalse(self.output.exists())

    def test_exact_stable_tag_preserves_custom_commit_and_excludes_unreleased_main(self) -> None:
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = json.loads(result.stdout)
        source_commit = git(self.custom, "rev-parse", "HEAD")
        self.assertEqual(outputs, {
            "upstream_tag": "0.19.0", "upstream_commit": self.upstream_commit,
            "source_commit": source_commit, "changed": "true",
            "previous_commit": self.previous_commit,
        })
        self.assertEqual(
            git(self.custom, "show", "-s", "--format=%P", "HEAD").split(),
            [self.previous_commit, self.upstream_commit],
        )
        self.assertEqual((self.custom / "avkit.txt").read_text(), "keep custom video changes\n")
        self.assertTrue((self.custom / "released.txt").exists())
        self.assertFalse((self.custom / "unreleased.txt").exists())
        self.assertEqual(git(self.custom, "status", "--porcelain"), "")
        self.assertEqual(git(self.remote, "rev-parse", "main"), self.remote_head)
        output_lines = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        self.assertEqual(output_lines, outputs)

    def test_repeat_merge_is_no_op(self) -> None:
        self.assertEqual(self.run_update().returncode, 0)
        merged_commit = git(self.custom, "rev-parse", "HEAD")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = json.loads(result.stdout)
        self.assertEqual(outputs["changed"], "false")
        self.assertEqual(outputs["previous_commit"], merged_commit)
        self.assertEqual(outputs["source_commit"], merged_commit)

    def test_check_reports_new_release_without_merging_or_touching_files(self) -> None:
        before_status = git(self.custom, "status", "--porcelain")
        result = self.run_update("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = json.loads(result.stdout)
        self.assertEqual(outputs["changed"], "true")
        self.assertEqual(outputs["upstream_commit"], self.upstream_commit)
        self.assertEqual(outputs["source_commit"], self.previous_commit)
        self.assertEqual(git(self.custom, "rev-parse", "HEAD"), self.previous_commit)
        self.assertEqual(git(self.custom, "status", "--porcelain"), before_status)
        self.assertFalse((self.custom / "released.txt").exists())
        self.assertEqual(git(self.remote, "rev-parse", "main"), self.remote_head)

    def test_check_skips_release_already_in_custom_history(self) -> None:
        self.assertEqual(self.run_update().returncode, 0)
        merged_commit = git(self.custom, "rev-parse", "HEAD")
        result = self.run_update("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["changed"], "false")
        self.assertEqual(git(self.custom, "rev-parse", "HEAD"), merged_commit)
        self.assertEqual(git(self.custom, "status", "--porcelain"), "")

    def test_default_queries_latest_published_stable_release(self) -> None:
        self.fake_release()
        result = self.run_update(api=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["upstream_commit"], self.upstream_commit)

    def test_draft_prerelease_and_unpublished_responses_stop_before_fetch(self) -> None:
        for override in ({"draft": True}, {"prerelease": True}, {"published_at": None}):
            with self.subTest(override=override):
                self.fake_release(**override)
                result = self.run_update(api=True)
                self.assertNotEqual(result.returncode, 0)
                self.assert_unchanged()
                self.assertFalse((self.custom / ".git/FETCH_HEAD").exists())

    def test_invalid_tag_cannot_inject_ref_options_or_output_lines(self) -> None:
        for tag in ("--upload-pack=bad", "0.19.0\nchanged=true", "../main", "bad tag", "x^{commit}", ""):
            with self.subTest(tag=tag):
                result = self.run_update(f"--tag={tag}")
                self.assertNotEqual(result.returncode, 0)
                self.assert_unchanged()
                self.assertFalse((self.custom / ".git/FETCH_HEAD").exists())

    def test_missing_remote_tag_leaves_checkout_and_remote_unchanged(self) -> None:
        result = self.run_update("--tag", "9.99.0")
        self.assertNotEqual(result.returncode, 0)
        self.assert_unchanged()
        self.assertEqual(git(self.custom, "status", "--porcelain"), "")

    def test_main_master_and_detached_head_are_rejected_before_fetch(self) -> None:
        git(self.custom, "branch", "master")
        for branch in ("main", "master", "native-avkit-video"):
            with self.subTest(branch=branch):
                git(self.custom, "switch", branch)
                if branch == "native-avkit-video":
                    git(self.custom, "checkout", "--detach")
                starting_head = git(self.custom, "rev-parse", "HEAD")
                result = self.run_update()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(git(self.custom, "rev-parse", "HEAD"), starting_head)
                self.assertFalse(self.output.exists())
                self.assertFalse((self.custom / ".git/FETCH_HEAD").exists())

    def test_tracked_and_untracked_changes_are_preserved_and_rejected(self) -> None:
        for name in ("shared.txt", "untracked.txt"):
            with self.subTest(name=name):
                path = self.custom / name
                path.write_text("user work\n", encoding="utf-8")
                result = self.run_update()
                self.assertNotEqual(result.returncode, 0)
                self.assert_unchanged()
                self.assertEqual(path.read_text(), "user work\n")
                self.assertFalse((self.custom / ".git/FETCH_HEAD").exists())
                if name == "shared.txt":
                    path.write_text("base\n", encoding="utf-8")
                else:
                    path.unlink()

    def test_conflict_keeps_original_head_and_both_versions_without_outputs(self) -> None:
        (self.custom / "shared.txt").write_text("custom player\n", encoding="utf-8")
        git(self.custom, "add", ".")
        git(self.custom, "commit", "-m", "Custom conflicting edit")
        self.previous_commit = git(self.custom, "rev-parse", "HEAD")
        (self.upstream / "shared.txt").write_text("upstream player\n", encoding="utf-8")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Upstream conflicting edit")
        conflict_commit = git(self.upstream, "rev-parse", "HEAD")
        git(self.upstream, "tag", "0.20.0")
        git(self.upstream, "push", "origin", "main", "--tags")
        self.remote_head = git(self.remote, "rev-parse", "main")
        result = self.run_update("--tag", "0.20.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No commits were pushed", result.stderr)
        self.assert_unchanged()
        self.assertEqual(git(self.custom, "rev-parse", "MERGE_HEAD"), conflict_commit)
        conflict = (self.custom / "shared.txt").read_text()
        self.assertIn("custom player", conflict)
        self.assertIn("upstream player", conflict)
        self.assertEqual((self.custom / "avkit.txt").read_text(), "keep custom video changes\n")

    def test_upstream_workflow_additions_modifications_and_deletions_keep_custom_tree(self) -> None:
        workflows = self.custom / ".github/workflows"
        workflows.mkdir(parents=True)
        (workflows / "rain-build.yml").write_text("name: Rain\n")
        (workflows / "modified.yml").write_text("name: custom workflow\n")
        (workflows / "deleted.yml").write_text("name: preserve this workflow\n")
        git(self.custom, "add", ".")
        git(self.custom, "commit", "-m", "Fork automation")
        before = git(self.custom, "rev-parse", "HEAD")
        upstream_workflows = self.upstream / ".github/workflows"
        upstream_workflows.mkdir(parents=True)
        (upstream_workflows / "modified.yml").write_text("name: upstream workflow\n")
        (upstream_workflows / "added.yml").write_text("name: new upstream workflow\n")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Upstream automation changes")
        git(self.upstream, "tag", "0.20.0")
        git(self.upstream, "push", "origin", "main", "--tags")
        result = self.run_update("--tag", "0.20.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.custom, "diff", before, "HEAD", "--", ".github/workflows"), "")
        self.assertEqual((workflows / "modified.yml").read_text(), "name: custom workflow\n")
        self.assertTrue((workflows / "deleted.yml").exists())
        self.assertFalse((workflows / "added.yml").exists())
        self.assertEqual(git(self.custom, "status", "--porcelain"), "")

    def test_workflow_content_conflict_is_resolved_with_premerge_custom_content(self) -> None:
        upstream_workflows = self.upstream / ".github/workflows"
        upstream_workflows.mkdir(parents=True)
        (upstream_workflows / "rain-build.yml").write_text("name: upstream\n")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Upstream workflow")
        git(self.upstream, "tag", "0.20.0")
        git(self.upstream, "push", "origin", "main", "--tags")
        workflows = self.custom / ".github/workflows"
        workflows.mkdir(parents=True)
        (workflows / "rain-build.yml").write_text("name: custom Rain\n")
        git(self.custom, "add", ".")
        git(self.custom, "commit", "-m", "Own Rain workflow")
        before = git(self.custom, "rev-parse", "HEAD")
        result = self.run_update("--tag", "0.20.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((workflows / "rain-build.yml").read_text(), "name: custom Rain\n")
        self.assertEqual(git(self.custom, "diff", before, "HEAD", "--", ".github/workflows"), "")
        self.assertEqual(git(self.custom, "status", "--porcelain"), "")

    def test_upstream_workflow_deletion_does_not_remove_the_forks_existing_workflow(self) -> None:
        path = self.upstream / ".github/workflows/shared.yml"
        path.parent.mkdir(parents=True)
        path.write_text("name: keep existing automation\n")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Shared automation baseline")
        git(self.upstream, "push", "origin", "main")
        git(self.custom, "fetch", "origin", "main")
        git(self.custom, "merge", "--no-ff", "--no-edit", "FETCH_HEAD")
        before = git(self.custom, "rev-parse", "HEAD")
        path.unlink()
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-m", "Remove upstream automation")
        git(self.upstream, "tag", "0.20.0")
        git(self.upstream, "push", "origin", "main", "--tags")
        result = self.run_update("--tag", "0.20.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.custom / ".github/workflows/shared.yml").read_text(), "name: keep existing automation\n")
        self.assertEqual(git(self.custom, "diff", before, "HEAD", "--", ".github/workflows"), "")

    def test_nonworkflow_conflict_still_stops_when_workflows_also_conflict(self) -> None:
        for repo, content in ((self.custom, "custom"), (self.upstream, "upstream")):
            workflows = repo / ".github/workflows"
            workflows.mkdir(parents=True)
            (workflows / "rain-build.yml").write_text(f"name: {content}\n")
            (repo / "shared.txt").write_text(content + "\n")
            git(repo, "add", ".")
            git(repo, "commit", "-m", content)
        self.previous_commit = git(self.custom, "rev-parse", "HEAD")
        git(self.upstream, "tag", "0.20.0")
        git(self.upstream, "push", "origin", "main", "--tags")
        self.remote_head = git(self.remote, "rev-parse", "main")
        result = self.run_update("--tag", "0.20.0")
        self.assertNotEqual(result.returncode, 0)
        self.assert_unchanged()
        self.assertEqual((self.custom / ".github/workflows/rain-build.yml").read_text(), "name: custom\n")
        self.assertEqual(git(self.custom, "diff", "--name-only", "--diff-filter=U"), "shared.txt")


if __name__ == "__main__":
    unittest.main()
