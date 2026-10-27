import base64
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "tools/avkit/build-needed.py"
SPEC = importlib.util.spec_from_file_location("rain_build_plan", SCRIPT)
PLAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN)


class BuildPlanChecks(unittest.TestCase):
    current = "a" * 40
    previous = "b" * 40

    def test_manual_always_builds(self):
        self.assertEqual(PLAN.decide("workflow_dispatch", False, self.current, self.current)["build"], "true")

    def test_schedule_skips_only_published_current_source_and_latest_upstream(self):
        self.assertEqual(PLAN.decide("schedule", False, self.current, self.current)["build"], "false")

    def test_schedule_builds_a_new_upstream_release(self):
        self.assertEqual(PLAN.decide("schedule", True, self.current, self.current)["build"], "true")

    def test_schedule_retries_after_branch_push_but_publication_failure(self):
        self.assertEqual(PLAN.decide("schedule", False, self.current, self.previous)["build"], "true")

    def test_schedule_builds_when_the_source_is_not_published(self):
        self.assertEqual(PLAN.decide("schedule", False, self.current, None)["build"], "true")

    def source(self, **version_overrides):
        version = {"buildVersion": "20261026123456", "downloadURL": "https://github.com/example/Rain/releases/download/rain-build-20261026123456/Rain.ipa"}
        version.update(version_overrides)
        source = {"apps": [{"bundleIdentifier": "com.minh-ton.ReynardAVKit", "versions": [version]}]}
        return json.dumps({"encoding": "base64", "content": base64.b64encode(json.dumps(source).encode()).decode()})

    def manifest(self, **overrides):
        manifest = {"buildVersion": "20261026123456", "artifact": "Rain.ipa", "bundleIdentifier": "com.minh-ton.ReynardAVKit", "sourceCommit": self.current}
        manifest.update(overrides)
        return json.dumps(manifest)

    def test_reads_immutable_manifest_for_the_version_actually_visible_in_sidestore(self):
        with patch.object(PLAN, "gh", side_effect=[self.source(), self.manifest()]) as gh:
            self.assertEqual(PLAN.last_published_commit("example/Rain"), self.current)
        self.assertEqual(gh.call_args_list[1].args, ("release", "download", "rain-build-20261026123456", "--repo", "example/Rain", "--pattern", "Rain.build.json", "--output", "-"))

    def test_missing_feed_causes_a_build(self):
        with patch.object(PLAN, "gh", return_value=None):
            self.assertIsNone(PLAN.last_published_commit("example/Rain"))

    def test_rejects_feed_redirect_to_another_repo(self):
        with patch.object(PLAN, "gh", return_value=self.source(downloadURL="https://example.test/untrusted.ipa")), self.assertRaises(ValueError):
            PLAN.last_published_commit("example/Rain")

    def test_rejects_manifest_identity_build_and_commit_mismatches(self):
        for overrides in ({"buildVersion": "2026102607"}, {"artifact": "Reynard.ipa"}, {"bundleIdentifier": "com.minh-ton.Reynard"}, {"sourceCommit": "not a commit"}):
            with self.subTest(overrides=overrides), patch.object(PLAN, "gh", side_effect=[self.source(), self.manifest(**overrides)]), self.assertRaises(ValueError):
                PLAN.last_published_commit("example/Rain")

    def test_network_errors_stop_the_check_instead_of_silently_skipping(self):
        with patch.object(PLAN, "gh", side_effect=ValueError("Network error")), self.assertRaises(ValueError):
            PLAN.last_published_commit("example/Rain")


if __name__ == "__main__":
    unittest.main()
