"""Synthetic filesystem tests only. Import/run after explicit review approval."""
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("prototype_cold_support", Path(__file__).resolve().parents[1] / "cold_support.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class MainBuildPolicyTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="main-build-policy-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve(strict=True)
        self.root = self.parent / "_build"
        self.root.mkdir(mode=0o700)
        for relative in policy.REVIEWED_BOUNDARY_VIEWS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.write_bytes(b"before")
        self.cache = self.root / policy.REVIEWED_BOUNDARY_VIEWS[0]

    def reviewed(self):
        return policy.main_build_snapshot(self.root, "reviewed-boundary-view-v2")

    def rewrite(self, path, value=b"after!"):
        old = path.stat()
        path.write_bytes(value)
        # No timing sleeps: a deterministic timestamp change accompanies a
        # same-length content mutation, including on coarse filesystems.
        os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns + 1_000_000))

    def test_default_strict_retains_legacy_fingerprint_and_rejects_cache_rewrite(self):
        before = policy.main_build_snapshot(self.root)
        self.assertEqual(before["policy"], "strict")
        self.assertEqual(before["strict"], policy.build_metadata(self.root))
        self.rewrite(self.cache)
        result = policy.compare_main_build_snapshots(before, policy.main_build_snapshot(self.root))
        self.assertFalse(result["accepted"])
        self.assertEqual(result["cache_audit"], {})

    def test_unchanged_reviewed_tree_is_accepted_with_all_seven_audits(self):
        before = self.reviewed()
        result = policy.compare_main_build_snapshots(before, self.reviewed())
        self.assertTrue(result["accepted"])
        self.assertEqual(set(result["cache_audit"]), set(policy.REVIEWED_BOUNDARY_VIEWS))
        self.assertTrue(all(item["changed_fields"] == [] for item in result["cache_audit"].values()))

    def test_exact_existing_same_size_cache_content_and_time_delta_is_recorded(self):
        before = self.reviewed()
        self.rewrite(self.cache)
        after = self.reviewed()
        original_before, original_after = copy.deepcopy(before), copy.deepcopy(after)
        result = policy.compare_main_build_snapshots(before, after)
        self.assertTrue(result["accepted"])
        self.assertEqual(before["strict"], after["strict"])
        audit = result["cache_audit"][policy.REVIEWED_BOUNDARY_VIEWS[0]]
        self.assertEqual(audit["before"]["sha256"], hashlib.sha256(b"before").hexdigest())
        self.assertEqual(audit["after"]["sha256"], hashlib.sha256(b"after!").hexdigest())
        self.assertIn("sha256", audit["changed_fields"])
        self.assertEqual(set(audit["before"]["metadata"]), {"kind", *policy._STAT_FIELDS})
        self.assertEqual(before, original_before)
        self.assertEqual(after, original_after)
        audit["before"]["metadata"]["size"] = 999
        self.assertEqual(before, original_before, "audit results must not rebase or alias initial snapshots")

    def test_time_only_cache_delta_is_accepted_without_rebasing(self):
        before = self.reviewed()
        after = copy.deepcopy(before)
        for field in ("mtime_ns", "ctime_ns"):
            after["cache_audit"][policy.REVIEWED_BOUNDARY_VIEWS[0]]["metadata"][field] += 1
        self.assertTrue(policy.compare_main_build_snapshots(before, after)["accepted"])
        self.assertNotEqual(before, after)

    def test_compiled_application_native_priv_static_and_other_manifests_remain_strict(self):
        paths = [
            "dev/lib/example/ebin/Elixir.Example.beam",
            "dev/lib/example/ebin/example.app",
            "dev/lib/example/priv/native.so",
            "dev/lib/example/priv/static/site.css",
            "dev/lib/example/priv/seed.json",
            "dev/lib/arbor_support/.mix/compile.elixir",
            "dev/lib/arbor_unreviewed/.mix/compile.boundary_view_v2",
        ]
        for relative in paths:
            with self.subTest(relative=relative):
                path = self.root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"before")
                before = self.reviewed()
                self.rewrite(path)
                result = policy.compare_main_build_snapshots(before, self.reviewed())
                self.assertFalse(result["accepted"])

    def test_new_file_and_removed_file_are_rejected(self):
        before = self.reviewed()
        extra = self.root / "dev/lib/arbor_support/.mix/compile.boundary_view_v3"
        extra.write_bytes(b"new")
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])
        # Even after removing the new file, changed directory metadata must not
        # be silently rebased to the original inventory.
        extra.unlink()
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])

    def test_removed_existing_protected_file_is_rejected(self):
        path = self.root / "existing.app"
        path.write_bytes(b"before")
        before = self.reviewed()
        path.unlink()
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])

    def test_cache_size_and_mode_changes_are_rejected(self):
        before = self.reviewed()
        self.rewrite(self.cache, b"different-length")
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])
        before = self.reviewed()
        os.chmod(self.cache, stat.S_IMODE(self.cache.stat().st_mode) ^ stat.S_IWGRP)
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])

    def test_each_cache_identity_field_is_checked_even_if_digest_is_unchanged(self):
        before = self.reviewed()
        for field in ("dev", "ino", "mode", "uid", "gid", "size", "nlink"):
            with self.subTest(field=field):
                after = copy.deepcopy(before)
                increment = stat.S_IWGRP if field == "mode" else 1
                after["cache_audit"][policy.REVIEWED_BOUNDARY_VIEWS[0]]["metadata"][field] += increment
                self.assertFalse(policy.compare_main_build_snapshots(before, after)["accepted"])

    def test_symlinked_cache_or_cache_ancestor_is_rejected_without_following(self):
        real_cache = self.cache.with_name("retained-cache")
        self.cache.rename(real_cache)
        self.cache.symlink_to(real_cache)
        with self.assertRaises((RuntimeError, OSError)):
            self.reviewed()
        self.cache.unlink()
        real_cache.rename(self.cache)
        directory = self.cache.parent
        retained = directory.with_name("retained-mix")
        directory.rename(retained)
        directory.symlink_to(retained, target_is_directory=True)
        with self.assertRaises((RuntimeError, OSError)):
            self.reviewed()

    def test_root_symlink_and_missing_cache_are_rejected(self):
        alias = self.parent / "alias-build"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((RuntimeError, OSError)):
            policy.main_build_snapshot(alias, "reviewed-boundary-view-v2")
        self.cache.unlink()
        with self.assertRaises((RuntimeError, OSError)):
            self.reviewed()

    def test_symlinked_ancestor_above_build_is_rejected(self):
        alias_parent = self.parent / "alias-parent"
        alias_parent.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symlinked ancestor"):
            policy.main_build_snapshot(alias_parent / "_build", "reviewed-boundary-view-v2")

    def test_cache_with_actual_hardlink_alias_outside_build_is_rejected(self):
        outside_alias = self.parent / "outside-cache-alias"
        os.link(self.cache, outside_alias)
        self.assertEqual(self.cache.stat().st_nlink, 2)
        with self.assertRaisesRegex(RuntimeError, "single-link"):
            self.reviewed()

    def test_noncache_symlink_target_and_directory_metadata_remain_strict(self):
        link = self.root / "resource-link"
        link.symlink_to("first-target")
        before = self.reviewed()
        link.unlink()
        link.symlink_to("second-target")
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])
        before = self.reviewed()
        directory = self.root / "dev"
        os.chmod(directory, stat.S_IMODE(directory.stat().st_mode) ^ stat.S_IXGRP)
        self.assertFalse(policy.compare_main_build_snapshots(before, self.reviewed())["accepted"])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires POSIX FIFO support")
    def test_special_file_in_cache_slot_is_rejected_without_reading(self):
        self.cache.unlink()
        os.mkfifo(self.cache)
        with self.assertRaises((RuntimeError, OSError)):
            self.reviewed()

    def test_cache_opens_are_fd_relative_nofollow_and_nonblocking(self):
        real_open = os.open
        opens = []
        def observe(name, flags, *args, **kwargs):
            if name == "compile.boundary_view_v2":
                opens.append((flags, kwargs.get("dir_fd")))
            return real_open(name, flags, *args, **kwargs)
        with mock.patch.object(policy.os, "open", side_effect=observe):
            self.reviewed()
        self.assertEqual(len(opens), 7)
        self.assertTrue(all(flags & os.O_NOFOLLOW and flags & os.O_NONBLOCK and type(fd) is int for flags, fd in opens))

    def test_short_growing_or_concurrently_changed_cache_reads_fail_closed(self):
        with mock.patch.object(policy.os, "read", side_effect=[b"x", b""]):
            with self.assertRaisesRegex(RuntimeError, "length changed"):
                self.reviewed()
        with mock.patch.object(policy.os, "read", return_value=b"too-long"):
            with self.assertRaisesRegex(RuntimeError, "grew during read"):
                self.reviewed()
        real_read = os.read
        touched = False
        def read_and_touch(fd, count):
            nonlocal touched
            data = real_read(fd, count)
            if data and not touched:
                current = os.fstat(fd)
                os.utime(fd, ns=(current.st_atime_ns, current.st_mtime_ns + 1_000_000))
                touched = True
            return data
        with mock.patch.object(policy.os, "read", side_effect=read_and_touch):
            with self.assertRaisesRegex(RuntimeError, "changed during read"):
                self.reviewed()

    def test_unknown_policy_policy_changes_and_malformed_audits_are_rejected(self):
        with self.assertRaises(RuntimeError):
            policy.main_build_snapshot(self.root, "all-compile-manifests")
        before = self.reviewed()
        self.assertFalse(policy.compare_main_build_snapshots(before, policy.main_build_snapshot(self.root))["accepted"])
        for changed in ("missing", "extra", "type", "sha"):
            with self.subTest(changed=changed):
                after = copy.deepcopy(before)
                path = policy.REVIEWED_BOUNDARY_VIEWS[0]
                if changed == "missing":
                    del after["cache_audit"][path]
                elif changed == "extra":
                    after["cache_audit"]["dev/lib/extra/.mix/compile.boundary_view_v2"] = after["cache_audit"][path]
                elif changed == "type":
                    after["cache_audit"][path]["metadata"]["kind"] = "symlink"
                else:
                    after["cache_audit"][path]["sha256"] = "not-a-sha256"
                self.assertFalse(policy.compare_main_build_snapshots(before, after)["accepted"])


if __name__ == "__main__":
    unittest.main()
