"""Temp-only named-nine successor tests; no real Main, tools, or BEAM access."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("nine_policy_helper", SCRIPTS / "cold_support.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
RUNNER_SPEC = importlib.util.spec_from_file_location("nine_policy_qualifier", SCRIPTS / "qualify_paired.py")
runner = importlib.util.module_from_spec(RUNNER_SPEC)
sys.path.insert(0, str(SCRIPTS))
try:
    RUNNER_SPEC.loader.exec_module(runner)
finally:
    sys.path.pop(0)

NINE = "reviewed-boundary-view-v2-nine"
SEVEN = "reviewed-boundary-view-v2"
ORIGINAL_SEVEN = (
    "dev/lib/arbor_support/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_kernel/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_signals/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_oauth/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_capabilities_oidc/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_capabilities/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_capabilities_signals/.mix/compile.boundary_view_v2",
)
EXTRA = (
    "dev/lib/arbor_trust/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_historian/.mix/compile.boundary_view_v2",
)


class NamedNineMainBuildPolicyTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="named-nine-policy-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve(strict=True)
        self.root = self.parent / "_build"
        self.root.mkdir(mode=0o700)
        # Construct the public-input fixture independently of the new helper API.
        for relative in ORIGINAL_SEVEN + EXTRA:
            path = self.root / relative
            path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            path.write_bytes(b"before")

    def snapshot(self, name=NINE):
        return policy.main_build_snapshot(self.root, name)

    def rewrite(self, path, content=b"after!"):
        before = path.stat()
        path.write_bytes(content)
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000))

    def test_closed_rosters_preserve_original_seven_and_add_only_two_literal_slots(self):
        expected_seven = (
            "dev/lib/arbor_support/.mix/compile.boundary_view_v2",
            "dev/lib/arbor_kernel/.mix/compile.boundary_view_v2",
            "dev/lib/arbor_signals/.mix/compile.boundary_view_v2",
            "dev/lib/arbor_oauth/.mix/compile.boundary_view_v2",
            "dev/lib/arbor_capabilities_oidc/.mix/compile.boundary_view_v2",
            "dev/lib/arbor_capabilities/.mix/compile.boundary_view_v2",
            "dev/lib/arbor_capabilities_signals/.mix/compile.boundary_view_v2",
        )
        self.assertEqual(policy.REVIEWED_BOUNDARY_VIEWS, expected_seven)
        self.assertEqual(policy.REVIEWED_BOUNDARY_VIEWS_NINE, expected_seven + EXTRA)
        self.assertEqual(policy.MAIN_BUILD_POLICIES, ("strict", SEVEN, NINE))
        with self.assertRaises(RuntimeError):
            self.snapshot("reviewed-boundary-view-v2-all")

    def test_new_policy_accepts_all_nine_same_size_rewrites_and_retains_full_nonaliasing_audit(self):
        before = self.snapshot()
        unchanged = copy.deepcopy(before)
        for relative in policy.REVIEWED_BOUNDARY_VIEWS_NINE:
            self.rewrite(self.root / relative)
        after = self.snapshot()
        result = policy.compare_main_build_snapshots(before, after)
        self.assertTrue(result["accepted"])
        self.assertEqual(before, unchanged)
        self.assertEqual(set(result["cache_audit"]), set(policy.REVIEWED_BOUNDARY_VIEWS_NINE))
        for relative, audit in result["cache_audit"].items():
            self.assertEqual(audit["before"], before["cache_audit"][relative])
            self.assertEqual(audit["after"], after["cache_audit"][relative])
            self.assertIn("sha256", audit["changed_fields"])
        result["cache_audit"][EXTRA[0]]["before"]["metadata"]["size"] += 1
        self.assertEqual(before, unchanged)

    def test_old_seven_policy_still_denies_each_extra_slot_rewrite(self):
        for relative in EXTRA:
            with self.subTest(path=relative):
                before = self.snapshot(SEVEN)
                self.rewrite(self.root / relative)
                result = policy.compare_main_build_snapshots(before, self.snapshot(SEVEN))
                self.assertFalse(result["accepted"])
                self.assertIn("Strict Main build metadata changed", result["reasons"])
                self.assertEqual(set(result["cache_audit"]), set(policy.REVIEWED_BOUNDARY_VIEWS))

    def test_default_strict_still_denies_each_extra_slot_rewrite(self):
        for relative in EXTRA:
            with self.subTest(path=relative):
                before = policy.main_build_snapshot(self.root)
                self.rewrite(self.root / relative)
                result = policy.compare_main_build_snapshots(before, policy.main_build_snapshot(self.root))
                self.assertFalse(result["accepted"])
                self.assertEqual(result["cache_audit"], {})

    def test_time_only_extra_deltas_are_recorded_under_nine_without_rebasing(self):
        before = self.snapshot()
        after = copy.deepcopy(before)
        for relative in EXTRA:
            for field in ("mtime_ns", "ctime_ns"):
                after["cache_audit"][relative]["metadata"][field] += 1
        result = policy.compare_main_build_snapshots(before, after)
        self.assertTrue(result["accepted"])
        self.assertEqual(set(result["cache_audit"]), set(policy.REVIEWED_BOUNDARY_VIEWS_NINE))
        self.assertNotEqual(before, after)

    def test_every_new_slot_identity_field_remains_strict(self):
        before = self.snapshot()
        for relative in EXTRA:
            for field in ("dev", "ino", "mode", "uid", "gid", "size", "nlink"):
                with self.subTest(path=relative, field=field):
                    after = copy.deepcopy(before)
                    after["cache_audit"][relative]["metadata"][field] += stat.S_IWGRP if field == "mode" else 1
                    self.assertFalse(policy.compare_main_build_snapshots(before, after)["accepted"])

    def test_actual_new_slot_replacement_is_rejected_even_at_same_size(self):
        before = self.snapshot()
        path = self.root / EXTRA[0]
        replacement = self.parent / "replacement"
        replacement.write_bytes(b"before")
        os.replace(replacement, path)
        result = policy.compare_main_build_snapshots(before, self.snapshot())
        self.assertFalse(result["accepted"])
        self.assertIn("Reviewed cache identity changed: " + EXTRA[0], result["reasons"])

    def test_new_slot_and_ancestor_symlinks_are_rejected_without_following(self):
        path = self.root / EXTRA[0]
        retained = self.parent / "retained-cache"
        path.rename(retained)
        path.symlink_to(retained)
        with self.assertRaises((RuntimeError, OSError)):
            self.snapshot()
        path.unlink()
        retained.rename(path)
        directory = path.parent
        retained_directory = self.parent / "retained-mix"
        directory.rename(retained_directory)
        directory.symlink_to(retained_directory, target_is_directory=True)
        with self.assertRaises((RuntimeError, OSError)):
            self.snapshot()

    def test_actual_new_slot_hardlink_is_rejected(self):
        path = self.root / EXTRA[1]
        os.link(path, self.parent / "external-alias")
        with self.assertRaisesRegex(RuntimeError, "single-link"):
            self.snapshot()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFO support")
    def test_new_slot_fifo_is_rejected_without_blocking_read(self):
        path = self.root / EXTRA[1]
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises((RuntimeError, OSError)):
            self.snapshot()

    def test_missing_new_slot_fails_new_policy_but_old_policy_does_not_require_it(self):
        (self.root / EXTRA[1]).unlink()
        with self.assertRaises(RuntimeError):
            self.snapshot()
        self.assertEqual(set(self.snapshot(SEVEN)["cache_audit"]), set(policy.REVIEWED_BOUNDARY_VIEWS))

    def test_malformed_seven_under_nine_or_tenth_audit_is_rejected(self):
        before = self.snapshot()
        for relative in EXTRA:
            after = copy.deepcopy(before)
            del after["cache_audit"][relative]
            self.assertFalse(policy.compare_main_build_snapshots(before, after)["accepted"])
        seven = self.snapshot(SEVEN)
        seven["policy"] = NINE
        self.assertFalse(policy.compare_main_build_snapshots(before, seven)["accepted"])
        after = copy.deepcopy(before)
        after["cache_audit"]["dev/lib/arbor_other/.mix/compile.boundary_view_v2"] = copy.deepcopy(after["cache_audit"][EXTRA[0]])
        self.assertFalse(policy.compare_main_build_snapshots(before, after)["accepted"])

    def test_policy_mismatch_cannot_reclassify_retained_seven_hold(self):
        before = self.snapshot(SEVEN)
        saved = copy.deepcopy(before)
        self.rewrite(self.root / EXTRA[0])
        held = policy.compare_main_build_snapshots(before, self.snapshot(SEVEN))
        self.assertFalse(held["accepted"])
        changed_policy = policy.compare_main_build_snapshots(before, self.snapshot())
        self.assertFalse(changed_policy["accepted"])
        self.assertIn("Main build policy changed", changed_policy["reasons"])
        self.assertEqual(before, saved)
        self.assertFalse(held["accepted"])

    def test_tenth_cache_other_manifests_beams_apps_priv_and_directories_stay_strict(self):
        for relative in ("dev/lib/arbor_other/.mix/compile.boundary_view_v2",
                         "dev/lib/arbor_trust/.mix/compile.boundary_view_v3",
                         "dev/lib/arbor_historian/.mix/compile.elixir",
                         "dev/lib/arbor_trust/ebin/Elixir.Example.beam",
                         "dev/lib/arbor_historian/ebin/arbor_historian.app",
                         "dev/lib/arbor_trust/priv/native.so"):
            with self.subTest(path=relative):
                path = self.root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"before")
                before = self.snapshot()
                self.rewrite(path)
                self.assertFalse(policy.compare_main_build_snapshots(before, self.snapshot())["accepted"])
        before = self.snapshot()
        directory = (self.root / EXTRA[1]).parent
        os.chmod(directory, stat.S_IMODE(directory.stat().st_mode) ^ stat.S_IXGRP)
        self.assertFalse(policy.compare_main_build_snapshots(before, self.snapshot())["accepted"])

    def test_all_nine_reads_are_fd_relative_nofollow_nonblocking(self):
        real_open = os.open
        opened = []
        def observe(name, flags, *args, **kwargs):
            if name == "compile.boundary_view_v2":
                opened.append((flags, kwargs.get("dir_fd")))
            return real_open(name, flags, *args, **kwargs)
        with mock.patch.object(policy.os, "open", side_effect=observe):
            self.snapshot()
        self.assertEqual(len(opened), 9)
        self.assertTrue(all(flags & os.O_NOFOLLOW and flags & os.O_NONBLOCK and type(fd) is int
                            for flags, fd in opened))

    def test_explicit_nine_parser_and_each_guard_keep_all_initial_and_current_records(self):
        work = self.parent / "attempt"
        work.mkdir(mode=0o700)
        arguments = ["--prepare"]
        for option in ("repository", "main-root", "work-dir", "fixtures-root", "mix", "erlang-root", "elixir-root",
                       "hex-archive", "cc", "make", "rebar3", "deps-source-cache", "initial-manifest", "sdk-root", "developer-dir"):
            arguments += ["--" + option, str(self.parent / option)]
        for option in ("head", "main-head", "branch", "initial-manifest-sha256"):
            arguments += ["--" + option, "unused-parser-value"]
        parser = runner.build_argument_parser()
        self.assertEqual(parser.parse_args(arguments).main_build_policy, "strict")
        self.assertEqual(parser.parse_args(arguments + ["--main-build-policy", NINE]).main_build_policy, NINE)
        initial = self.snapshot()
        saved = copy.deepcopy(initial)
        self.rewrite(self.root / EXTRA[0])
        first, first_ref = runner.record_main_build_guard(work, 1, "before:compile", initial, self.root, NINE)
        self.rewrite(self.root / EXTRA[1])
        second, second_ref = runner.record_main_build_guard(work, 2, "after:compile", initial, self.root, NINE)
        self.assertTrue(first["accepted"] and second["accepted"])
        self.assertEqual(initial, saved)
        for reference in (first_ref, second_ref):
            path = work / reference["path"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), reference["sha256"])
            record = json.loads(path.read_text())
            self.assertEqual(record["initial_snapshot"], saved)
            self.assertEqual(set(record["cache_audit"]), set(policy.REVIEWED_BOUNDARY_VIEWS_NINE))
            for relative, audit in record["cache_audit"].items():
                self.assertEqual(audit["before"], initial["cache_audit"][relative])
                self.assertEqual(set(audit["after"]), {"sha256", "metadata"})
        with self.assertRaises(FileExistsError):
            runner.record_main_build_guard(work, 1, "after:compile", initial, self.root, NINE)


if __name__ == "__main__":
    unittest.main()
