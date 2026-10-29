"""Containment regressions for the standalone qualification driver."""

import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("qualify_standalone.py")
SPEC = importlib.util.spec_from_file_location("qualify_standalone", MODULE_PATH)
qualifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qualifier)


class QualificationLocationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="arbor-qualification-location-")
        self.addCleanup(temporary.cleanup)
        self.sandbox = Path(temporary.name).resolve()
        self.ancestor = self.sandbox / "arbor"
        self.repository = self.ancestor / "tmp/worktrees/standalone"
        self.package = self.repository / "packages/arbor_persistence"
        script = self.package / "scripts/qualify_standalone.py"
        script.parent.mkdir(parents=True)
        script.write_text("# Isolated source-location fixture.\n")
        patch = mock.patch.object(qualifier, "__file__", str(script))
        patch.start()
        self.addCleanup(patch.stop)

        mix = self.sandbox / "pinned-mix"
        mix.write_text("#!/bin/sh\nexit 0\n")
        mix.chmod(0o700)
        self.args = SimpleNamespace(
            mix=mix, adapter="core", database=None, postgres_fixture=None
        )

    def mark_ancestor(self, relative):
        marker = self.ancestor / relative
        marker.parent.mkdir(parents=True)
        marker.write_text("# Isolated Arbor root marker.\n")

    def assert_rejects_source_work(self, work):
        self.assertFalse(work.exists())
        with self.assertRaisesRegex(
            RuntimeError, "^--work-dir must be outside all Arbor source checkouts$"
        ):
            qualifier.validate_locations(self.args, work)
        self.assertFalse(work.exists())

    def test_security_regression_rejects_work_in_canonical_ancestor_checkout(self):
        self.mark_ancestor("packages/arbor_kernel/mix.exs")
        self.assert_rejects_source_work(self.ancestor / "verification/qualification")

    def test_security_regression_rejects_work_in_legacy_ancestor_checkout(self):
        self.mark_ancestor("apps/arbor_kernel/mix.exs")
        self.assert_rejects_source_work(self.ancestor / "verification/qualification")

    def test_rejects_the_ancestor_source_root_itself(self):
        self.mark_ancestor("packages/arbor_kernel/mix.exs")
        with self.assertRaisesRegex(
            RuntimeError, "^--work-dir must be outside all Arbor source checkouts$"
        ):
            qualifier.validate_locations(self.args, self.ancestor)

    def test_rejects_work_in_the_nested_source_checkout_without_a_marker(self):
        self.assert_rejects_source_work(self.repository / "verification/qualification")

    def test_accepts_a_new_work_directory_outside_both_source_checkouts(self):
        self.mark_ancestor("packages/arbor_kernel/mix.exs")
        work = self.sandbox / "outside/qualification"
        self.assertFalse(work.exists())
        locations = qualifier.validate_locations(self.args, work)
        self.assertEqual(locations[:2], (self.package, self.repository))
        self.assertEqual(locations[2], self.args.mix)
        self.assertFalse(work.exists())


if __name__ == "__main__":
    unittest.main()
