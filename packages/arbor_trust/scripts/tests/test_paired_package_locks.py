"""Synthetic archive/lock checks only; never compile packages or access Main."""
import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_lock_qualifier", SCRIPTS / "qualify_paired.py")
runner = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPTS))
try:
    import cold_support as support
    assert Path(support.__file__).resolve() == SCRIPTS / "cold_support.py"
    SPEC.loader.exec_module(runner)
finally:
    sys.path.pop(0)


class PairedPackageLocksTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="paired-package-locks-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve(strict=True)
        dependencies = set().union(*(context[1] for context in runner.CONTEXTS.values()))
        self.records = {name: ('"' + name + '": {:hex, :' + name + ', "1.0.0", "public-pin", [], [], "hexpm", "lock"},').encode()
                        for name in dependencies}

    def context_lock(self, context):
        return runner.make_lock(self.records, runner.CONTEXTS[context][1])

    def package(self, name="package"):
        path = self.root / name
        path.mkdir(mode=0o700)
        return path

    def archive(self, checksum_valid=True):
        published = {"lib/sample.ex": b"defmodule Sample do\nend\n", "mix.exs": b"# synthetic source only\n"}
        contents_bytes = io.BytesIO()
        with tarfile.open(fileobj=contents_bytes, mode="w:gz") as contents:
            for name, data in published.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                contents.addfile(member, io.BytesIO(data))
        compressed = contents_bytes.getvalue()
        metadata = b"synthetic public metadata"
        checksum = hashlib.sha256(b"3" + metadata + compressed).hexdigest().encode()
        if not checksum_valid:
            checksum = b"0" * 64
        path = self.root / "sample.tar"
        with tarfile.open(path, mode="w:") as outer:
            for name, data in (("VERSION", b"3"), ("CHECKSUM", checksum), ("metadata.config", metadata),
                               ("contents.tar.gz", compressed)):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                outer.addfile(member, io.BytesIO(data))
        return path, {name: hashlib.sha256(data).hexdigest() for name, data in published.items()}, metadata

    def test_every_package_receives_its_contexts_exact_closed_public_lock(self):
        self.assertEqual({context: len(spec[1]) for context, spec in runner.CONTEXTS.items()},
                         {"trust": 13, "historian": 4, "composed": 22})
        for context, (packages, dependencies, _app, _module, _phases) in runner.CONTEXTS.items():
            expected = self.context_lock(context)
            self.assertEqual(set(runner.lock_records(expected)), dependencies)
            for name in packages:
                with self.subTest(context=context, package=name):
                    package = self.package(context + "-" + name)
                    runner.install_unpacked_package_lock(package, expected)
                    self.assertEqual((package / "mix.lock").read_bytes(), expected)
                    runner.require_unpacked_package_lock(package, expected)
        self.assertNotEqual(self.context_lock("trust"), self.context_lock("historian"))
        self.assertNotEqual(self.context_lock("trust"), self.context_lock("composed"))

    def test_verified_unpack_adds_only_private_lock_without_changing_archive_or_published_receipt(self):
        archive, published, metadata = self.archive()
        original_archive = archive.read_bytes()
        package, metadata_path = self.root / "unpacked", self.root / "sample.config"
        expected_lock = self.context_lock("composed")
        record = runner.unpack_context_package(archive, package, published, metadata_path, expected_lock)
        self.assertEqual(archive.read_bytes(), original_archive)
        self.assertEqual(record, {"archive_sha256": hashlib.sha256(original_archive).hexdigest(),
                                  "metadata_sha256": hashlib.sha256(metadata).hexdigest(), "files": published})
        self.assertEqual(support.source_files(package, ("lib", "mix.exs"), sources_only=True), published)
        self.assertNotIn("mix.lock", record["files"])
        self.assertEqual((package / "mix.lock").read_bytes(), expected_lock)
        runner.require_unpacked_package_lock(package, expected_lock)

    def test_failed_archive_verification_does_not_install_a_lock(self):
        archive, published, _metadata = self.archive(checksum_valid=False)
        destination = self.root / "unpacked"
        with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
            runner.unpack_context_package(archive, destination, published, self.root / "sample.config",
                                          self.context_lock("composed"))
        self.assertFalse(destination.exists())
        self.assertFalse((self.root / "sample.config").exists())

    def test_install_refuses_existing_locks_including_malformed_bytes_without_overwriting(self):
        expected = self.context_lock("composed")
        for index, existing in enumerate((expected, b"not an Elixir lock\n")):
            with self.subTest(existing=index):
                package = self.package("existing-" + str(index))
                path = package / "mix.lock"
                path.write_bytes(existing)
                with self.assertRaises(FileExistsError):
                    runner.install_unpacked_package_lock(package, expected)
                self.assertEqual(path.read_bytes(), existing)

    def test_install_refuses_existing_lock_symlink_and_symlinked_package_root(self):
        package = self.package()
        outside = self.root / "not-created"
        (package / "mix.lock").symlink_to(outside)
        with self.assertRaises(FileExistsError):
            runner.install_unpacked_package_lock(package, self.context_lock("trust"))
        self.assertFalse(outside.exists())
        actual = self.package("actual")
        alias = self.root / "alias"
        alias.symlink_to(actual, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "package root"):
            runner.install_unpacked_package_lock(alias, self.context_lock("trust"))
        self.assertFalse((actual / "mix.lock").exists())

    def test_later_guard_rejects_mutated_or_malformed_lock_without_repair(self):
        expected = self.context_lock("composed")
        for index, changed in enumerate((self.context_lock("trust"), b"not an Elixir lock\n")):
            with self.subTest(change=index):
                package = self.package("mutated-" + str(index))
                runner.install_unpacked_package_lock(package, expected)
                path = package / "mix.lock"
                path.write_bytes(changed)
                with self.assertRaisesRegex(RuntimeError, "context public lock changed"):
                    runner.require_unpacked_package_lock(package, expected)
                self.assertEqual(path.read_bytes(), changed)

    def test_later_guard_rejects_missing_or_symlinked_lock_without_reading_target(self):
        expected = self.context_lock("trust")
        package = self.package()
        runner.install_unpacked_package_lock(package, expected)
        path = package / "mix.lock"
        path.unlink()
        with self.assertRaisesRegex(RuntimeError, "Missing/unsafe"):
            runner.require_unpacked_package_lock(package, expected)
        target = self.root / "lock-target"
        target.write_bytes(expected)
        path.symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "Missing/unsafe"):
            runner.require_unpacked_package_lock(package, expected)
        self.assertEqual(target.read_bytes(), expected)

    def test_same_exact_lock_is_verified_after_owned_source_hidden_relocation(self):
        package = self.package()
        expected = self.context_lock("historian")
        runner.install_unpacked_package_lock(package, expected)
        hidden = self.root / "source-hidden"
        hidden.mkdir(mode=0o700)
        moved = hidden / "package"
        package.rename(moved)
        runner.require_unpacked_package_lock(moved, expected)
        self.assertEqual((moved / "mix.lock").read_bytes(), expected)

    def test_missing_declared_public_pin_refuses_before_package_installation(self):
        package = self.package()
        with self.assertRaisesRegex(RuntimeError, "explicit public prod pin"):
            runner.install_unpacked_package_lock(package, runner.make_lock(self.records, {"missing_public_pin"}))
        self.assertEqual(list(package.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
