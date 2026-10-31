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


# Public Hex metadata fixtures: exact bytes/hash provenance in source audit02.
PUBLISHED_APP_FIXTURES = {'cowboy': {'version': '2.19.0', 'outer_sha256': '986dae81f99fcb78ef2d8efc21d738cee189410840eeaf32eca84ada81dcf6d4', 'app': b'{application, \'cowboy\', [\n\t{description, "Small, fast, modern HTTP server."},\n\t{vsn, "2.19.0"},\n\t{modules, [\'cowboy\',\'cowboy_app\',\'cowboy_bstr\',\'cowboy_children\',\'cowboy_clear\',\'cowboy_clock\',\'cowboy_compress_h\',\'cowboy_constraints\',\'cowboy_decompress_h\',\'cowboy_handler\',\'cowboy_http\',\'cowboy_http2\',\'cowboy_http3\',\'cowboy_loop\',\'cowboy_metrics_h\',\'cowboy_middleware\',\'cowboy_quicer\',\'cowboy_req\',\'cowboy_rest\',\'cowboy_router\',\'cowboy_static\',\'cowboy_stream\',\'cowboy_stream_h\',\'cowboy_sub_protocol\',\'cowboy_sup\',\'cowboy_tls\',\'cowboy_tracer_h\',\'cowboy_websocket\',\'cowboy_webtransport\']},\n\t{registered, [cowboy_sup,cowboy_clock]},\n\t{applications, [kernel,stdlib,crypto,cowlib,ranch]},\n\t{optional_applications, []},\n\t{mod, {\'cowboy_app\', []}},\n\t{env, []}\n]}.', 'hex_metadata': b'{<<"links">>,\n [{<<"Function reference">>,\n   <<"https://ninenines.eu/docs/en/cowboy/2.19/manual/">>},\n  {<<"GitHub">>,<<"https://github.com/ninenines/cowboy">>},\n  {<<"Sponsor">>,<<"https://github.com/sponsors/essen">>},\n  {<<"User guide">>,<<"https://ninenines.eu/docs/en/cowboy/2.19/guide/">>}]}.\n{<<"name">>,<<"cowboy">>}.\n{<<"version">>,<<"2.19.0">>}.\n{<<"description">>,<<"Small, fast, modern HTTP server.">>}.\n{<<"app">>,<<"cowboy">>}.\n{<<"build_tools">>,[<<"make">>,<<"rebar3">>]}.\n{<<"files">>,\n [<<"ebin/cowboy.app">>,<<"erlang.mk">>,<<"LICENSE">>,<<"Makefile">>,\n  <<"plugins.mk">>,<<"README.asciidoc">>,<<"rebar.config">>,\n  <<"src/cowboy.erl">>,<<"src/cowboy_app.erl">>,<<"src/cowboy_bstr.erl">>,\n  <<"src/cowboy_children.erl">>,<<"src/cowboy_clear.erl">>,\n  <<"src/cowboy_clock.erl">>,<<"src/cowboy_compress_h.erl">>,\n  <<"src/cowboy_constraints.erl">>,<<"src/cowboy_decompress_h.erl">>,\n  <<"src/cowboy_dynamic_buffer.hrl">>,<<"src/cowboy_handler.erl">>,\n  <<"src/cowboy_http.erl">>,<<"src/cowboy_http2.erl">>,\n  <<"src/cowboy_http3.erl">>,<<"src/cowboy_loop.erl">>,\n  <<"src/cowboy_metrics_h.erl">>,<<"src/cowboy_middleware.erl">>,\n  <<"src/cowboy_quicer.erl">>,<<"src/cowboy_req.erl">>,\n  <<"src/cowboy_rest.erl">>,<<"src/cowboy_router.erl">>,\n  <<"src/cowboy_static.erl">>,<<"src/cowboy_stream.erl">>,\n  <<"src/cowboy_stream_h.erl">>,<<"src/cowboy_sub_protocol.erl">>,\n  <<"src/cowboy_sup.erl">>,<<"src/cowboy_tls.erl">>,\n  <<"src/cowboy_tracer_h.erl">>,<<"src/cowboy_websocket.erl">>,\n  <<"src/cowboy_webtransport.erl">>,\n  <<"doc/src/guide/security_model.asciidoc">>,\n  <<"doc/src/guide/security_checklist.asciidoc">>]}.\n{<<"requirements">>,\n [{<<"cowlib">>,\n   [{<<"app">>,<<"cowlib">>},\n    {<<"optional">>,false},\n    {<<"requirement">>,<<">= 2.20.0 and < 3.0.0">>}]},\n  {<<"ranch">>,\n   [{<<"app">>,<<"ranch">>},\n    {<<"optional">>,false},\n    {<<"requirement">>,<<">= 1.8.0 and < 3.0.0">>}]}]}.\n{<<"licenses">>,[<<"ISC">>]}.\n'}, 'cowlib': {'version': '2.20.0', 'outer_sha256': '7d41a0dd2c093041ff3779ac5fe8a1585a68ec7cb2dd1de0536bdd2452fd7ba1', 'app': b'{application, \'cowlib\', [\n\t{description, "Support library for manipulating Web protocols."},\n\t{vsn, "2.20.0"},\n\t{modules, [\'cow_base64url\',\'cow_capsule\',\'cow_cookie\',\'cow_date\',\'cow_deflate\',\'cow_hpack\',\'cow_http\',\'cow_http1\',\'cow_http2\',\'cow_http2_machine\',\'cow_http3\',\'cow_http3_machine\',\'cow_http_hd\',\'cow_http_struct_hd\',\'cow_http_te\',\'cow_iolists\',\'cow_link\',\'cow_mimetypes\',\'cow_multipart\',\'cow_qpack\',\'cow_qs\',\'cow_sse\',\'cow_uri\',\'cow_uri_template\',\'cow_ws\']},\n\t{registered, []},\n\t{applications, [kernel,stdlib,crypto]},\n\t{optional_applications, []},\n\t{env, []}\n]}.', 'hex_metadata': b'{<<"links">>,\n [{<<"Function reference">>,\n   <<"https://ninenines.eu/docs/en/cowlib/2.20/manual/">>},\n  {<<"GitHub">>,<<"https://github.com/ninenines/cowlib">>},\n  {<<"Sponsor">>,<<"https://github.com/sponsors/essen">>}]}.\n{<<"name">>,<<"cowlib">>}.\n{<<"version">>,<<"2.20.0">>}.\n{<<"description">>,<<"Support library for manipulating Web protocols.">>}.\n{<<"app">>,<<"cowlib">>}.\n{<<"build_tools">>,[<<"make">>,<<"rebar3">>]}.\n{<<"files">>,\n [<<"ebin/cowlib.app">>,<<"erlang.mk">>,<<"include/cow_inline.hrl">>,\n  <<"include/cow_parse.hrl">>,<<"LICENSE">>,<<"Makefile">>,\n  <<"README.asciidoc">>,<<"src/cow_base64url.erl">>,<<"src/cow_capsule.erl">>,\n  <<"src/cow_cookie.erl">>,<<"src/cow_date.erl">>,<<"src/cow_deflate.erl">>,\n  <<"src/cow_hpack.erl">>,<<"src/cow_hpack_common.hrl">>,\n  <<"src/cow_hpack_dec_huffman_lookup.hrl">>,<<"src/cow_http.erl">>,\n  <<"src/cow_http1.erl">>,<<"src/cow_http2.erl">>,\n  <<"src/cow_http2_machine.erl">>,<<"src/cow_http3.erl">>,\n  <<"src/cow_http3_machine.erl">>,<<"src/cow_http_hd.erl">>,\n  <<"src/cow_http_struct_hd.erl">>,<<"src/cow_http_te.erl">>,\n  <<"src/cow_iolists.erl">>,<<"src/cow_link.erl">>,\n  <<"src/cow_mimetypes.erl">>,<<"src/cow_mimetypes.erl.src">>,\n  <<"src/cow_multipart.erl">>,<<"src/cow_qpack.erl">>,<<"src/cow_qs.erl">>,\n  <<"src/cow_sse.erl">>,<<"src/cow_uri.erl">>,<<"src/cow_uri_template.erl">>,\n  <<"src/cow_ws.erl">>]}.\n{<<"requirements">>,[]}.\n{<<"licenses">>,[<<"ISC">>]}.\n'}, 'ranch': {'version': '2.3.0', 'outer_sha256': '6168ec49409d982f7cfbd83dd083144f6cbe67caa4036551d2f0a3ad67c9d023', 'app': b'{application, \'ranch\', [\n\t{description, "Socket acceptor pool for TCP protocols."},\n\t{vsn, "2.3.0"},\n\t{modules, [\'ranch\',\'ranch_acceptor\',\'ranch_acceptors_sup\',\'ranch_app\',\'ranch_conns_sup\',\'ranch_conns_sup_sup\',\'ranch_crc32c\',\'ranch_embedded_sup\',\'ranch_listener_sup\',\'ranch_protocol\',\'ranch_proxy_header\',\'ranch_server\',\'ranch_server_proxy\',\'ranch_ssl\',\'ranch_sup\',\'ranch_tcp\',\'ranch_transport\']},\n\t{registered, [ranch_sup,ranch_server]},\n\t{applications, [kernel,stdlib,ssl]},\n\t{optional_applications, []},\n\t{mod, {\'ranch_app\', []}},\n\t{env, []}\n]}.', 'hex_metadata': b'{<<"links">>,\n [{<<"Function reference">>,\n   <<"https://ninenines.eu/docs/en/ranch/2.3/manual/">>},\n  {<<"GitHub">>,<<"https://github.com/ninenines/ranch">>},\n  {<<"Sponsor">>,<<"https://github.com/sponsors/essen">>},\n  {<<"User guide">>,<<"https://ninenines.eu/docs/en/ranch/2.3/guide/">>}]}.\n{<<"name">>,<<"ranch">>}.\n{<<"version">>,<<"2.3.0">>}.\n{<<"description">>,<<"Socket acceptor pool for TCP protocols.">>}.\n{<<"app">>,<<"ranch">>}.\n{<<"build_tools">>,[<<"make">>,<<"rebar3">>]}.\n{<<"files">>,\n [<<"ebin/ranch.app">>,<<"ebin/ranch.appup">>,<<"erlang.mk">>,<<"LICENSE">>,\n  <<"Makefile">>,<<"README.asciidoc">>,<<"src/ranch.appup">>,\n  <<"src/ranch.erl">>,<<"src/ranch_acceptor.erl">>,\n  <<"src/ranch_acceptors_sup.erl">>,<<"src/ranch_app.erl">>,\n  <<"src/ranch_conns_sup.erl">>,<<"src/ranch_conns_sup_sup.erl">>,\n  <<"src/ranch_crc32c.erl">>,<<"src/ranch_embedded_sup.erl">>,\n  <<"src/ranch_listener_sup.erl">>,<<"src/ranch_protocol.erl">>,\n  <<"src/ranch_proxy_header.erl">>,<<"src/ranch_server.erl">>,\n  <<"src/ranch_server_proxy.erl">>,<<"src/ranch_ssl.erl">>,\n  <<"src/ranch_sup.erl">>,<<"src/ranch_tcp.erl">>,\n  <<"src/ranch_transport.erl">>]}.\n{<<"requirements">>,[]}.\n{<<"licenses">>,[<<"ISC">>]}.\n'}}

class PublishedOTPMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.cache = self.root / "cache"
        self.hex = self.root / "hex-tool"
        self.hex.mkdir()
        (self.hex / "tool.ex").write_text("synthetic tool source")
        for name, spec in Q.PACKAGES.items():
            package = self.repo / "packages" / name
            package.mkdir(parents=True)
            for relative in spec[1]:
                path = package / relative
                if Path(relative).suffix:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("synthetic source selection only")
                else:
                    path.mkdir(parents=True, exist_ok=True)
                    (path / "source.txt").write_text("synthetic source selection only")
        records = []
        for name in Q.DEPENDENCIES:
            root = self.cache / name
            (root / "src").mkdir(parents=True)
            (root / "src" / (name + ".erl")).write_text("synthetic source")
            (root / ".hex").write_bytes(b"synthetic Hex marker")
            fixture = PUBLISHED_APP_FIXTURES.get(name)
            version = fixture["version"] if fixture else "0.0.0"
            outer = fixture["outer_sha256"] if fixture else "0" * 64
            records.append('  "' + name + '": {:hex, :' + name + ', "' + version + '", "' + "0" * 64 + '", [], [], "hexpm", "' + outer + '"},')
            if fixture:
                (root / "ebin").mkdir()
                (root / "ebin" / (name + ".app")).write_bytes(fixture["app"])
                (root / "hex_metadata.config").write_bytes(fixture["hex_metadata"])
        self.lock = ("%{\n" + "\n".join(records) + "\n}\n").encode()
        (self.repo / "mix.lock").write_bytes(self.lock)
        consumer = self.repo / "packages/arbor_llm/examples/standalone"
        (consumer / "lib").mkdir(parents=True)
        (consumer / "lib/proof.ex").write_text("synthetic source")
        (consumer / "config").mkdir()
        (consumer / "config/config.exs").write_text("synthetic config selection only")
        (consumer / "README.md").write_text("synthetic source")
        (consumer / "mix.exs").write_text("synthetic source")
        (consumer / "mix.lock").write_bytes(self.lock)
        self.args = type("Args", (), {"repository": self.repo, "deps_source_cache": self.cache, "hex_archive": self.hex})()

    def inputs(self):
        return Q.source_inputs(self.args, H)[0]

    def copy(self, name, files):
        work = self.root / ("work-" + name)
        (work / "deps").mkdir(parents=True)
        H.copy_files(self.cache / name, work / "deps" / name, files)
        record = {"deps/" + name: {"files": files, "dependency": True}}
        return work, record, work / "deps" / name

    def test_existing_source_inputs_and_copy_path_preserve_published_app_specs(self):
        # This existing-callable assertion fails old71f because ebin was omitted.
        source = self.inputs()
        for name, fixture in PUBLISHED_APP_FIXTURES.items():
            relative = "ebin/" + name + ".app"
            files = source["dependencies"][name]
            self.assertIn(relative, files)
            self.assertEqual(files[relative], Q.sha(fixture["app"]))
            work, records, root = self.copy(name, files)
            self.assertEqual((root / relative).read_bytes(), fixture["app"])
            Q.check_private_inputs(work, records, H)

    def test_unselected_compiled_and_generated_ebin_extras_are_never_copied(self):
        root = self.cache / "ranch"
        for name in ("injected.beam", "injected.so", "generated.app"):
            (root / "ebin" / name).write_bytes(b"unreviewed compiled/generated output")
        files = self.inputs()["dependencies"]["ranch"]
        self.assertEqual([name for name in files if name.startswith("ebin/")], ["ebin/ranch.app"])
        work, records, copied = self.copy("ranch", files)
        self.assertEqual([path.name for path in (copied / "ebin").iterdir()], ["ranch.app"])
        Q.check_private_inputs(work, records, H)

    def test_private_extra_ebin_is_rejected_in_normal_and_hidden_roots(self):
        files = self.inputs()["dependencies"]["ranch"]
        work, records, root = self.copy("ranch", files)
        Q.check_private_inputs(work, records, H)
        (root / "ebin/injected.beam").write_bytes(b"not a permitted input")
        with self.assertRaisesRegex(RuntimeError, "unreviewed extra"):
            Q.check_private_inputs(work, records, H)
        hidden = work / "source-hidden/deps/ranch"
        hidden.parent.mkdir(parents=True)
        root.rename(hidden)
        with self.assertRaisesRegex(RuntimeError, "unreviewed extra"):
            Q.check_private_inputs(work, records, H)

    def test_copied_source_spec_is_immutable_after_source_hiding(self):
        files = self.inputs()["dependencies"]["cowlib"]
        work, records, root = self.copy("cowlib", files)
        hidden = work / "source-hidden/deps/cowlib"
        hidden.parent.mkdir(parents=True)
        root.rename(hidden)
        Q.check_private_inputs(work, records, H)
        (hidden / "ebin/cowlib.app").write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "Source-published OTP metadata"):
            Q.check_private_inputs(work, records, H)

    def test_missing_source_spec_is_rejected_before_copy(self):
        (self.cache / "ranch/ebin/ranch.app").unlink()
        with self.assertRaises((FileNotFoundError, RuntimeError)):
            self.inputs()

    def test_source_spec_links_and_hardlinks_are_rejected(self):
        path = self.cache / "ranch/ebin/ranch.app"
        retained = self.root / "retained-ranch.app"
        path.rename(retained)
        path.symlink_to(retained)
        with self.assertRaises((OSError, RuntimeError)):
            self.inputs()
        path.unlink()
        os.link(retained, path)
        with self.assertRaisesRegex(RuntimeError, "single-link"):
            self.inputs()

    def test_wrong_hash_oversized_NUL_and_invalid_UTF8_specs_are_rejected(self):
        path = self.cache / "ranch/ebin/ranch.app"
        original = path.read_bytes()
        invalid = [b"x" * len(original), b"x" * 4097,
                   b"\0" + original[1:], b"\xff" + original[1:]]
        for data in invalid:
            with self.subTest(shape=Q.sha(data)):
                path.write_bytes(data)
                with self.assertRaisesRegex(RuntimeError, "Source-published OTP metadata"):
                    self.inputs()
        path.write_bytes(original)

    def test_metadata_manifest_and_public_version_outer_checksum_are_bound(self):
        path = self.cache / "ranch/hex_metadata.config"
        data = path.read_bytes()
        path.write_bytes(b"different public metadata")
        with self.assertRaisesRegex(RuntimeError, "package manifest"):
            self.inputs()
        path.write_bytes(data)
        for old, new in [(b'"2.3.0"', b'"2.3.1"'),
                         (PUBLISHED_APP_FIXTURES["ranch"]["outer_sha256"].encode(), b"f" * 64)]:
            lock = self.lock.replace(old, new)
            (self.repo / "mix.lock").write_bytes(lock)
            (self.repo / "packages/arbor_llm/examples/standalone/mix.lock").write_bytes(lock)
            with self.assertRaisesRegex(RuntimeError, "version/archive lock"):
                self.inputs()

    def test_metadata_admission_stays_closed_to_the_three_named_dependencies(self):
        root = self.cache / "req/ebin"
        root.mkdir()
        (root / "req.app").write_bytes(PUBLISHED_APP_FIXTURES["ranch"]["app"])
        source = self.inputs()
        self.assertNotIn("ebin/req.app", source["dependencies"]["req"])
        expected = {name: ["ebin/" + name + ".app"] for name in PUBLISHED_APP_FIXTURES}
        actual = {name: [path for path in source["dependencies"][name] if path.startswith("ebin/")]
                  for name in PUBLISHED_APP_FIXTURES}
        self.assertEqual(actual, expected)

    def test_private_spec_replacement_link_is_refused(self):
        files = self.inputs()["dependencies"]["cowboy"]
        work, records, root = self.copy("cowboy", files)
        path = root / "ebin/cowboy.app"
        retained = self.root / "retained-cowboy.app"
        path.rename(retained)
        path.symlink_to(retained)
        with self.assertRaises((OSError, RuntimeError)):
            Q.check_private_inputs(work, records, H)


if __name__ == '__main__':
    unittest.main()
