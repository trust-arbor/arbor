"""Synthetic-only tests. Source review precedes execution.

The actual reviewed helper is imported, but only its source_files function is
called on TemporaryDirectory fixtures. Parser cases stop main before input
access and then exercise the actual constructed parser. No Main/operator/
toolchain/VM calls.
"""
from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / 'packages/arbor_llm/scripts/qualify_standalone.py'
HELPER = ROOT / 'packages/arbor_trust/scripts/cold_support.py'


def module(path, name):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


Q = module(SCRIPT, 'llm_cold_synthetic_subject')
if hashlib.sha256(HELPER.read_bytes()).hexdigest() != Q.GUARD_SHA256:
    raise RuntimeError('Synthetic test helper differs from reviewed tooling')
H = module(HELPER, 'llm_cold_synthetic_helper')


class ColdPolicyParserTests(unittest.TestCase):
    def parser(self):
        captured = []

        class ParserCaptured(Exception):
            pass

        def capture(parser, *args, **kwargs):
            captured.append(parser)
            raise ParserCaptured

        with mock.patch.object(Q, 'load_guard') as guard, \
                mock.patch.object(Q, 'source_inputs') as inputs, \
                mock.patch.object(Q.argparse.ArgumentParser, 'parse_args', capture):
            with self.assertRaises(ParserCaptured):
                Q.main()
        guard.assert_not_called()
        inputs.assert_not_called()
        self.assertEqual(len(captured), 1)
        return captured[0]

    def arguments(self):
        arguments = ['--prepare']
        for option in ('repository', 'main-root', 'work-dir', 'mix', 'erlang-root',
                       'elixir-root', 'hex-archive', 'cc', 'make', 'rebar3',
                       'sdk-root', 'developer-dir', 'deps-source-cache', 'guard-helper'):
            arguments += ['--' + option, '/synthetic/' + option]
        for option in ('head', 'main-head', 'branch'):
            arguments += ['--' + option, 'unused-parser-value']
        return arguments

    def test_cli_keeps_strict_as_default_before_guard_or_source_access(self):
        self.assertEqual(self.parser().parse_args(self.arguments()).main_build_policy, 'strict')

    def test_cli_accepts_only_the_three_pinned_helper_policies(self):
        expected = ('strict', 'reviewed-boundary-view-v2', 'reviewed-boundary-view-v2-nine')
        self.assertEqual(Q.POLICIES, expected)
        self.assertEqual(Q.POLICIES, H.MAIN_BUILD_POLICIES)
        parser = self.parser()
        for policy in expected:
            with self.subTest(policy=policy):
                selected = parser.parse_args(self.arguments() + ['--main-build-policy', policy])
                self.assertEqual(selected.main_build_policy, policy)

    def test_cli_rejects_unknown_policy_before_guard_or_source_access(self):
        parser = self.parser()
        for policy in ('all-compile-manifests', 'reviewed-boundary-view-v2-all', ''):
            with self.subTest(policy=policy), redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as failure:
                parser.parse_args(self.arguments() + ['--main-build-policy', policy])
            self.assertEqual(failure.exception.code, 2)


class ColdPrivateInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()
        self.records = {}

    def fixture(self, relative, files, dependency=False):
        root = self.work / relative
        root.mkdir(parents=True)
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.records[relative] = {'files': {name: Q.sha(data) for name, data in files.items()}, 'dependency': dependency}
        return root

    def check(self):
        Q.check_private_inputs(self.work, self.records, H)

    def hide(self, relative):
        source = self.work / relative
        target = self.work / 'source-hidden' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        source.rename(target)
        return target

    def test_normal_then_hidden_inputs_and_lock_are_conserved(self):
        self.fixture('consumer', {'lib/proof.ex': b'proof', 'mix.lock': b'lock'})
        self.check()
        root = self.hide('consumer')
        self.check()
        Q.check_lock(root, b'lock')

    def test_changed_source_is_rejected_after_hiding(self):
        self.fixture('unpacked/arbor_llm', {'lib/api.ex': b'original', 'mix.lock': b'lock'})
        root = self.hide('unpacked/arbor_llm')
        (root / 'lib/api.ex').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'Copied private source'):
            self.check()

    def test_new_consumed_config_is_rejected(self):
        root = self.fixture('producer-arbor_llm', {'mix.exs': b'mix', 'mix.lock': b'lock'})
        (root / 'config').mkdir()
        (root / 'config/config.exs').write_bytes(b'unreviewed')
        with self.assertRaisesRegex(RuntimeError, 'Copied private source'):
            self.check()

    def test_missing_project_is_rejected(self):
        root = self.fixture('consumer', {'mix.lock': b'lock'})
        root.rename(self.work / 'retained')
        with self.assertRaisesRegex(RuntimeError, 'missing'):
            self.check()

    def test_normal_and_hidden_ambiguity_is_rejected(self):
        root = self.fixture('consumer', {'mix.lock': b'lock'})
        target = self.work / 'source-hidden/consumer'
        target.parent.mkdir()
        shutil.copytree(root, target)
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            self.check()

    def test_linked_project_is_rejected(self):
        root = self.fixture('consumer', {'mix.lock': b'lock'})
        retained = self.work / 'retained'
        root.rename(retained)
        root.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'link'):
            self.check()

    def test_linked_project_ancestor_is_rejected(self):
        self.fixture('unpacked/arbor_llm', {'mix.lock': b'lock'})
        (self.work / 'unpacked').rename(self.work / 'retained')
        (self.work / 'unpacked').symlink_to(self.work / 'retained', target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'ancestor'):
            self.check()

    def test_only_dependency_build_outputs_are_excluded(self):
        root = self.fixture('deps/cowboy', {'src/cowboy.erl': b'source', '.hex': b'marker'}, dependency=True)
        for name in ('_build/prod/a.beam', 'ebin/cowboy.app'):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'generated')
        self.check()
        (root / 'src/cowboy.erl').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'Copied private source'):
            self.check()

    def test_hex_tool_beam_change_is_rejected(self):
        root = self.fixture('tool-archives/hex-reviewed', {'ebin/tool.beam': b'tool'})
        (root / 'ebin/tool.beam').write_bytes(b'other')
        with self.assertRaisesRegex(RuntimeError, 'Copied private source'):
            self.check()

    def test_hidden_lock_change_is_rejected(self):
        self.fixture('consumer', {'mix.lock': b'lock'})
        root = self.hide('consumer')
        (root / 'mix.lock').write_bytes(b'other')
        with self.assertRaisesRegex(RuntimeError, 'lock changed'):
            Q.check_lock(root, b'lock')
        with self.assertRaisesRegex(RuntimeError, 'Copied private source'):
            self.check()

    def test_archive_and_metadata_bytes_and_member_map_remain_pinned(self):
        (self.work / 'archives').mkdir()
        (self.work / 'metadata').mkdir()
        archive = self.work / 'archives/arbor_llm-0.1.0.tar'
        metadata = self.work / 'metadata/arbor_llm.config'
        archive.write_bytes(b'validated archive')
        metadata.write_bytes(b'validated terms')
        files = {'lib/api.ex': Q.sha(b'original')}
        record = {'archive_sha256': Q.sha(archive.read_bytes()), 'metadata_sha256': Q.sha(metadata.read_bytes()), 'files': files}
        Q.check_archives(self.work, {'arbor_llm': record}, {'arbor_llm': files})
        for target in (archive, metadata):
            original = target.read_bytes()
            target.write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'archive/member/metadata'):
                Q.check_archives(self.work, {'arbor_llm': record}, {'arbor_llm': files})
            target.write_bytes(original)
        with self.assertRaisesRegex(RuntimeError, 'archive/member/metadata'):
            Q.check_archives(self.work, {'arbor_llm': {**record, 'files': {}}}, {'arbor_llm': files})


class ColdStartupContextTests(unittest.TestCase):
    """Only temporary paths; main stops at the first post-guard helper boundary."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repository = self.root / 'repository'
        self.cwd = self.root / 'caller-cwd'
        self.home = self.root / 'fake-home'
        self.work = self.root / 'not-yet-prepared'
        for root in (self.repository, self.cwd, self.home):
            root.mkdir()

    def arguments(self):
        values = {
            'repository': self.repository,
            'main-root': self.root / 'main',
            'work-dir': self.work,
        }
        arguments = ['qualify_standalone.py', '--prepare']
        for option in ('repository', 'main-root', 'work-dir', 'mix', 'erlang-root',
                       'elixir-root', 'hex-archive', 'cc', 'make', 'rebar3',
                       'sdk-root', 'developer-dir', 'deps-source-cache', 'guard-helper'):
            arguments += ['--' + option, str(values.get(option, self.root / option))]
        return arguments + ['--head', '1' * 40, '--main-head', '2' * 40, '--branch', '']

    def prepare_outcome(self):
        class GuardBoundaryReached(Exception):
            pass

        original_home = os.environ.get('HOME')
        work_existed = self.work.exists()
        with mock.patch.object(Q.Path, 'home', return_value=self.home), \
                mock.patch.object(Q.Path, 'cwd', return_value=self.cwd), \
                mock.patch.object(Q.sys, 'argv', self.arguments()), \
                mock.patch.object(Q, 'load_guard', side_effect=GuardBoundaryReached) as loader, \
                mock.patch.object(Q, 'source_inputs') as inputs, \
                mock.patch.object(Q.shutil, 'copyfile') as copy, \
                mock.patch.object(Q.subprocess, 'Popen') as process:
            try:
                Q.main()
            except GuardBoundaryReached:
                outcome = ('admitted', None)
            except RuntimeError as error:
                outcome = ('rejected', str(error))
            else:
                self.fail('Preparation crossed the pinned helper boundary')
        self.assertEqual(loader.call_count, int(outcome[0] == 'admitted'))
        inputs.assert_not_called()
        copy.assert_not_called()
        process.assert_not_called()
        self.assertEqual(self.work.exists(), work_existed)
        self.assertEqual(os.environ.get('HOME'), original_home)
        return outcome

    def assert_preparation_rejected(self, path):
        outcome, message = self.prepare_outcome()
        self.assertEqual(outcome, 'rejected')
        self.assertEqual(message, 'Startup/dotenv input is not qualified: ' + str(path))

    def test_prepare_ignores_home_dotenv_without_query_or_mutation(self):
        path = self.home / '.env'
        path.write_bytes(b'SYNTHETIC_UNUSED_HOME_VALUE=keep-me\n')
        original = (path.read_bytes(), path.lstat())
        exists, is_symlink = Path.exists, Path.is_symlink

        def checked_exists(item):
            self.assertNotEqual(item, path, 'Unused Home dotenv metadata queried')
            return exists(item)

        def checked_is_symlink(item):
            self.assertNotEqual(item, path, 'Unused Home dotenv link queried')
            return is_symlink(item)

        with mock.patch.object(Q.Path, 'exists', checked_exists), \
                mock.patch.object(Q.Path, 'is_symlink', checked_is_symlink):
            self.assertEqual(self.prepare_outcome(), ('admitted', None))
        self.assertEqual(path.lstat(), original[1])
        self.assertEqual(path.read_bytes(), original[0])

    def test_prepare_rejects_repository_dotenv_before_helper_or_work_creation(self):
        path = self.repository / '.env'
        path.write_text('SYNTHETIC_REPOSITORY_VALUE=refuse\n')
        self.assert_preparation_rejected(path)

    def test_prepare_rejects_caller_cwd_dotenv_before_helper_or_work_creation(self):
        path = self.cwd / '.env'
        path.write_text('SYNTHETIC_CWD_VALUE=refuse\n')
        self.assert_preparation_rejected(path)

    def test_prepare_rejects_work_dotenv_before_helper_or_source_copy(self):
        self.work.mkdir()
        path = self.work / '.env'
        path.write_text('SYNTHETIC_WORK_VALUE=refuse\n')
        self.assert_preparation_rejected(path)

    def test_prepare_rejects_home_erlang_before_helper_or_work_creation(self):
        path = self.home / '.erlang'
        path.write_text('% synthetic startup input\n')
        self.assert_preparation_rejected(path)

    def test_prepare_rejects_home_iex_before_helper_or_work_creation(self):
        path = self.home / '.iex.exs'
        path.write_text('# synthetic startup input\n')
        self.assert_preparation_rejected(path)

    def test_prepare_rejects_dangling_repository_dotenv_link(self):
        path = self.repository / '.env'
        path.symlink_to(self.root / 'absent-dotenv')
        self.assert_preparation_rejected(path)

    def test_source_hidden_release_cwd_still_rejects_dotenv(self):
        cwd = self.root / 'source-hidden' / 'release'
        cwd.mkdir(parents=True)
        path = cwd / '.env'
        path.write_text('SYNTHETIC_RELEASE_VALUE=refuse\n')
        with self.assertRaisesRegex(RuntimeError, 'Startup/dotenv input'):
            Q.no_startup_files((cwd,), home=self.home)

    def test_actual_command_cwds_still_reject_vm_startup_files(self):
        for name in ('.erlang', '.iex.exs'):
            with self.subTest(startup=name):
                cwd = self.root / ('command-' + name.removeprefix('.'))
                cwd.mkdir()
                (cwd / name).write_text('synthetic startup input\n')
                with self.assertRaisesRegex(RuntimeError, 'Startup/dotenv input'):
                    Q.no_startup_files((cwd,), home=self.home)

    def test_home_dotenv_is_rejected_when_home_is_an_actual_consumed_cwd(self):
        path = self.home / '.env'
        path.write_text('SYNTHETIC_CWD_HOME_VALUE=refuse\n')
        with self.assertRaisesRegex(RuntimeError, 'Startup/dotenv input'):
            Q.no_startup_files((self.home,), home=self.home)


if __name__ == '__main__':
    unittest.main()
