"""Synthetic public metadata/lock gates; no Mix, VM, native compiler or Main access."""

import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "qualify_standalone.py"
SPEC = importlib.util.spec_from_file_location("support_qualifier_unit_source", SCRIPT)
QUALIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QUALIFIER)


def public_metadata():
    return {
        name: {
            "name": name,
            "app": name,
            "version": spec["version"],
            "licenses": ["MIT"],
            "description": "Synthetic public metadata",
            "links": {"GitHub": QUALIFIER.PUBLIC_SOURCE_URL},
            "requirements": [
                {"name": dependency, "app": dependency, "requirement": requirement,
                 "repository": "hexpm", "optional": False}
                for dependency, requirement in spec["requirements"].items()
            ],
        }
        for name, spec in QUALIFIER.PACKAGES.items()
    }


def root_lock():
    entries = [
        f'  "{name}": {{:hex, :{name}, "1.0.0", "' + "a" * 64 +
        '", [:mix], [], "hexpm", "' + "b" * 64 + '"},'
        for name in QUALIFIER.DEPENDENCIES
    ]
    return ("%{\n" + "\n".join(entries) + "\n}\n").encode()


class ArchiveMetadataTest(unittest.TestCase):
    def test_exact_two_archive_public_metadata_is_admitted(self):
        QUALIFIER.validate_archive_metadata(public_metadata())

    def test_omitting_kernel_archive_is_refused(self):
        metadata = public_metadata()
        del metadata["arbor_kernel"]
        with self.assertRaises(RuntimeError):
            QUALIFIER.validate_archive_metadata(metadata)

    def test_support_without_its_required_kernel_edge_is_refused(self):
        metadata = public_metadata()
        metadata["arbor_support"]["requirements"] = [
            value for value in metadata["arbor_support"]["requirements"]
            if value["name"] != "arbor_kernel"
        ]
        with self.assertRaises(RuntimeError):
            QUALIFIER.validate_archive_metadata(metadata)

    def test_wrong_kernel_version_is_refused(self):
        metadata = public_metadata()
        metadata["arbor_kernel"]["version"] = "0.1.0-dev"
        with self.assertRaises(RuntimeError):
            QUALIFIER.validate_archive_metadata(metadata)

    def test_optional_or_private_path_requirements_are_refused(self):
        for field, value in [("optional", True), ("path", "/private/unpublished"),
                             ("repository", "private")]:
            metadata = public_metadata()
            metadata["arbor_support"]["requirements"][0][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                QUALIFIER.validate_archive_metadata(metadata)

    def test_duplicate_and_extra_requirements_are_refused(self):
        metadata = public_metadata()
        metadata["arbor_kernel"]["requirements"][1] = copy.deepcopy(
            metadata["arbor_kernel"]["requirements"][0]
        )
        with self.assertRaises(RuntimeError):
            QUALIFIER.validate_archive_metadata(metadata)
        metadata = public_metadata()
        metadata["arbor_support"]["requirements"].append({
            "name": "arbor_kernel_runtime", "requirement": "~> 0.1", "optional": False,
            "repository": "hexpm"
        })
        with self.assertRaises(RuntimeError):
            QUALIFIER.validate_archive_metadata(metadata)

    def test_private_source_links_are_refused(self):
        metadata = public_metadata()
        metadata["arbor_kernel"]["links"] = {"GitHub": "http://private.invalid/source"}
        with self.assertRaises(RuntimeError):
            QUALIFIER.validate_archive_metadata(metadata)


class ProjectLockTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="support-lock-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.lock = QUALIFIER.selected_public_lock(root_lock())

    def project(self, name):
        project = self.work / name
        project.mkdir(parents=True)
        return project

    def test_selected_lock_keeps_exact_three_public_records(self):
        self.assertEqual(self.lock, root_lock())
        with self.assertRaises(RuntimeError):
            QUALIFIER.selected_public_lock(root_lock().replace(b'"jason":', b'"missing":'))
        with self.assertRaises(RuntimeError):
            QUALIFIER.selected_public_lock(root_lock().replace(b'"hexpm"', b'"private"', 1))

    def test_both_unpacked_projects_receive_the_same_exclusive_public_lock(self):
        for name in QUALIFIER.PACKAGES:
            project = self.project("unpacked/" + name)
            QUALIFIER.install_project_lock(project, self.lock)
            self.assertEqual((project / "mix.lock").read_bytes(), self.lock)
        QUALIFIER.check_project_locks(
            self.work, ["unpacked/" + name for name in QUALIFIER.PACKAGES], self.lock
        )

    def test_existing_and_symlink_locks_are_not_overwritten(self):
        project = self.project("existing")
        path = project / "mix.lock"
        path.write_bytes(b"retained original")
        with self.assertRaises(FileExistsError):
            QUALIFIER.install_project_lock(project, self.lock)
        self.assertEqual(path.read_bytes(), b"retained original")
        project = self.project("symlink")
        (project / "mix.lock").symlink_to(path)
        with self.assertRaises(FileExistsError):
            QUALIFIER.install_project_lock(project, self.lock)
        with self.assertRaises(RuntimeError):
            QUALIFIER.check_project_lock(project, self.lock)

    def test_later_lock_mutation_or_disappearance_is_refused(self):
        project = self.project("mutable")
        QUALIFIER.install_project_lock(project, self.lock)
        path = project / "mix.lock"
        path.write_bytes(b"malformed or different lock")
        with self.assertRaises(RuntimeError):
            QUALIFIER.check_project_lock(project, self.lock)
        path.rename(project / "retained-mutated-lock")
        with self.assertRaises(RuntimeError):
            QUALIFIER.check_project_lock(project, self.lock)

    def test_hidden_project_lock_is_still_verified_and_ambiguous_roots_refused(self):
        project = self.project("unpacked/arbor_support")
        QUALIFIER.install_project_lock(project, self.lock)
        hidden = self.work / "source-hidden/unpacked"
        hidden.mkdir(parents=True)
        project.rename(hidden / "arbor_support")
        QUALIFIER.check_project_locks(self.work, ["unpacked/arbor_support"], self.lock)
        self.project("unpacked/arbor_support")
        with self.assertRaises(RuntimeError):
            QUALIFIER.check_project_locks(self.work, ["unpacked/arbor_support"], self.lock)

    def test_hardlinked_lock_is_refused(self):
        project = self.project("hardlink")
        QUALIFIER.install_project_lock(project, self.lock)
        (project / "alias").hardlink_to(project / "mix.lock")
        with self.assertRaises(RuntimeError):
            QUALIFIER.check_project_lock(project, self.lock)


if __name__ == "__main__":
    unittest.main()
