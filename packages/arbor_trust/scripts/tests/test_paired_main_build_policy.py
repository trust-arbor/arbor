"""Synthetic runner integration only; no Main checkout, tool or BEAM is used."""
import argparse
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest import mock

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("paired_policy_qualifier", SCRIPTS / "qualify_paired.py")
runner = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPTS))
try:
    import cold_support as policy
    assert Path(policy.__file__).resolve() == SCRIPTS / "cold_support.py"
    SPEC.loader.exec_module(runner)
finally:
    sys.path.pop(0)


class PairedMainBuildPolicyTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="paired-build-policy-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve(strict=True)
        self.main = self.parent / "synthetic-main"
        self.root = self.main / "_build"
        self.root.mkdir(parents=True, mode=0o700)
        for relative in policy.REVIEWED_BOUNDARY_VIEWS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(b"before")
        self.cache_paths = runner.main_build_snapshot(self.root, "reviewed-boundary-view-v2")["cache_audit"]
        self.cache = self.root / next(iter(self.cache_paths))
        self.work = self.parent / "attempt"
        self.work.mkdir(mode=0o700)

    def snapshot(self, policy="reviewed-boundary-view-v2"):
        return runner.main_build_snapshot(self.root, policy)

    def rewrite(self, path, value=b"after!"):
        before = path.stat()
        path.write_bytes(value)
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000))

    def args_and_manifest(self, policy="reviewed-boundary-view-v2"):
        args = argparse.Namespace(work_dir=self.work, main_root=self.main, main_build_policy=policy)
        manifest = {
            "args": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
            "main_build_policy": policy,
            "guard_before": {"main_build": self.snapshot(policy)},
        }
        return args, manifest

    def write_manifest(self, manifest, results=False):
        data = json.dumps(manifest, indent=2, sort_keys=True).encode()
        (self.work / "source-manifest.json").write_bytes(data)
        if results:
            (self.work / "results.json").write_text(json.dumps({
                "status": "prepared", "source_manifest_sha256": hashlib.sha256(data).hexdigest(), "steps": []
            }))
        return data

    def parser_arguments(self):
        arguments = ["--prepare"]
        for option in ("repository", "main-root", "work-dir", "fixtures-root", "mix", "erlang-root", "elixir-root",
                       "hex-archive", "cc", "make", "rebar3", "deps-source-cache", "initial-manifest", "sdk-root", "developer-dir"):
            arguments += ["--" + option, str(self.parent / option)]
        for option in ("head", "main-head", "branch", "initial-manifest-sha256"):
            arguments += ["--" + option, "unused-parser-value"]
        return arguments

    def test_cli_defaults_to_strict_and_accepts_only_the_closed_explicit_policy(self):
        parser = runner.build_argument_parser()
        arguments = self.parser_arguments()
        self.assertEqual(parser.parse_args(arguments).main_build_policy, "strict")
        self.assertEqual(parser.parse_args(arguments + ["--main-build-policy", "reviewed-boundary-view-v2"]).main_build_policy,
                         "reviewed-boundary-view-v2")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(arguments + ["--main-build-policy", "all-compile-manifests"])

    def test_run_rejects_manifest_policy_mismatch_or_legacy_manifest_before_state_changes(self):
        for field in ("main_build_policy", "snapshot_policy", "argument_policy", "legacy_manifest"):
            with self.subTest(field=field):
                args, manifest = self.args_and_manifest()
                if field == "main_build_policy":
                    manifest["main_build_policy"] = "strict"
                elif field == "snapshot_policy":
                    manifest["guard_before"]["main_build"] = self.snapshot("strict")
                elif field == "argument_policy":
                    manifest["args"]["main_build_policy"] = "strict"
                else:
                    del manifest["main_build_policy"]
                self.write_manifest(manifest)
                with mock.patch.object(runner.secrets, "token_hex", side_effect=AssertionError("runtime began")), \
                        mock.patch.object(runner, "main_build_snapshot", side_effect=AssertionError("guard began")), \
                        self.assertRaises(RuntimeError):
                    runner.run(args)
                self.assertEqual(sorted(path.name for path in self.work.iterdir()), ["source-manifest.json"])

    def test_run_rejects_malformed_initial_snapshot_before_reading_results(self):
        args, manifest = self.args_and_manifest()
        manifest["guard_before"]["main_build"]["cache_audit"].pop(next(iter(self.cache_paths)))
        original = self.write_manifest(manifest)
        with self.assertRaisesRegex(RuntimeError, "snapshot is malformed"):
            runner.run(args)
        self.assertEqual((self.work / "source-manifest.json").read_bytes(), original)
        self.assertFalse((self.work / "results.json").exists())

    def test_each_guard_retains_all_seven_records_and_always_compares_to_preparation(self):
        initial = self.snapshot()
        immutable_initial = copy.deepcopy(initial)
        self.rewrite(self.cache)
        first, first_ref = runner.record_main_build_guard(self.work, 1, "before:compile", initial, self.root,
                                                        "reviewed-boundary-view-v2")
        self.rewrite(self.cache, b"third!")
        second, second_ref = runner.record_main_build_guard(self.work, 2, "after:compile", initial, self.root,
                                                          "reviewed-boundary-view-v2")
        self.assertTrue(first["accepted"] and second["accepted"])
        self.assertEqual(initial, immutable_initial)
        for reference in (first_ref, second_ref):
            path = self.work / reference["path"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), reference["sha256"])
            record = json.loads(path.read_text())
            self.assertEqual(record["initial_snapshot"], immutable_initial)
            self.assertEqual(record["guard_label"], reference["guard_label"])
            self.assertEqual(set(record["cache_audit"]), set(initial["cache_audit"]))
            for relative, audit in record["cache_audit"].items():
                self.assertEqual(audit["before"], initial["cache_audit"][relative])
                self.assertEqual(set(audit["after"]), {"sha256", "metadata"})
        self.assertNotEqual(first["cache_audit"], second["cache_audit"])

    def test_rejected_protected_file_change_still_retains_complete_current_cache_audit(self):
        protected = self.root / "unchanged-identity.app"
        protected.write_bytes(b"before")
        initial = self.snapshot()
        self.rewrite(protected)
        comparison, reference = runner.record_main_build_guard(self.work, 1, "after:compile", initial, self.root,
                                                             "reviewed-boundary-view-v2")
        record = json.loads((self.work / reference["path"]).read_text())
        self.assertFalse(comparison["accepted"])
        self.assertIn("Strict Main build metadata changed", record["reasons"])
        self.assertEqual(set(record["cache_audit"]), set(initial["cache_audit"]))
        self.assertEqual(record["current_snapshot"], self.snapshot())
        self.assertIsNone(record["capture_error"])

    def test_unsafe_capture_refuses_with_initial_records_and_explicit_unavailable_current(self):
        initial = self.snapshot()
        retained = self.parent / "retained-cache"
        self.cache.rename(retained)
        self.cache.symlink_to(retained)
        comparison, reference = runner.record_main_build_guard(self.work, 1, "before:compile", initial, self.root,
                                                             "reviewed-boundary-view-v2")
        record = json.loads((self.work / reference["path"]).read_text())
        self.assertFalse(comparison["accepted"])
        self.assertIsNone(record["current_snapshot"])
        self.assertIsNotNone(record["capture_error"])
        self.assertEqual(set(record["cache_audit"]), set(initial["cache_audit"]))
        for relative, audit in record["cache_audit"].items():
            self.assertEqual(audit["before"], initial["cache_audit"][relative])
            self.assertIsNone(audit["after"])
            self.assertEqual(audit["capture_error"], record["capture_error"])

    def test_guard_receipts_are_exclusive_and_invalid_identity_does_not_create_receipts(self):
        initial = self.snapshot()
        for sequence, label in ((0, "before:compile"), (True, "before:compile"), (1, "")):
            with self.assertRaisesRegex(RuntimeError, "guard identity"):
                runner.record_main_build_guard(self.work, sequence, label, initial, self.root, "reviewed-boundary-view-v2")
        self.assertFalse((self.work / "main-build-guards").exists())
        _, reference = runner.record_main_build_guard(self.work, 1, "before:compile", initial, self.root,
                                                    "reviewed-boundary-view-v2")
        original = (self.work / reference["path"]).read_bytes()
        with self.assertRaises(FileExistsError):
            runner.record_main_build_guard(self.work, 1, "after:compile", initial, self.root, "reviewed-boundary-view-v2")
        self.assertEqual((self.work / reference["path"]).read_bytes(), original)

    def test_default_strict_run_retains_refused_start_and_final_guard_without_starting_tools(self):
        args, manifest = self.args_and_manifest("strict")
        self.write_manifest(manifest, results=True)
        self.rewrite(self.cache)
        with mock.patch.object(runner.subprocess, "Popen", side_effect=AssertionError("tool launched")), \
                mock.patch.object(runner, "git_state", side_effect=AssertionError("other gate reached")), \
                self.assertRaisesRegex(RuntimeError, "Main build policy guard changed"):
            runner.run(args)
        state = json.loads((self.work / "results.json").read_text())
        self.assertEqual(state["status"], "HOLD")
        self.assertEqual(state["steps"], [])
        self.assertEqual([item["guard_label"] for item in state["main_build_guards"]], ["run-start", "cleanup-final"])
        self.assertTrue(all(not item["accepted"] for item in state["main_build_guards"]))
        for item in state["main_build_guards"]:
            record = json.loads((self.work / item["path"]).read_text())
            self.assertEqual(record["initial_snapshot"], manifest["guard_before"]["main_build"])
            self.assertEqual(record["cache_audit"], {})

    def test_accepted_cache_policy_cannot_hide_other_guard_domain_failure(self):
        args, manifest = self.args_and_manifest()
        args.repository = self.parent / "synthetic-candidate"
        manifest["args"]["repository"] = str(args.repository)
        manifest["guard_before"].update(main={"head": "original"}, candidate={"head": "original"},
                                       main_dotenv=None, operator={"node_id_sha256": "original"})
        self.write_manifest(manifest, results=True)
        self.rewrite(self.cache)
        with mock.patch.object(runner.subprocess, "Popen", side_effect=AssertionError("tool launched")), \
                mock.patch.object(runner, "git_state", return_value={"head": "original"}), \
                mock.patch.object(runner, "metadata", return_value=None), \
                mock.patch.object(runner, "operator_state", return_value={"node_id_sha256": "changed"}), \
                self.assertRaisesRegex(RuntimeError, "Main/candidate/stash/dotenv/operator guard changed"):
            runner.run(args)
        state = json.loads((self.work / "results.json").read_text())
        self.assertEqual(state["status"], "HOLD")
        self.assertEqual(state["steps"], [])
        self.assertEqual([item["guard_label"] for item in state["main_build_guards"]], ["run-start", "cleanup-final"])
        self.assertTrue(all(item["accepted"] for item in state["main_build_guards"]))
        self.assertIn("operator guard changed", state["final_guard_error"])

    def assert_manifest_rejection_keeps_both_guard_receipts(self, delete):
        args, manifest = self.args_and_manifest()
        original = self.write_manifest(manifest, results=True)
        manifest_path = self.work / "source-manifest.json"

        def mutate_after_manifest_pin(_length):
            if delete:
                manifest_path.unlink()
            else:
                manifest_path.write_bytes(b"{}\n")
            return "00" * 32

        expected_error = FileNotFoundError if delete else RuntimeError
        with mock.patch.object(runner.secrets, "token_hex", side_effect=mutate_after_manifest_pin), \
                mock.patch.object(runner.subprocess, "Popen") as launch, \
                mock.patch.object(runner, "git_state", side_effect=AssertionError("other gate reached")), \
                self.assertRaises(expected_error):
            runner.run(args)
        launch.assert_not_called()
        state = json.loads((self.work / "results.json").read_text())
        self.assertEqual(state["status"], "HOLD")
        self.assertEqual(state["steps"], [])
        self.assertEqual(state["source_manifest_sha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual([item["guard_label"] for item in state["main_build_guards"]], ["run-start", "cleanup-final"])
        for reference in state["main_build_guards"]:
            path = self.work / reference["path"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), reference["sha256"])
            record = json.loads(path.read_text())
            self.assertTrue(record["accepted"])
            self.assertEqual(record["initial_snapshot"], manifest["guard_before"]["main_build"])
            self.assertEqual(set(record["cache_audit"]), set(self.cache_paths))
        self.assertEqual(json.loads(original)["guard_before"], manifest["guard_before"])
        if delete:
            self.assertFalse(manifest_path.exists())
        else:
            self.assertEqual(manifest_path.read_bytes(), b"{}\n")

    def test_changed_manifest_after_initial_pin_retains_start_and_cleanup_audits(self):
        self.assert_manifest_rejection_keeps_both_guard_receipts(delete=False)

    def test_deleted_manifest_after_initial_pin_retains_start_and_cleanup_audits(self):
        self.assert_manifest_rejection_keeps_both_guard_receipts(delete=True)


if __name__ == "__main__":
    unittest.main()
