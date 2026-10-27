#!/usr/bin/env python3
"""Skip scheduled engine builds only when the current source is published."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def gh(*arguments, missing_ok=False):
    result = subprocess.run(["gh", *arguments], capture_output=True, text=True, check=False)
    if result.returncode:
        if missing_ok and "HTTP 404" in result.stderr:
            return None
        raise ValueError(f"GitHub publication check failed: {result.stderr.strip()}")
    return result.stdout


def last_published_commit(repository):
    response = gh("api", f"repos/{repository}/contents/source.json?ref=rain-source", missing_ok=True)
    if response is None:
        return None
    content = json.loads(response)
    if content.get("encoding") != "base64" or not isinstance(content.get("content"), str):
        raise ValueError("The source branch did not return a readable source.json")
    source = json.loads(base64.b64decode(content["content"]))
    apps = source.get("apps", [])
    if len(apps) != 1 or apps[0].get("bundleIdentifier") != "com.minh-ton.ReynardAVKit":
        raise ValueError("The published SideStore source is not the expected Rain app")
    versions = apps[0].get("versions", [])
    if not versions:
        return None
    build = str(versions[0].get("buildVersion", ""))
    if not re.fullmatch(r"[0-9]{14}", build):
        raise ValueError("The published Rain build number is invalid")
    tag = "rain-build-" + build
    expected_download = f"https://github.com/{repository}/releases/download/{tag}/Rain.ipa"
    if versions[0].get("downloadURL") != expected_download:
        raise ValueError("The published Rain version points to an unexpected download")
    raw_manifest = gh("release", "download", tag, "--repo", repository, "--pattern", "Rain.build.json", "--output", "-")
    manifest = json.loads(raw_manifest)
    if manifest.get("buildVersion") != build or manifest.get("artifact") != "Rain.ipa" or manifest.get("bundleIdentifier") != "com.minh-ton.ReynardAVKit":
        raise ValueError("The published build manifest does not match the SideStore source")
    commit = manifest.get("sourceCommit")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("The published build manifest lacks a valid source commit")
    return commit


def decide(event, upstream_changed, current_commit, published_commit):
    if event == "workflow_dispatch":
        return {"build": "true", "reason": "A manual build was requested."}
    if upstream_changed:
        return {"build": "true", "reason": "A newer stable upstream release is available."}
    if published_commit != current_commit:
        return {"build": "true", "reason": "The current custom source has not yet been published to SideStore."}
    return {"build": "false", "reason": "The latest stable release and current Rain source are already published; the macOS build was skipped."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--event", choices=("schedule", "workflow_dispatch"), required=True)
    parser.add_argument("--upstream-changed", choices=("true", "false"), default="false")
    arguments = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository):
        parser.error("Repository must be owner/name")
    current_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    # Manual runs always build, including recovery after a broken source update.
    published_commit = None if arguments.event == "workflow_dispatch" else last_published_commit(arguments.repository)
    outputs = decide(arguments.event, arguments.upstream_changed == "true", current_commit, published_commit)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"build={outputs['build']}\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(outputs["reason"] + "\n")
    print(json.dumps(outputs))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Rain build planning stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
