#!/usr/bin/env python3
"""Validate and package the AVKit archive for SideStore signing."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / "dist"
APP = DIST / "Rain.xcarchive/Products/Applications/Reynard.app"
IDENTIFIER = "com.minh-ton.ReynardAVKit"
ARTIFACT = "Rain.ipa"
MACHO_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def validate_app(app, metadata):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == IDENTIFIER, "Unexpected app identity; ordinary Reynard must stay separate")
    require(info.get("CFBundleDisplayName") == "Rain", "Incorrect Rain display name")
    require(info.get("CFBundleVersion") == metadata["buildVersion"], "Archive build number differs from prepared source")
    require(info.get("ReynardURLScheme") == "reynard-avkit", "Incorrect private URL scheme")
    require(info.get("ReynardBrowserDisplayName") == "Rain", "Incorrect browser display name key")
    schemes = [scheme for entry in info.get("CFBundleURLTypes", []) for scheme in entry.get("CFBundleURLSchemes", [])]
    require(schemes == ["reynard-avkit"], "AVKit URL scheme must not capture ordinary Reynard")
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        if key in info:
            require(info[key].get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "NativeVideoAppIcon", "Custom primary icon is missing")
    require("CFBundleIcons" in info, "Compiled icon metadata is missing")
    require(info.get("MinimumOSVersion"), "Minimum iOS version is missing")
    require(isinstance(info.get("CFBundleShortVersionString"), str) and info["CFBundleShortVersionString"], "Marketing version is missing")

    expected = {"OpenIn.appex": IDENTIFIER + ".OpenIn", "Reynard Helper.appex": IDENTIFIER + ".Helper"}
    require({p.name for p in (app / "PlugIns").glob("*.appex")} == set(expected), "Expected exactly the existing two extensions")
    extensions = []
    for name, identifier in expected.items():
        extension = plistlib.loads((app / "PlugIns" / name / "Info.plist").read_bytes())
        require(extension.get("CFBundleIdentifier") == identifier, f"Incorrect extension ID: {name}")
        require(extension.get("CFBundleVersion") == metadata["buildVersion"], f"Incorrect extension build: {name}")
        require(extension.get("CFBundleShortVersionString") == info["CFBundleShortVersionString"], f"Incorrect extension version: {name}")
        require(extension.get("MinimumOSVersion") == info["MinimumOSVersion"], f"Incorrect extension minimum iOS version: {name}")
        display_name = "Open in Rain" if name == "OpenIn.appex" else "Rain Helper"
        require(extension.get("CFBundleDisplayName") == display_name, f"Incorrect extension display name: {name}")
        if name == "OpenIn.appex":
            require(extension.get("ReynardURLScheme") == "reynard-avkit", "Share extension must open this preview")
            require(extension.get("ReynardBrowserDisplayName") == "Rain", "Share extension must use Rain in messages")
        extensions.append(identifier)

    binaries = ["Reynard", "Frameworks/GeckoView.framework/GeckoView", "Frameworks/XUL", "PlugIns/OpenIn.appex/OpenIn", "PlugIns/Reynard Helper.appex/Reynard Helper"]
    for name in binaries:
        path = app / name
        require(path.is_file(), f"Missing compiled binary: {name}")
        with path.open("rb") as source:
            require(source.read(4) in MACHO_MAGIC, f"Invalid Mach-O binary: {name}")
    for relative in ("modules/GeckoViewContent.sys.mjs", "actors/GeckoViewContentChild.sys.mjs"):
        module = (app / "Frameworks/GeckoView.framework/Frameworks" / relative).read_bytes()
        require(b"NativeVideo:Get" in module and b"NativeVideo:Command" in module, f"Missing AVKit Gecko bridge: {relative}")
    require(not list(app.rglob("embedded.mobileprovision")), "Personal provisioning profiles must not be published")
    return info, extensions, binaries


def main():
    metadata = json.loads((DIST / "avkit-build/preparation.json").read_text())
    source_commit = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    require(source_commit == metadata["sourceCommit"], "Checkout changed during the build")
    require("** ARCHIVE SUCCEEDED **" in (DIST / "Rain.xcodebuild.log").read_text(errors="replace"), "Xcode archive did not succeed")
    for relative, expected_hash in metadata["nativeVideoSwiftSHA256"].items():
        require(digest(ROOT / "browser" / relative) == expected_hash, f"Source changed during build: {relative}")
    require(digest(ROOT / "browser/Configuration/NativeVideoPreview.json") == metadata["brandingSHA256"], "Rain branding changed during the build")
    icon = ROOT / "browser/Reynard/Resources/Assets.xcassets/NativeVideoAppIcon.appiconset"
    for name, expected_hash in metadata["iconAssetSHA256"].items():
        require(digest(icon / name) == expected_hash, "Approved icon changed during build")
    info, extensions, binaries = validate_app(APP, metadata)
    for name in binaries:
        subprocess.run(["xcrun", "lipo", "-verify_arch", "arm64", str(APP / name)], check=True)

    ipa = DIST / ARTIFACT
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(APP.rglob("*")):
            if path.is_file() and path.name != ".DS_Store" and not path.name.startswith("._"):
                archive.write(path, Path("Payload/Reynard.app") / path.relative_to(APP))
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "Corrupt packaged IPA")
    manifest = {
        **metadata,
        "artifact": ARTIFACT,
        "version": info["CFBundleShortVersionString"],
        "bundleIdentifier": info["CFBundleIdentifier"],
        "displayName": info["CFBundleDisplayName"],
        "minimumOSVersion": info["MinimumOSVersion"],
        "extensionBundleIdentifiers": extensions,
        "sha256": digest(ipa),
        "size": ipa.stat().st_size,
        "builtAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "signing": "Unsigned app and extensions; sign and refresh with SideStore on the iPhone",
        "engine": "Built from the pinned Gecko release source with this fork's patches",
        "build": "GitHub Actions full source build; Xcode Release archive for arm64",
        "runtimeValidation": "Cloud packaging and identity checks passed; playback must be tested on an iPhone",
    }
    (DIST / "Rain.build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
