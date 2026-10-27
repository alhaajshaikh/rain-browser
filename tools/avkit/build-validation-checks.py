#!/usr/bin/env python3
"""Exercise variant isolation and reject incorrectly packaged app identities."""

from copy import deepcopy
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load("avkit_prepare", "prepare-build.py")
package = load("avkit_package", "package-build.py")


class BuildValidationChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="reynard-avkit-build-checks-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.app = self.directory / "Reynard.app"
        self.app.mkdir()
        self.metadata = {"buildVersion": "20261026123456", "repository": "example/reynard-browser"}
        self.info = {
            "CFBundleIdentifier": package.IDENTIFIER,
            "CFBundleDisplayName": "Rain",
            "CFBundleVersion": self.metadata["buildVersion"],
            "CFBundleShortVersionString": "0.19.0",
            "ReynardURLScheme": "reynard-avkit",
            "ReynardBrowserDisplayName": "Rain",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["reynard-avkit"]}],
            "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "NativeVideoAppIcon"}},
            "MinimumOSVersion": "15.0",
        }
        self.write_info()
        for name, suffix in (("OpenIn", "OpenIn"), ("Reynard Helper", "Helper")):
            extension = self.app / f"PlugIns/{name}.appex"
            extension.mkdir(parents=True)
            (extension / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": package.IDENTIFIER + "." + suffix,
                "CFBundleVersion": self.metadata["buildVersion"],
                "CFBundleShortVersionString": self.info["CFBundleShortVersionString"],
                "CFBundleDisplayName": "Open in Rain" if suffix == "OpenIn" else "Rain Helper",
                "MinimumOSVersion": self.info["MinimumOSVersion"],
                "ReynardURLScheme": "reynard-avkit",
                "ReynardBrowserDisplayName": "Rain",
            }))
        for relative in ("Reynard", "Frameworks/GeckoView.framework/GeckoView", "Frameworks/XUL", "PlugIns/OpenIn.appex/OpenIn", "PlugIns/Reynard Helper.appex/Reynard Helper"):
            binary = self.app / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(package.MACHO_MAGIC[0] + b"fixture")
        for relative in ("modules/GeckoViewContent.sys.mjs", "actors/GeckoViewContentChild.sys.mjs"):
            module = self.app / "Frameworks/GeckoView.framework/Frameworks" / relative
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_bytes(b"NativeVideo:Get NativeVideo:Command")

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def assert_invalid(self):
        with self.assertRaises(ValueError):
            package.validate_app(self.app, self.metadata)

    def test_valid_identity_and_existing_extensions(self):
        _, extensions, binaries = package.validate_app(self.app, self.metadata)
        self.assertEqual(extensions, [package.IDENTIFIER + ".OpenIn", package.IDENTIFIER + ".Helper"])
        self.assertEqual(len(binaries), 5)

    def test_rejects_ordinary_app_and_wrong_build_icon_or_repository(self):
        original = deepcopy(self.info)
        for key, value in (("CFBundleIdentifier", "com.minh-ton.Reynard"), ("CFBundleVersion", "2026102607"), ("ReynardURLScheme", "reynard"), ("CFBundleIcons", {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}})):
            with self.subTest(key=key):
                self.info = {**deepcopy(original), key: value}
                self.write_info()
                self.assert_invalid()

    def test_rejects_url_scheme_collision(self):
        self.info["CFBundleURLTypes"][0]["CFBundleURLSchemes"].append("reynard")
        self.write_info()
        self.assert_invalid()

    def test_rejects_extra_extension_that_consumes_another_app_id(self):
        (self.app / "PlugIns/Unexpected.appex").mkdir()
        self.assert_invalid()

    def test_rejects_renamed_helper_folder(self):
        (self.app / "PlugIns/Reynard Helper.appex").rename(self.app / "PlugIns/AVKit Helper.appex")
        self.assert_invalid()

    def test_rejects_wrong_extension_identity_or_version(self):
        path = self.app / "PlugIns/OpenIn.appex/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for key, value in (("CFBundleIdentifier", "com.minh-ton.Reynard.OpenIn"), ("CFBundleVersion", "2026102607"), ("ReynardURLScheme", "reynard")):
            with self.subTest(key=key):
                path.write_bytes(plistlib.dumps({**original, key: value}))
                self.assert_invalid()

    def test_rejects_uncompiled_executable(self):
        (self.app / "Frameworks/XUL").write_bytes(b"not an executable")
        self.assert_invalid()

    def test_rejects_missing_gecko_patch(self):
        (self.app / "Frameworks/GeckoView.framework/Frameworks/actors/GeckoViewContentChild.sys.mjs").write_bytes(b"upstream only")
        self.assert_invalid()

    def test_rejects_accidental_personal_provisioning_profile(self):
        (self.app / "embedded.mobileprovision").write_bytes(b"private profile")
        self.assert_invalid()

    def test_preparation_preserves_original_project_and_icon(self):
        repo = self.directory / "repo"
        repo.mkdir()
        shutil.copytree(ROOT / "browser", repo / "browser", ignore=shutil.ignore_patterns("xcuserdata", "*.xcuserstate"))
        engine = repo / "engine/firefox"
        engine.mkdir(parents=True)
        (repo / "engine/release.txt").write_text("FIREFOX_158_0_1_RELEASE\n")
        for path in (repo, engine):
            subprocess.run(["git", "init", "-q", str(path)], check=True)
            subprocess.run(["git", "-C", str(path), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "Fixture"], check=True)
        tracked = ["Reynard.xcodeproj/project.pbxproj", "Configuration/Reynard.xcconfig", "Reynard/Resources/Info.plist", "Extensions/OpenIn/Info.plist", prepare.ICON + "/icon.png"]
        before = {relative: (repo / "browser" / relative).read_bytes() for relative in tracked}
        output = self.directory / "staging"
        metadata = prepare.prepare(repo, output, "20261026123456", "example/reynard-browser")
        self.assertEqual(before, {relative: (repo / "browser" / relative).read_bytes() for relative in tracked})
        staged = output / "browser"
        info = plistlib.loads((staged / "Reynard/Resources/Info.plist").read_bytes())
        self.assertEqual(info["ReynardBrowserDisplayName"], "Rain")
        share = plistlib.loads((staged / "Extensions/OpenIn/Info.plist").read_bytes())
        self.assertEqual(share["ReynardBrowserDisplayName"], "Rain")
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["reynard-avkit"])
        self.assertEqual(metadata["branding"]["display_name"], "Rain")
        self.assertEqual(metadata["iconAssetSHA256"]["icon.png"], prepare.digest(staged / prepare.ICON / "icon.png"))
        config = (output / "Rain.xcconfig").read_text()
        self.assertIn("CURRENT_BUILD = 20261026123456", config)
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 15.0", config)
        project = (staged / "Reynard.xcodeproj/project.pbxproj").read_text()
        for identifier in (package.IDENTIFIER, package.IDENTIFIER + ".OpenIn", package.IDENTIFIER + ".Helper"):
            self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER = "{identifier}";', project)
        self.assertNotIn('PRODUCT_BUNDLE_IDENTIFIER = "com.minh-ton.Reynard";', project)

    def test_rejects_old_or_nonnumeric_builds_before_staging(self):
        for value in ("2026102607", "2026102608", "abc", "0.19.0"):
            with self.subTest(build=value), self.assertRaises(ValueError):
                prepare.prepare(self.directory / "absent", self.directory / "output", value)
        self.assertFalse((self.directory / "output").exists())


if __name__ == "__main__":
    unittest.main()
