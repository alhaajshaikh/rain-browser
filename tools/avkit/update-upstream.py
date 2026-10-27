#!/usr/bin/env python3
"""Merge a published upstream release into a disposable AVKit build checkout.

Run from the custom Git checkout after configuring a Git author identity. This
only fetches and merges: the caller must validate/build before pushing commits
or publishing a release. A conflict deliberately remains available to inspect.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


UPSTREAM_REPOSITORY = "minh-ton/reynard-browser"
UPSTREAM_URL = f"https://github.com/{UPSTREAM_REPOSITORY}.git"


class UpdateError(Exception):
    """An update stopped without pushing or publishing anything."""


def command(*arguments: str) -> str:
    result = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if result.returncode:
        detail = (result.stderr.strip() or result.stdout.strip())
        raise UpdateError(f"{arguments[0]} failed: {detail}")
    return result.stdout.strip()


def validate_tag(tag: object) -> str:
    if not isinstance(tag, str) or not tag or tag.startswith("-"):
        raise UpdateError("The upstream release must have a valid tag name.")
    if any(character.isspace() or ord(character) < 32 for character in tag):
        raise UpdateError("The upstream release tag cannot contain whitespace.")
    command("git", "check-ref-format", f"refs/tags/{tag}")
    return tag


def latest_stable_tag() -> str:
    response = command("gh", "api", f"repos/{UPSTREAM_REPOSITORY}/releases/latest")
    try:
        release = json.loads(response)
    except json.JSONDecodeError as error:
        raise UpdateError("GitHub did not return a valid release response.") from error
    if not isinstance(release, dict):
        raise UpdateError("GitHub did not return a release object.")
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise UpdateError("Only published stable upstream releases can be merged.")
    if not isinstance(release.get("published_at"), str) or not release["published_at"]:
        raise UpdateError("The upstream release has not been published.")
    return validate_tag(release.get("tag_name"))


def merge_release(tag: str | None, upstream_url: str, check_only: bool = False) -> dict[str, str]:
    command("git", "rev-parse", "--show-toplevel")
    try:
        branch = command("git", "symbolic-ref", "--quiet", "--short", "HEAD")
    except UpdateError as error:
        raise UpdateError("Check out a custom feature branch before updating; HEAD is detached.") from error
    if branch in {"main", "master"}:
        raise UpdateError("Use a custom branch, such as native-avkit-video, before updating.")
    if command("git", "status", "--porcelain", "--untracked-files=normal"):
        raise UpdateError("The custom checkout must be clean before updating.")
    merge_head = Path(command("git", "rev-parse", "--git-path", "MERGE_HEAD"))
    if merge_head.exists():
        raise UpdateError("Finish or abort the existing merge before updating.")

    previous_commit = command("git", "rev-parse", "--verify", "HEAD^{commit}")
    upstream_tag = validate_tag(tag) if tag is not None else latest_stable_tag()
    # An exact source ref, without a destination, cannot move a local branch or
    # overwrite an existing local tag. No remote's main branch is consulted.
    command("git", "fetch", "--no-tags", "--", upstream_url, f"refs/tags/{upstream_tag}")
    upstream_commit = command("git", "rev-parse", "--verify", "FETCH_HEAD^{commit}")
    if check_only:
        ancestry = subprocess.run(
            ["git", "merge-base", "--is-ancestor", upstream_commit, previous_commit],
            capture_output=True, text=True, check=False,
        )
        if ancestry.returncode not in {0, 1}:
            raise UpdateError(f"Could not compare the upstream release: {ancestry.stderr.strip()}")
        return {
            "upstream_tag": upstream_tag,
            "upstream_commit": upstream_commit,
            "source_commit": previous_commit,
            "changed": "true" if ancestry.returncode == 1 else "false",
            "previous_commit": previous_commit,
        }
    merge = subprocess.run(
        ["git", "merge", "--no-ff", "--no-commit", upstream_commit],
        capture_output=True, text=True, check=False,
    )
    # Keep the fork's automation exactly as it was. GITHUB_TOKEN cannot request
    # Workflows write access, and upstream workflows do not configure Rain.
    previous_workflows = command("git", "ls-tree", "-r", "--name-only", previous_commit, "--", ".github/workflows")
    current_workflows = command("git", "ls-files", "--", ".github/workflows")
    if previous_workflows or current_workflows:
        command("git", "restore", f"--source={previous_commit}", "--staged", "--worktree", "--", ".github/workflows")
    conflicts = command("git", "diff", "--name-only", "--diff-filter=U")
    merge_in_progress = Path(command("git", "rev-parse", "--git-path", "MERGE_HEAD")).exists()
    if conflicts or (merge.returncode != 0 and not merge_in_progress):
        detail = merge.stderr.strip() or merge.stdout.strip()
        raise UpdateError(
            "Upstream could not be merged. No commits were pushed and no release was published. "
            "Inspect the disposable checkout for conflicts; the previous custom commit is preserved.\n"
            f"{detail}\nRemaining conflicts: {conflicts or 'none'}"
        )
    if merge_in_progress:
        command("git", "commit", "--no-edit")
    source_commit = command("git", "rev-parse", "--verify", "HEAD^{commit}")
    command("git", "merge-base", "--is-ancestor", previous_commit, source_commit)
    command("git", "merge-base", "--is-ancestor", upstream_commit, source_commit)
    command("git", "diff", "--exit-code", previous_commit, source_commit, "--", ".github/workflows")
    return {
        "upstream_tag": upstream_tag,
        "upstream_commit": upstream_commit,
        "source_commit": source_commit,
        "changed": "true" if source_commit != previous_commit else "false",
        "previous_commit": previous_commit,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tag",
        help="Merge this exact tag without a release API lookup (for tests or explicit recovery).",
    )
    parser.add_argument(
        "--upstream-url", default=UPSTREAM_URL,
        help="Override the official fetch URL for isolated Git fixture tests.",
    )
    parser.add_argument(
        "--check", action="store_true",
        help="Check whether the release is already included without merging or modifying tracked files.",
    )
    arguments = parser.parse_args()
    try:
        outputs = merge_release(arguments.tag, arguments.upstream_url, arguments.check)
        output_file = os.environ.get("GITHUB_OUTPUT")
        if output_file:
            with open(output_file, "a", encoding="utf-8") as stream:
                for key, value in outputs.items():
                    stream.write(f"{key}={value}\n")
        print(json.dumps(outputs, sort_keys=True))
    except (UpdateError, OSError) as error:
        print(f"AVKit upstream update stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
