"""Checks feed metadata against packaged app identity, not a handwritten feed."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("avkit_source", ROOT / "tools/avkit/source.py")
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)
REPOSITORY = "example/reynard-browser"
BUILD = "20261026183000"
DATE = "2026-10-26T18:30:00Z"


class SourceChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.ipa = self.path / "Rain.ipa"
        self.infos = {}
        for path, identifier in {SOURCE.APP_PATH: SOURCE.BUNDLE_ID, **SOURCE.EXTENSIONS}.items():
            self.infos[path] = {
                "CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": "0.19.0",
                "CFBundleVersion": BUILD,
                "MinimumOSVersion": "15.0",
                "CFBundleExecutable": path.rsplit("/", 1)[-1].split(".")[0],
            }
        self.infos[SOURCE.APP_PATH].update({
            "CFBundleDisplayName": "Rain",
            "ReynardURLScheme": "reynard-avkit",
            "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "NativeVideoAppIcon"}},
            "NSCameraUsageDescription": "Website camera access.",
        })
        self.infos[SOURCE.APP_PATH + "/PlugIns/OpenIn.appex"]["NSPhotoLibraryUsageDescription"] = "Extension photo access."
        self.write_ipa()

    def write_ipa(self):
        with zipfile.ZipFile(self.ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path, info in self.infos.items():
                archive.writestr(path + "/Info.plist", plistlib.dumps(info))
                archive.writestr(path + "/" + info["CFBundleExecutable"], b"fixture executable")
        self.manifest = {
            "artifact": self.ipa.name,
            "sha256": hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
            "size": self.ipa.stat().st_size,
            "version": "0.19.0",
            "buildVersion": self.infos[SOURCE.APP_PATH]["CFBundleVersion"],
            "bundleIdentifier": SOURCE.BUNDLE_ID,
            "minimumOSVersion": "15.0",
            "sourceCommit": "a" * 40,
        }

    def generate(self, **kwargs):
        return SOURCE.make_source(self.ipa, self.manifest, REPOSITORY,
                                  "rain-build-" + self.manifest["buildVersion"], date=DATE, **kwargs)

    def assert_rejected(self, message, **kwargs):
        with self.assertRaisesRegex(ValueError, message):
            self.generate(**kwargs)

    def test_metadata_matches_ipa_and_is_separate_from_official_source(self):
        feed = self.generate()
        app = feed["apps"][0]
        version = app["versions"][0]
        self.assertEqual(app["bundleIdentifier"], SOURCE.BUNDLE_ID)
        self.assertEqual(version["version"], "0.19.0")
        self.assertEqual(version["buildVersion"], BUILD)
        self.assertEqual(version["sha256"], self.manifest["sha256"])
        self.assertEqual(version["size"], self.ipa.stat().st_size)
        self.assertEqual(version["minOSVersion"], "15.0")
        self.assertEqual(version["downloadURL"], f"https://github.com/{REPOSITORY}/releases/download/rain-build-{BUILD}/Rain.ipa")
        self.assertEqual(app["iconURL"], f"https://raw.githubusercontent.com/{REPOSITORY}/rain-source/Rain.png")
        self.assertNotIn("marketplaceID", app)
        self.assertNotIn("Build", app)

    def test_app_and_extension_permissions_are_disclosed_without_private_jit_entitlements(self):
        permissions = self.generate()["apps"][0]["appPermissions"]
        self.assertEqual(permissions["entitlements"], ["com.apple.developer.kernel.increased-memory-limit", "get-task-allow"])
        self.assertEqual(permissions["privacy"], {
            "NSCameraUsageDescription": "Website camera access.",
            "NSPhotoLibraryUsageDescription": "Extension photo access.",
        })
        self.assertNotIn("platform-application", permissions["entitlements"])

    def test_old_local_manifest_field_names_are_supported(self):
        for new, old in [("size", "bytes"), ("buildVersion", "bundle_build"),
                         ("bundleIdentifier", "bundle_identifier"), ("minimumOSVersion", "minimum_iOS"),
                         ("sourceCommit", "source_commit")]:
            self.manifest[old] = self.manifest.pop(new)
        result = SOURCE.make_source(self.ipa, self.manifest, REPOSITORY, "rain-build-" + BUILD, date=DATE)
        self.assertEqual(result["apps"][0]["versions"][0]["buildVersion"], BUILD)

    def test_conflicting_manifest_aliases_are_rejected(self):
        self.manifest["bundle_build"] = "20261026183001"
        self.assert_rejected("Conflicting manifest")

    def test_hash_and_size_are_verified(self):
        self.manifest["sha256"] = "0" * 64
        self.assert_rejected("SHA-256")
        self.write_ipa()
        self.manifest["size"] += 1
        self.assert_rejected("size")

    def test_main_and_extension_ids_are_verified(self):
        for path in self.infos:
            with self.subTest(path=path):
                original = self.infos[path]["CFBundleIdentifier"]
                self.infos[path]["CFBundleIdentifier"] = "com.minh-ton.Reynard"
                self.write_ipa()
                self.assert_rejected("bundle identifier")
                self.infos[path]["CFBundleIdentifier"] = original

    def test_missing_or_additional_extensions_are_rejected(self):
        path = SOURCE.APP_PATH + "/PlugIns/OpenIn.appex"
        original = self.infos.pop(path)
        self.write_ipa()
        self.assert_rejected("exactly the OpenIn")
        self.infos[path] = original
        self.infos[SOURCE.APP_PATH + "/PlugIns/Unexpected.appex"] = copy.deepcopy(original)
        self.write_ipa()
        self.assert_rejected("exactly the OpenIn")

    def test_extension_version_build_and_os_must_match_app(self):
        info = self.infos[SOURCE.APP_PATH + "/PlugIns/OpenIn.appex"]
        for key, changed in [("CFBundleShortVersionString", "0.18.0"), ("CFBundleVersion", "2026102607"), ("MinimumOSVersion", "14.0")]:
            with self.subTest(key=key):
                original = info[key]
                info[key] = changed
                self.write_ipa()
                self.assert_rejected("mismatch")
                info[key] = original

    def test_empty_privacy_description_is_rejected(self):
        self.infos[SOURCE.APP_PATH]["NSCameraUsageDescription"] = " "
        self.write_ipa()
        self.assert_rejected("Empty privacy")

    def test_build_must_be_numeric_and_newer_than_phone_build(self):
        for build in ["2026102607", "2026102606", "abc1234", "01", "1.2", "0", "-1"]:
            with self.subTest(build=build):
                self.manifest["buildVersion"] = build
                self.assert_rejected("buildVersion|newer")

    def test_malformed_version_os_and_commit_metadata_are_rejected(self):
        original = copy.deepcopy(self.manifest)
        for field, value in [("version", "v0.19.0"), ("version", 19),
                             ("version", "0.19.0-beta"), ("minimumOSVersion", "iOS 15"),
                             ("sourceCommit", "a95eeec")]:
            with self.subTest(field=field, value=value):
                self.manifest = {**original, field: value}
                self.assert_rejected("version|minimumOSVersion|sourceCommit")

    def test_preview_name_scheme_and_custom_icon_are_preserved(self):
        info = self.infos[SOURCE.APP_PATH]
        original = copy.deepcopy(info)
        for field, value in [("CFBundleDisplayName", "Reynard"), ("ReynardURLScheme", "reynard"),
                             ("CFBundleIcons", {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}})]:
            with self.subTest(field=field):
                self.infos[SOURCE.APP_PATH] = {**original, field: value}
                self.write_ipa()
                self.assert_rejected("display name|scheme|custom NativeVideoAppIcon")

    def test_publication_target_and_immutable_tag_are_verified(self):
        for repository, tag in [("minh-ton/reynard-browser", "rain-build-" + BUILD),
                                ("example/reynard-browser?token=secret", "rain-build-" + BUILD),
                                (REPOSITORY, "avkit-source")]:
            with self.subTest(repository=repository, tag=tag):
                with self.assertRaises(ValueError):
                    SOURCE.make_source(self.ipa, self.manifest, repository, tag, date=DATE)

    def test_same_marketing_version_with_new_build_is_first(self):
        previous = self.generate()
        for info in self.infos.values():
            info["CFBundleVersion"] = str(int(BUILD) + 1)
        self.write_ipa()
        feed = self.generate(previous=previous)
        versions = feed["apps"][0]["versions"]
        self.assertEqual([v["buildVersion"] for v in versions], [str(int(BUILD) + 1), BUILD])
        self.assertEqual([v["version"] for v in versions], ["0.19.0", "0.19.0"])

    def test_retry_is_idempotent_but_rollback_and_replacement_are_rejected(self):
        previous = self.generate()
        self.assertEqual(len(self.generate(previous=previous)["apps"][0]["versions"]), 1)
        previous["apps"][0]["versions"][0]["sha256"] = "0" * 64
        self.assert_rejected("Refusing to replace", previous=previous)
        previous = self.generate()
        for info in self.infos.values():
            info["CFBundleVersion"] = str(int(BUILD) - 1)
        self.write_ipa()
        self.assert_rejected("Refusing to replace", previous=previous)

    def test_history_is_bounded_and_old_permissions_are_retained(self):
        previous = self.generate()
        version = previous["apps"][0]["versions"][0]
        previous["apps"][0]["appPermissions"]["privacy"]["NSMicrophoneUsageDescription"] = "Older microphone permission."
        for offset in range(1, 25):
            entry = copy.deepcopy(version)
            entry["buildVersion"] = str(int(BUILD) - offset)
            entry["downloadURL"] = SOURCE.release_url(REPOSITORY, "rain-build-" + entry["buildVersion"], self.ipa.name)
            previous["apps"][0]["versions"].append(entry)
        for info in self.infos.values():
            info["CFBundleVersion"] = str(int(BUILD) + 1)
        self.write_ipa()
        app = self.generate(previous=previous)["apps"][0]
        self.assertEqual(len(app["versions"]), SOURCE.MAX_VERSIONS)
        self.assertIn("NSMicrophoneUsageDescription", app["appPermissions"]["privacy"])

    def test_wrong_previous_source_and_changed_download_urls_are_rejected(self):
        for mutation in [lambda data: data.update(identifier="com.minh-ton.Reynard"),
                         lambda data: data.update(website="https://github.com/another/repo"),
                         lambda data: data["apps"][0]["versions"][0].update(downloadURL="https://example.com/app.ipa")]:
            with self.subTest(mutation=mutation):
                previous = self.generate()
                mutation(previous)
                self.assert_rejected("identity|repository|immutable", previous=previous)

    def test_iso_date_validation(self):
        self.assertEqual(SOURCE.release_date("2026-10-26T19:30:00+01:00"), DATE)
        for value in ["yesterday", "2026-10-26", "2026-10-26T18:30:00"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                SOURCE.release_date(value)

    def test_cli_failure_preserves_existing_feed(self):
        manifest = self.path / "build.json"
        manifest.write_text(json.dumps({**self.manifest, "sha256": "0" * 64}))
        output = self.path / "source.json"
        output.write_text("previous feed")
        result = subprocess.run([sys.executable, str(ROOT / "tools/avkit/source.py"),
                                 "--ipa", str(self.ipa), "--manifest", str(manifest),
                                 "--repository", REPOSITORY, "--tag", "rain-build-" + BUILD,
                                 "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SHA-256", result.stderr)
        self.assertEqual(output.read_text(), "previous feed")


if __name__ == "__main__":
    unittest.main()
