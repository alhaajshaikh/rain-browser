#!/usr/bin/env python3
"""Stage the separate AVKit variant without changing the upstream Xcode project."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = "com.minh-ton.ReynardAVKit"
ICON = "Reynard/Resources/Assets.xcassets/NativeVideoAppIcon.appiconset"
LAST_LOCAL_BUILD = 2026102608


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def git(repo, *arguments):
    return subprocess.check_output(["git", "-C", str(repo), *arguments], text=True).strip()


def replace_setting(text, name, value):
    text, count = re.subn(rf"^{re.escape(name)} = .*$", f"{name} = {value}", text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"Expected one {name} setting; found {count}. Review the upstream configuration.")
    return text


def prepare(repo, output, build, repository=None):
    if not build.isdecimal() or int(build) <= LAST_LOCAL_BUILD:
        raise ValueError(f"Build must be numeric and greater than {LAST_LOCAL_BUILD}")
    if repository is not None and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Repository must be a GitHub owner/repository name")
    engine = repo / "engine/firefox"
    if Path(git(engine, "rev-parse", "--show-toplevel")).resolve() != engine.resolve():
        raise ValueError("Initialize and build the pinned Gecko submodule before staging the app")
    branding_path = repo / "browser/Configuration/NativeVideoPreview.json"
    branding = json.loads(branding_path.read_text())
    expected_keys = {"display_name", "share_display_name", "helper_display_name", "artifact_stem"}
    if set(branding) != expected_keys or any(not isinstance(value, str) or not value for value in branding.values()):
        raise ValueError("Invalid NativeVideoPreview.json branding")
    if branding["artifact_stem"] != "Rain" or branding["display_name"] != "Rain":
        raise ValueError("This cloud recipe must retain the Rain artifact and display name")
    output.mkdir(parents=True, exist_ok=True)
    staged = output / "browser"
    if staged.exists():
        shutil.rmtree(staged)
    shutil.copytree(repo / "browser", staged, ignore=shutil.ignore_patterns("xcuserdata", "*.xcuserstate"))

    project = staged / "Reynard.xcodeproj/project.pbxproj"
    text = project.read_text()
    for identifier in ("com.minh-ton.Reynard.OpenIn", "com.minh-ton.Reynard.Helper", "com.minh-ton.Reynard"):
        if f'PRODUCT_BUNDLE_IDENTIFIER = "{identifier}";' not in text:
            raise ValueError(f"Missing upstream target identity {identifier}; review the project before publishing.")
    text = text.replace("com.minh-ton.Reynard", IDENTIFIER)
    if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" not in text:
        raise ValueError("Missing upstream AppIcon build setting")
    text = text.replace("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;", "ASSETCATALOG_COMPILER_APPICON_NAME = NativeVideoAppIcon;")
    text = text.replace('INFOPLIST_KEY_CFBundleDisplayName = "Open in Reynard";', f'INFOPLIST_KEY_CFBundleDisplayName = "{branding["share_display_name"]}";')
    text = text.replace('INFOPLIST_KEY_CFBundleDisplayName = "Reynard Helper";', f'INFOPLIST_KEY_CFBundleDisplayName = "{branding["helper_display_name"]}";')
    project.write_text(text)

    for relative in ("Reynard/Resources/Info.plist", "Extensions/OpenIn/Info.plist"):
        path = staged / relative
        info = plistlib.loads(path.read_bytes())
        info["ReynardURLScheme"] = "reynard-avkit"
        info["ReynardBrowserDisplayName"] = branding["display_name"]
        if relative.startswith("Reynard/"):
            info["CFBundleURLTypes"] = [{"CFBundleURLName": IDENTIFIER, "CFBundleURLSchemes": ["reynard-avkit"]}]
        path.write_bytes(plistlib.dumps(info))

    # These compatibility adjustments are confined to the generated project.
    # Xcode 27 cannot compile the obsolete iOS 13 annotation even in a dead branch.
    main = staged / "Reynard/main.swift"
    main.write_text(main.read_text().replace('@available(iOS, introduced: 13.0, obsoleted: 14.0)\n', ''))
    toolbar = staged / "Reynard/Client/Interface/Chrome/Toolbar/ToolbarButtonMenus.swift"
    toolbar.write_text(toolbar.read_text().replace('if #available(iOS 15.0, *) {\n                action.subtitle', 'if #available(iOS 16.0, *) {\n                action.subtitle').replace('if #available(iOS 15.0, *),\n               let value', 'if #available(iOS 16.0, *),\n               let value'))

    add_gecko = staged / "Scripts/AddGecko.sh"
    add_gecko.write_text(add_gecko.read_text().replace('${SRCROOT}/../engine/firefox/toolkit/mozapps/extensions/default-theme', str(repo / 'engine/firefox/toolkit/mozapps/extensions/default-theme')))
    config = (staged / "Configuration/Reynard.xcconfig").read_text()
    for name, value in {
        "CURRENT_BUILD": build,
        "APP_DISPLAY_NAME": branding["display_name"],
        "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
        "GECKO_DIST": str(repo / "engine/firefox/obj-aarch64-apple-ios/dist"),
    }.items():
        config = replace_setting(config, name, value)
    config_path = output / "Rain.xcconfig"
    config_path.write_text(config)

    icon_hashes = {path.name: digest(path) for path in sorted((repo / "browser" / ICON).iterdir()) if path.is_file()}
    if icon_hashes.get("icon.png") != "27577cf8182e80f50bffbaca9b6f181d42affc63ccd0bb887e37bdb5689c399e":
        raise ValueError("The custom icon changed; preserve the approved icon and its white border.")
    metadata = {
        "buildVersion": build,
        "repository": repository,
        "branding": branding,
        "brandingSHA256": digest(branding_path),
        "sourceCommit": git(repo, "rev-parse", "HEAD"),
        "engineRelease": (repo / "engine/release.txt").read_text().strip(),
        "engineCommit": git(repo / "engine/firefox", "rev-parse", "HEAD"),
        "preparedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "iconAssetSHA256": icon_hashes,
        "nativeVideoSwiftSHA256": {
            str(path.relative_to(repo / "browser")): digest(path)
            for path in sorted((repo / "browser").rglob("NativeVideo*.swift"))
        },
    }
    (output / "preparation.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True, help="Monotonically increasing numeric CFBundleVersion")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/avkit-build")
    parser.add_argument("--repository", help="GitHub owner/repository for build provenance")
    options = parser.parse_args()
    print(json.dumps(prepare(ROOT, options.output.resolve(), options.build, options.repository), indent=2))


if __name__ == "__main__":
    main()
