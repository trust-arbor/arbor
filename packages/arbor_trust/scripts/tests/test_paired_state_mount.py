"""Owned synthetic filesystem fixtures only; no authority state or VM is used."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("state_mount_qualifier", SCRIPTS / "qualify_paired.py")
runner = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPTS))
try:
    import cold_support as support
    assert Path(support.__file__).resolve() == SCRIPTS / "cold_support.py"
    SPEC.loader.exec_module(runner)
finally:
    sys.path.pop(0)


class PairedStateMountTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="paired-state-mount-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve(strict=True)
        self.work = self.parent / "cold-work"
        self.work.mkdir(mode=0o700)
        self.source = self.work / "contexts/composed/state"
        self.source.mkdir(mode=0o700, parents=True)
        (self.source / "empty").mkdir(mode=0o700)
        (self.source / "nested").mkdir(mode=0o750)
        (self.source / "nested/value").write_bytes(b"original")
        os.chmod(self.source / "nested/value", 0o640)
        (self.source / ".hidden").write_bytes(b"hidden")
        os.chmod(self.source / ".hidden", 0o600)
        (self.source / "pending").write_bytes(b"0")
        self.initial = runner.state_tree_inventory(self.source)
        self.original_identity = runner.state_directory_identity(self.source)
        diagnostic = self.parent / "new-diagnostic"
        diagnostic.mkdir(mode=0o700)
        self.evidence = diagnostic / "state-mounts"
        self.events = []

    def idle(self):
        self.events.append("idle")

    def quiescent(self):
        self.events.append("quiescent")
        self.assertEqual((self.source / "pending").read_bytes(), b"0")

    def mount(self, label="candidate-conflict", idle=None, quiescent=None):
        return runner.mounted_state_copy(self.work, self.evidence, label,
                                         quiescent or self.quiescent, idle or self.idle)

    def assert_original(self):
        self.assertEqual(runner.state_directory_identity(self.source), self.original_identity)
        self.assertTrue(runner.pristine_state_matches(self.initial, runner.state_tree_inventory(self.source)))

    def receipt(self, label="candidate-conflict"):
        return json.loads((self.evidence / label / "receipt.json").read_text())

    def test_clone_preserves_complete_tree_hidden_files_empty_directories_and_modes(self):
        target = self.work / "copy"
        copied = runner.clone_state_tree(self.source, target)
        self.assertEqual(runner.state_content_projection(copied), runner.state_content_projection(self.initial))
        self.assertEqual(set(copied), set(self.initial))
        self.assertTrue((target / "empty").is_dir())
        self.assertEqual(stat.S_IMODE((target / "nested/value").stat().st_mode), 0o640)
        self.assertNotEqual(copied["."]["ino"], self.initial["."]["ino"])
        self.assertTrue(all(value["nlink"] == 1 for value in copied.values() if value["kind"] == "file"))
        self.assertEqual(runner.state_tree_inventory(self.source), self.initial)

    def test_clone_refuses_symlink_and_special_file_without_creating_copy(self):
        outside = self.parent / "outside"
        outside.write_bytes(b"untouched")
        bad = self.source / "unsafe"
        bad.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "single-link regular"):
            runner.clone_state_tree(self.source, self.work / "copy")
        self.assertEqual(outside.read_bytes(), b"untouched")
        self.assertFalse((self.work / "copy").exists())
        bad.unlink()
        os.mkfifo(bad)
        with self.assertRaisesRegex(RuntimeError, "single-link regular"):
            runner.state_tree_inventory(self.source)

    def test_clone_refuses_hardlink_alias_outside_state(self):
        os.link(self.source / "nested/value", self.parent / "alias")
        with self.assertRaisesRegex(RuntimeError, "single-link regular"):
            runner.clone_state_tree(self.source, self.work / "copy")
        self.assertFalse((self.work / "copy").exists())

    def test_exclusive_rename_never_replaces_even_an_empty_destination_directory(self):
        target = self.work / "occupied"
        target.mkdir(mode=0o700)
        identity = runner.state_directory_identity(target)
        with self.assertRaises(OSError):
            runner.rename_state_directory(self.source, target)
        self.assertEqual(runner.state_directory_identity(target), identity)
        self.assert_original()

    def test_success_retains_mutated_copy_and_restores_original_inode_and_bytes(self):
        with self.mount() as mounted:
            self.assertEqual(mounted["execution_root"], self.source)
            self.assertNotEqual(runner.state_directory_identity(self.source), self.original_identity)
            self.assertEqual(runner.state_directory_identity(self.evidence / "candidate-conflict/pristine-original"),
                             self.original_identity)
            (self.source / "nested/value").write_bytes(b"mutated")
            (self.source / "new-empty").mkdir(mode=0o700)
        self.assert_original()
        self.assertEqual((mounted["retained_root"] / "nested/value").read_bytes(), b"mutated")
        self.assertTrue((mounted["retained_root"] / "new-empty").is_dir())
        record = self.receipt()
        self.assertEqual(record["status"], "restored")
        self.assertEqual(record["initial_inventory"], self.initial)
        self.assertEqual(record["execution_root"], str(self.source))
        self.assertEqual(record["retained_root"], str(mounted["retained_root"]))
        self.assertEqual(mounted["receipt_sha256"], support.sha(mounted["receipt_path"].read_bytes()))
        self.assertLess(record["events"].index("park-original-intent"), record["events"].index("original-parked"))
        self.assertLess(record["events"].index("mount-copy-intent"), record["events"].index("copy-mounted"))

    def test_phase_failure_restores_original_and_retains_failure_branch(self):
        with self.assertRaisesRegex(ValueError, "phase failed"):
            with self.mount() as mounted:
                (self.source / "failure-evidence").write_bytes(b"retained")
                raise ValueError("phase failed")
        self.assert_original()
        self.assertEqual((mounted["retained_root"] / "failure-evidence").read_bytes(), b"retained")

    def test_interruption_immediately_after_original_rename_still_restores_by_inode(self):
        operation = runner.rename_state_directory
        calls = 0
        def interrupt(source, destination):
            nonlocal calls
            calls += 1
            operation(source, destination)
            if calls == 1:
                raise OSError("interrupted after original park")
        with mock.patch.object(runner, "rename_state_directory", side_effect=interrupt), \
                self.assertRaisesRegex(OSError, "after original park"):
            with self.mount():
                self.fail("phase must not begin")
        self.assert_original()
        self.assertTrue((self.evidence / "candidate-conflict/branch-copy").is_dir())

    def test_mount_rename_failure_before_or_after_effect_restores_original(self):
        for after, label in ((False, "candidate-conflict"), (True, "candidate-namespace_rollback_attack")):
            operation = runner.rename_state_directory
            calls = 0
            def interrupt(source, destination):
                nonlocal calls
                calls += 1
                if calls == 2 and not after:
                    raise OSError("mount failed")
                operation(source, destination)
                if calls == 2:
                    raise OSError("mount failed after effect")
            with self.subTest(after=after), mock.patch.object(runner, "rename_state_directory", side_effect=interrupt), \
                    self.assertRaisesRegex(OSError, "mount failed"):
                with self.mount(label):
                    self.fail("phase must not begin")
            self.assert_original()
            self.assertTrue((self.evidence / label / ("retained-state" if after else "branch-copy")).is_dir())

    def test_unexpected_canonical_occupant_is_not_overwritten_and_original_stays_parked(self):
        operation = runner.rename_state_directory
        calls = 0
        def occupy(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                self.source.mkdir(mode=0o700)
                (self.source / "foreign").write_bytes(b"do not overwrite")
            operation(source, destination)
        with mock.patch.object(runner, "rename_state_directory", side_effect=occupy), self.assertRaises(RuntimeError):
            with self.mount():
                self.fail("phase must not begin")
        self.assertEqual((self.source / "foreign").read_bytes(), b"do not overwrite")
        self.assertEqual(runner.state_directory_identity(self.evidence / "candidate-conflict/pristine-original"),
                         self.original_identity)
        self.assertEqual(self.receipt()["status"], "HOLD")

    def test_unexpected_retained_occupant_causes_hold_without_overwrite_or_deletion(self):
        with self.assertRaisesRegex(RuntimeError, "Retained state path occupied"):
            with self.mount() as mounted:
                mounted["retained_root"].mkdir(mode=0o700)
                (mounted["retained_root"] / "foreign").write_bytes(b"preserve")
        self.assertEqual((mounted["retained_root"] / "foreign").read_bytes(), b"preserve")
        self.assertEqual(runner.state_directory_identity(self.evidence / "candidate-conflict/pristine-original"),
                         self.original_identity)
        self.assertEqual(self.receipt()["status"], "HOLD")

    def test_nonquiescent_or_live_entry_is_refused_before_any_state_rename(self):
        def refuse():
            raise RuntimeError("not safe")
        for callbacks in ({"quiescent": refuse}, {"idle": refuse}):
            with self.subTest(callbacks=tuple(callbacks)), self.assertRaisesRegex(RuntimeError, "not safe"):
                with self.mount(**callbacks):
                    self.fail("phase must not begin")
            self.assert_original()
        self.assertFalse((self.evidence / "candidate-conflict").exists())

    def test_live_exit_refuses_unmount_and_keeps_original_parked(self):
        live = False
        def idle():
            if live:
                raise RuntimeError("owned process is live")
        with self.assertRaisesRegex(RuntimeError, "owned process is live"):
            with self.mount(idle=idle):
                live = True
        self.assertNotEqual(runner.state_directory_identity(self.source), self.original_identity)
        self.assertEqual(runner.state_directory_identity(self.evidence / "candidate-conflict/pristine-original"),
                         self.original_identity)
        self.assertEqual(self.receipt()["status"], "HOLD")

    def test_attack_pending_conflict_does_not_require_mutated_branch_quiescence_on_exit(self):
        with self.mount() as mounted:
            (self.source / "pending").write_bytes(b"1")
        self.assert_original()
        self.assertEqual((mounted["retained_root"] / "pending").read_bytes(), b"1")
        self.assertEqual(self.events.count("quiescent"), 2)

    def test_unsafe_mutated_branch_is_retained_and_original_restored_before_hold(self):
        outside = self.parent / "outside"
        outside.write_bytes(b"untouched")
        with self.assertRaisesRegex(RuntimeError, "Retained branch inventory unsafe"):
            with self.mount() as mounted:
                (self.source / "unsafe").symlink_to(outside)
        self.assert_original()
        self.assertTrue((mounted["retained_root"] / "unsafe").is_symlink())
        self.assertEqual(outside.read_bytes(), b"untouched")
        self.assertIn("retained_inventory_error", self.receipt())

    def test_two_operations_share_one_mounted_copy_without_intermediate_restore(self):
        with self.mount("actual-predecessor-rollback") as mounted:
            first_identity = runner.state_directory_identity(self.source)
            (self.source / "old-touched").write_bytes(b"actual-old-observation")
            self.assertEqual((self.source / "old-touched").read_bytes(), b"actual-old-observation")
            self.assertEqual(runner.state_directory_identity(self.source), first_identity)
            (self.source / "candidate-reopened").write_bytes(b"same branch")
        self.assert_original()
        self.assertTrue((mounted["retained_root"] / "old-touched").exists())
        self.assertTrue((mounted["retained_root"] / "candidate-reopened").exists())

    def test_namespace_only_replacement_changes_only_mounted_selected_namespace(self):
        authority = self.source / "authority"
        authority.mkdir(mode=0o700)
        for name in ("ns_selected", "ns_other"):
            (authority / name).mkdir(mode=0o700)
            (authority / name / "value").write_bytes(name.encode())
        self.initial = runner.state_tree_inventory(self.source)
        snapshot = self.work / "pre-seed"
        snapshot.mkdir(mode=0o700)
        (snapshot / "value").write_bytes(b"old selected")
        with self.mount("candidate-namespace_rollback_attack") as mounted:
            preserved = mounted["retained_root"].parent / "selected-current"
            runner.rename_state_directory(authority / "ns_selected", preserved)
            runner.clone_state_tree(snapshot, authority / "ns_selected")
            self.assertEqual((authority / "ns_other/value").read_bytes(), b"ns_other")
        self.assert_original()
        self.assertEqual((mounted["retained_root"] / "authority/ns_selected/value").read_bytes(), b"old selected")
        self.assertEqual((preserved / "value").read_bytes(), b"ns_selected")

    def test_closed_labels_evidence_overlap_and_cross_device_are_refused(self):
        for evidence, label in ((self.evidence, "../escape"), (self.source / "state-mounts", "candidate-conflict")):
            with self.subTest(label=label), self.assertRaises(RuntimeError):
                with runner.mounted_state_copy(self.work, evidence, label, self.quiescent, self.idle):
                    self.fail("phase must not begin")
        with self.assertRaisesRegex(RuntimeError, "Cross-device"):
            runner.owned_state_directory(self.source, self.source.stat().st_dev + 1)
        self.assert_original()

    def test_unsupported_exclusive_rename_fails_closed_without_plain_rename_fallback(self):
        with mock.patch.object(runner.sys, "platform", "unsupported"), \
                mock.patch.object(runner.os, "rename", side_effect=AssertionError("unsafe fallback")), \
                self.assertRaisesRegex(RuntimeError, "unavailable on this platform"):
            runner.rename_state_directory(self.source, self.work / "copy")
        self.assert_original()

    def assert_one_shot_cleanup_audit_failure_restores(self, stage):
        label = "candidate-conflict"
        failed = False
        fsync = runner.os.fsync
        def interrupt(fd):
            nonlocal failed
            if not failed and self.receipt(label)["events"][-1] == stage:
                failed = True
                raise OSError("one-shot cleanup audit failure")
            return fsync(fd)
        failure = None
        with mock.patch.object(runner.os, "fsync", side_effect=interrupt):
            try:
                with self.mount(label) as mounted:
                    (self.source / "failure-evidence").write_bytes(stage.encode())
            except BaseException as error:
                failure = error
        self.assertTrue(failed)
        self.assert_original()
        self.assertIsInstance(failure, RuntimeError)
        self.assertIn("State restored with cleanup errors", str(failure))
        self.assertEqual((mounted["retained_root"] / "failure-evidence").read_bytes(), stage.encode())
        record = self.receipt(label)
        self.assertEqual(record["status"], "HOLD")
        self.assertTrue(record["original_restored"])
        self.assertTrue(any(error["operation"] == "audit:" + stage for error in record["cleanup_errors"]))

    def test_one_shot_retain_intent_audit_failure_still_restores(self):
        self.assert_one_shot_cleanup_audit_failure_restores("retain-mutated-copy-intent")

    def test_one_shot_retained_progress_audit_failure_still_restores(self):
        self.assert_one_shot_cleanup_audit_failure_restores("mutated-copy-retained")

    def test_one_shot_restore_intent_audit_failure_still_restores(self):
        self.assert_one_shot_cleanup_audit_failure_restores("restore-original-intent")

    def test_persistent_cleanup_fsync_failure_restores_before_hold(self):
        cleanup = False
        fsync = runner.os.fsync
        def interrupt(fd):
            if cleanup:
                raise OSError("persistent cleanup fsync failure")
            return fsync(fd)
        failure = None
        with mock.patch.object(runner.os, "fsync", side_effect=interrupt):
            try:
                with self.mount() as mounted:
                    (self.source / "failure-evidence").write_bytes(b"retained")
                    cleanup = True
            except BaseException as error:
                failure = error
        self.assert_original()
        self.assertIsInstance(failure, RuntimeError)
        self.assertIn("State restored with cleanup errors", str(failure))
        self.assertEqual((mounted["retained_root"] / "failure-evidence").read_bytes(), b"retained")
        self.assertEqual(self.receipt()["status"], "HOLD")
        self.assertTrue(self.receipt()["original_restored"])

    def test_persistent_truncating_receipt_write_failure_does_not_prevent_restore(self):
        cleanup = False
        path_open = Path.open
        receipt_path = self.evidence / "candidate-conflict/receipt.json"
        class BrokenOutput:
            def __init__(self, output):
                self.output = output
            def __enter__(self):
                return self
            def __exit__(self, *_args):
                self.output.close()
            def write(self, _value):
                raise OSError("persistent truncated audit write")
        def interrupt(path, *args, **kwargs):
            output = path_open(path, *args, **kwargs)
            mode = args[0] if args else kwargs.get("mode", "r")
            return BrokenOutput(output) if cleanup and path == receipt_path and mode == "w" else output
        failure = None
        with mock.patch.object(Path, "open", new=interrupt):
            try:
                with self.mount() as mounted:
                    (self.source / "failure-evidence").write_bytes(b"retained")
                    cleanup = True
            except BaseException as error:
                failure = error
        self.assert_original()
        self.assertIsInstance(failure, RuntimeError)
        self.assertIn("State restored with cleanup errors", str(failure))
        self.assertEqual((mounted["retained_root"] / "failure-evidence").read_bytes(), b"retained")
        self.assertEqual(receipt_path.read_bytes(), b"", "failed audit is incomplete, never success evidence")

    def test_post_effect_retain_rename_exception_reobserves_and_restores_original(self):
        operation = runner.rename_state_directory
        failed = False
        def interrupt(source, destination):
            nonlocal failed
            operation(source, destination)
            if destination.name == "retained-state" and not failed:
                failed = True
                raise OSError("retain completed then raised")
        failure = None
        with mock.patch.object(runner, "rename_state_directory", side_effect=interrupt):
            try:
                with self.mount() as mounted:
                    (self.source / "failure-evidence").write_bytes(b"retained")
            except BaseException as error:
                failure = error
        self.assertTrue(failed)
        self.assert_original()
        self.assertIsInstance(failure, RuntimeError)
        self.assertIn("State restored with cleanup errors", str(failure))
        self.assertEqual((mounted["retained_root"] / "failure-evidence").read_bytes(), b"retained")
        self.assertTrue(self.receipt()["original_restored"])
        self.assertTrue(any(error["operation"] == "retain-mutated-copy" for error in self.receipt()["cleanup_errors"]))

    def test_retained_inventory_interruption_holds_only_after_original_is_restored(self):
        inventory = runner.state_tree_inventory
        def interrupt(path):
            if path.name == "retained-state":
                raise KeyboardInterrupt("retained inventory interrupted")
            return inventory(path)
        failure = None
        with mock.patch.object(runner, "state_tree_inventory", side_effect=interrupt):
            try:
                with self.mount() as mounted:
                    (self.source / "failure-evidence").write_bytes(b"retained")
            except BaseException as error:
                failure = error
        self.assert_original()
        self.assertIsInstance(failure, RuntimeError)
        self.assertIn("Retained branch inventory unsafe", str(failure))
        self.assertEqual((mounted["retained_root"] / "failure-evidence").read_bytes(), b"retained")
        self.assertEqual(self.receipt()["status"], "HOLD")
        self.assertTrue(self.receipt()["original_restored"])
        self.assertIn("KeyboardInterrupt", self.receipt()["retained_inventory_error"])


if __name__ == "__main__":
    unittest.main()
