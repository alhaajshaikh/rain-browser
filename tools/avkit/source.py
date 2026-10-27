#!/usr/bin/env python3
"""Generate the Rain preview's SideStore / AltStore Classic source.

The IPA is signed on the phone, so no Apple credentials or signing material are
needed here. Permissions disclose the normal app/extension entitlement files
and the privacy keys in the packaged IPA, never the private JIT entitlements.

Schema: https://faq.altstore.io/developers/make-a-source
Updates: https://faq.altstore.io/developers/updating-apps
SideStore: https://docs.sidestore.io/docs/advanced/app-sources
SHA-256: https://github.com/altstoreio/AltStore/blob/develop/AltStoreCore/Model/AppVersion.swift
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import quote
import zipfile

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "com.minh-ton.ReynardAVKit"
SOURCE_ID = BUNDLE_ID + ".source"
BASELINE_BUILD = 2026102607
MAX_VERSIONS = 20
APP_PATH = "Payload/Reynard.app"
EXTENSIONS = {
    APP_PATH + "/PlugIns/OpenIn.appex": BUNDLE_ID + ".OpenIn",
    APP_PATH + "/PlugIns/Reynard Helper.appex": BUNDLE_ID + ".Helper",
}
ENTITLEMENT_FILES = (
    ROOT / "browser/Reynard/Entitlements/Reynard.entitlements",
    ROOT / "browser/Helper/Entitlements/Reynard-Helper.entitlements",
)
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def manifest_value(manifest: dict, *names: str):
    """Accept old local manifests and the cloud manifest, rejecting ambiguity."""
    values = [manifest[name] for name in names if name in manifest]
    require(bool(values), f"Manifest is missing {names[0]}")
    require(all(value == values[0] for value in values), f"Conflicting manifest fields: {', '.join(names)}")
    return values[0]


def version_number(value, name: str) -> str:
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value) is not None,
            f"{name} must be a numeric dotted version string")
    return value


def build_number(value) -> int:
    require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*", value) is not None,
            "buildVersion must be a positive decimal string")
    return int(value)


def release_date(value: str) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(parsed.tzinfo is not None, "Release date must include a timezone")
    except (TypeError, AttributeError, ValueError) as error:
        raise ValueError("Release date must be an ISO 8601 timestamp with a timezone") from error
    return parsed.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def release_url(repository: str, tag: str, asset: str) -> str:
    return f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}/{quote(asset, safe='')}"


def source_url(repository: str, filename: str = "source.json") -> str:
    return f"https://raw.githubusercontent.com/{repository}/rain-source/{quote(filename, safe='')}"


def read_ipa(ipa: Path, manifest: dict) -> tuple[dict, dict]:
    actual_size = ipa.stat().st_size
    with ipa.open("rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    require(manifest_value(manifest, "sha256") == digest, "IPA SHA-256 differs from manifest")
    declared_size = manifest_value(manifest, "size", "bytes")
    require(type(declared_size) is int and declared_size == actual_size, "IPA size differs from manifest")
    require(manifest_value(manifest, "bundleIdentifier", "bundle_identifier") == BUNDLE_ID,
            "Manifest is not the Rain preview")
    version = version_number(manifest_value(manifest, "version"), "version")
    build = manifest_value(manifest, "buildVersion", "bundle_build")
    require(build_number(build) > BASELINE_BUILD, "Cloud build must be newer than installed preview build 2026102607")
    minimum_os = version_number(manifest_value(manifest, "minimumOSVersion", "minimum_iOS"), "minimumOSVersion")
    commit = manifest_value(manifest, "sourceCommit", "source_commit")
    require(isinstance(commit, str) and re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", commit) is not None,
            "Manifest sourceCommit must be a complete Git commit SHA")
    artifact = manifest.get("artifact")
    require(artifact is None or artifact == ipa.name, "IPA filename differs from manifest artifact")

    privacy = {}
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "IPA contains duplicate archive entries")
        main_plists = {name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)}
        require(main_plists == {APP_PATH + "/Info.plist"}, "IPA must contain exactly one Reynard app")
        extension_paths = {name.rsplit("/", 1)[0] for name in names
                           if re.fullmatch(APP_PATH + r"/PlugIns/[^/]+\.appex/Info\.plist", name)}
        require(extension_paths == set(EXTENSIONS), "IPA must keep exactly the OpenIn and Reynard Helper extensions")
        infos = {}
        for path, identifier in {APP_PATH: BUNDLE_ID, **EXTENSIONS}.items():
            info = plistlib.loads(archive.read(path + "/Info.plist"))
            require(isinstance(info, dict), "IPA Info.plist must be a dictionary")
            require(info.get("CFBundleIdentifier") == identifier, f"Incorrect bundle identifier for {path}")
            require(info.get("CFBundleShortVersionString") == version, f"Version mismatch for {path}")
            require(info.get("CFBundleVersion") == build, f"Build mismatch for {path}")
            require(info.get("MinimumOSVersion") == minimum_os, f"Minimum iOS mismatch for {path}")
            executable = info.get("CFBundleExecutable")
            require(isinstance(executable, str) and executable not in {"", ".", ".."} and "/" not in executable,
                    f"Invalid executable for {path}")
            require(path + "/" + executable in names, f"Missing executable for {path}")
            for key, value in info.items():
                if re.fullmatch(r"NS.+UsageDescription.*", key):
                    require(isinstance(value, str) and bool(value.strip()), f"Empty privacy description: {key}")
                    # One source description must cover duplicate permissions across extensions.
                    privacy.setdefault(key, value)
            infos[path] = info
        app = infos[APP_PATH]
        require(app.get("CFBundleDisplayName") == "Rain", "Preview display name was changed")
        require(app.get("ReynardURLScheme") == "reynard-avkit", "Preview URL scheme was changed")
        require(app.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "NativeVideoAppIcon",
                "Preview must keep its custom NativeVideoAppIcon")

    entitlements = set()
    for path in ENTITLEMENT_FILES:
        declared = plistlib.loads(path.read_bytes())
        require(isinstance(declared, dict), f"Entitlements must be a dictionary: {path.name}")
        entitlements.update(declared)
    permissions = {
        "entitlements": sorted(entitlements - IGNORED_ENTITLEMENTS),
        "privacy": dict(sorted(privacy.items())),
    }
    return {
        "version": version, "buildVersion": build, "size": actual_size,
        "sha256": digest, "minOSVersion": minimum_os,
    }, permissions


def previous_versions(previous: dict | None, repository: str, current: dict) -> tuple[list[dict], dict]:
    if previous is None:
        return [], {"entitlements": [], "privacy": {}}
    require(isinstance(previous, dict) and previous.get("identifier") == SOURCE_ID,
            "Previous feed has a different source identity")
    require(previous.get("website") == f"https://github.com/{repository}", "Previous feed belongs to a different repository")
    apps = previous.get("apps")
    require(isinstance(apps, list) and len(apps) == 1 and isinstance(apps[0], dict)
            and apps[0].get("bundleIdentifier") == BUNDLE_ID, "Previous feed has a different app identity")
    permissions = apps[0].get("appPermissions")
    require(isinstance(permissions, dict) and isinstance(permissions.get("entitlements"), list)
            and all(isinstance(key, str) and bool(key) for key in permissions["entitlements"])
            and isinstance(permissions.get("privacy"), dict)
            and all(isinstance(key, str) and re.fullmatch(r"NS.+UsageDescription.*", key)
                    and isinstance(value, str) and bool(value.strip()) for key, value in permissions["privacy"].items()),
            "Previous feed permissions are malformed")
    versions = apps[0].get("versions")
    require(isinstance(versions, list) and bool(versions), "Previous feed must contain versions")
    seen = set()
    last_build = None
    for entry in versions:
        require(isinstance(entry, dict), "Previous version is malformed")
        version_number(entry.get("version"), "Previous version")
        build = build_number(entry.get("buildVersion"))
        require(last_build is None or build < last_build, "Previous versions must have distinct descending build numbers")
        last_build = build
        require((entry["version"], build) not in seen, "Previous feed contains duplicate versions")
        seen.add((entry["version"], build))
        release_date(entry.get("date"))
        version_number(entry.get("minOSVersion"), "Previous minimum iOS")
        require(type(entry.get("size")) is int and entry["size"] > 0, "Previous IPA size is invalid")
        require(isinstance(entry.get("sha256"), str) and re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]),
                "Previous IPA SHA-256 is invalid")
        expected_url = release_url(repository, "rain-build-" + entry["buildVersion"], "Rain.ipa")
        require(entry.get("downloadURL") == expected_url, "Previous download must use this repository's immutable build release")

    latest = versions[0]
    if build_number(current["buildVersion"]) <= build_number(latest["buildVersion"]):
        require(all(current.get(key) == latest.get(key) for key in
                    ("version", "buildVersion", "downloadURL", "size", "sha256", "minOSVersion")),
                "Refusing to replace a newer published build or overwrite an existing build")
        # A retry can republish identical artifacts without duplicating its version.
        return versions[1:MAX_VERSIONS], permissions
    return versions[:MAX_VERSIONS - 1], permissions


def make_source(ipa: Path, manifest: dict, repository: str, tag: str, *,
                previous: dict | None = None, date: str | None = None, notes: str = "") -> dict:
    require(isinstance(repository, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repository)
            and repository.split("/")[1] not in {".", ".."}, "repository must be GitHub OWNER/NAME")
    require(repository.lower() != "minh-ton/reynard-browser", "Publish this custom source from a separate GitHub fork")
    require(ipa.name == "Rain.ipa", "Use the stable Rain IPA asset filename")
    require(isinstance(manifest, dict), "Build manifest must be a JSON object")
    version, permissions = read_ipa(ipa, manifest)
    require(tag == "rain-build-" + version["buildVersion"], "Release tag must be rain-build-<buildVersion>")
    version.update({
        "date": release_date(date or datetime.now(timezone.utc).isoformat()),
        "downloadURL": release_url(repository, tag, ipa.name),
        "localizedDescription": notes.strip() or "Custom Rain build. Keeps the preview's separate app identity, native video changes, and icon.",
    })
    history, old_permissions = previous_versions(previous, repository, version)
    # Keeping old permissions also allows installing compatible older entries.
    permissions["entitlements"] = sorted(set(permissions["entitlements"]) | set(old_permissions["entitlements"]))
    permissions["privacy"] = {**old_permissions["privacy"], **permissions["privacy"]}
    icon = source_url(repository, "Rain.png")
    return {
        "name": "Rain",
        "identifier": SOURCE_ID,
        "website": f"https://github.com/{repository}",
        "subtitle": "Custom Reynard with native video playback",
        "description": "Custom Rain builds based on Reynard Browser. This source updates the existing preview and keeps ordinary Reynard separate. Source code and build logs are available in the linked GitHub repository.",
        "iconURL": icon,
        "tintColor": "#FB3728",
        "apps": [{
            "name": "Rain",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "Minh Ton and AVKit contributors",
            "subtitle": "Gecko browser with native video controls",
            "localizedDescription": "Rain is based on Reynard Browser with custom native AVKit playback and Picture in Picture support. Install with SideStore using the same Apple Account and keep both app extensions to update the existing Rain or AVKit preview. This app requires JIT, just like upstream Reynard. Browser-managed video uses the existing Gecko playback engine; native AirPlay is available for supported direct video streams.",
            "iconURL": icon,
            "tintColor": "#FB3728",
            "category": "utilities",
            "appPermissions": permissions,
            "versions": [version, *history],
        }],
        "news": [],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--repository", required=True, help="GitHub owner/repository")
    parser.add_argument("--tag", required=True, help="Immutable rain-build-<buildVersion> release tag")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--previous", type=Path, help="Previously published source.json, if one exists")
    parser.add_argument("--date", help="ISO 8601 publication timestamp; defaults to current UTC time")
    parser.add_argument("--notes-file", type=Path)
    args = parser.parse_args()
    try:
        source = make_source(
            args.ipa, json.loads(args.manifest.read_text(encoding="utf-8")), args.repository, args.tag,
            previous=json.loads(args.previous.read_text(encoding="utf-8")) if args.previous else None,
            date=args.date, notes=args.notes_file.read_text(encoding="utf-8") if args.notes_file else "",
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(args.output.name + ".tmp")
        temporary.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(args.output)
        print(f"Generated {args.output}: {source['apps'][0]['versions'][0]['version']} ({source['apps'][0]['versions'][0]['buildVersion']})")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"Cannot generate AVKit source: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
