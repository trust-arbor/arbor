#!/usr/bin/env python3
"""Offline public-source Hex qualification of Trust, Historian and their SQL composition.

Each attempt requires reviewed inputs. --prepare copies only pinned source/tool
inputs into a fresh owned attempt. --run executes that immutable attempt. Never fetches, seeds
build artifacts, publishes, changes HOME, mutates Git or removes source/evidence.
A real predecessor rollback release is mandatory for composed final acceptance.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True

from cold_support import (require, sha, save_json, git, git_state, metadata,
                          MAIN_BUILD_POLICIES, main_build_snapshot, compare_main_build_snapshots,
                          operator_state, source_files, copy_files, names, unpack_archive)

BASE = "fafa2689158f29f6aa20ccc03ad8b41052a900b6"
PACKAGES = {
    "arbor_kernel": ("2.0.0-dev", ("lib", "mix.exs", "README.md", "LICENSE", "docs/ADOPTION.md")),
    "arbor_custody": ("0.1.0-dev", ("lib", "mix.exs", "README.md", "LICENSE")),
    "arbor_support": ("0.1.0-dev", ("lib", "c_src", "mix.exs", "README.md", "LICENSE")),
    "arbor_oauth": ("0.1.0-dev", ("lib", "mix.exs", "README.md", "LICENSE")),
    "arbor_capabilities": ("0.1.0-dev", ("lib", "mix.exs", "README.md", "LICENSE")),
    "arbor_persistence": ("0.1.0-dev", ("lib", "mix.exs", "README.md", "LICENSE")),
    "arbor_trust": ("0.1.0", ("lib", "mix.exs", "README.md", "LICENSE")),
    "arbor_historian": ("0.1.0", ("lib", "mix.exs", "README.md", "LICENSE")),
    "arbor_persistence_sql": ("0.1.0-dev", ("lib", "priv", "mix.exs", "README.md", "LICENSE")),
}
CORE_PUBLIC = {"boundary", "typed_struct", "jason", "telemetry", "plug_crypto", "req", "finch", "mint",
               "hpax", "mime", "nimble_options", "nimble_pool"}
TRUST_PUBLIC = CORE_PUBLIC | {"phoenix_pubsub"}
HIST_PUBLIC = {"boundary", "typed_struct", "jason", "telemetry"}
SQL_PUBLIC = {"ecto_sql", "ecto", "decimal", "db_connection", "postgrex", "ecto_sqlite3", "exqlite",
              "elixir_make", "cc_precompiler"}
TRUST = tuple(list(PACKAGES)[:7])
HIST = ("arbor_kernel", "arbor_support", "arbor_persistence", "arbor_historian")
CONTEXTS = {
    "trust": (TRUST, TRUST_PUBLIC, "trust_standalone_consumer", "TrustStandaloneConsumer", ("verify",)),
    "historian": (HIST, HIST_PUBLIC, "historian_standalone_consumer", "HistorianStandaloneConsumer", ("verify",)),
    "composed": (tuple(PACKAGES), TRUST_PUBLIC | SQL_PUBLIC, "paired_standalone_consumer", "PairedStandaloneConsumer.Proof", ("install", "write", "recover", "namespace_seed", "retirement", "refused")),
}
OVERRIDES = {"ARBOR_KERNEL_PATH": "arbor_kernel", "ARBOR_CUSTODY_PATH": "arbor_custody",
             "ARBOR_SUPPORT_PATH": "arbor_support", "ARBOR_OAUTH_PATH": "arbor_oauth",
             "ARBOR_CAPABILITIES_PATH": "arbor_capabilities", "ARBOR_PERSISTENCE_PATH": "arbor_persistence",
             "ARBOR_TRUST_PATH": "arbor_trust", "ARBOR_HISTORIAN_PATH": "arbor_historian",
             "ARBOR_PERSISTENCE_SQL_PATH": "arbor_persistence_sql"}
CACHE_EXCLUDES = frozenset(("_build", "deps", ".git", ".elixir_ls", "cover", "doc", "ebin", "obj"))
FIXTURE_INPUTS = ("lib", "config", "mix.exs", "README.md")
# --fixtures-root is the reviewed repository root. Each context has exactly
# one canonical location; no Hist consumer is duplicated below Trust.
FIXTURE_LOCATIONS = {
    "trust": "packages/arbor_trust/examples/standalone",
    "historian": "packages/arbor_historian/examples/standalone",
    "composed": "examples/trust_historian",
}
RESULT = "PAIRED_QUALIFICATION_RESULT="
NATIVE_PROBE = "native_header_link_probe.c"
SDK_INPUTS = ("SDKSettings.json", "SDKSettings.plist", "usr/lib/libSystem.B.tbd",
              "usr/include/errno.h", "usr/include/fcntl.h", "usr/include/inttypes.h",
              "usr/include/stdint.h", "usr/include/stdio.h", "usr/include/stdlib.h",
              "usr/include/string.h", "usr/include/sys/stat.h", "usr/include/sys/types.h",
              "usr/include/unistd.h")


def native_path(args):
    # Support intentionally looks up cc by name. Its resolved executable must
    # equal the explicit compiler pin, including when that pin is CLT clang.
    return ":".join(dict.fromkeys(map(str, (args.cc.parent, args.make.parent,
        args.erlang_root / "bin", args.elixir_root / "bin", Path("/usr/bin"),
        Path("/bin"), Path("/usr/sbin"), Path("/sbin")))))


def native_sdk_inputs(args):
    require(args.sdk_root.is_dir() and args.sdk_root.name == "MacOSX27.0.sdk",
            "Explicit supported MacOSX27.0.sdk pin required")
    require(args.developer_dir.is_dir() and args.sdk_root.is_relative_to(args.developer_dir / "SDKs"),
            "SDK must belong to the explicit developer directory")
    files, logical = {}, {}
    for name in SDK_INPUTS:
        path = args.sdk_root / name
        require(path.is_file(), "Pinned critical SDK input missing: " + name)
        resolved = path.resolve()
        require(resolved.is_relative_to(args.sdk_root), "Critical SDK input escapes its pinned root")
        files[str(resolved)] = sha(resolved.read_bytes())
        logical[name] = str(resolved)
    compiler = shutil.which("cc", path=native_path(args))
    require(compiler and Path(compiler).resolve() == args.cc,
            "Support cc lookup differs from explicit compiler pin")
    return {"sdk_root": str(args.sdk_root), "developer_dir": str(args.developer_dir),
            "critical_files": files, "logical_inputs": logical,
            "probe_source_sha256": sha((Path(__file__).parent / NATIVE_PROBE).read_bytes())}

# Consult actual Hex terms in a real pinned VM, not by a source-text heuristic.
METADATA_PROBE = r'''
expected = System.fetch_env!("PAIRED_EXPECTED_METADATA") |> File.read!() |> Jason.decode!()
root = System.fetch_env!("PAIRED_METADATA_ROOT")
Enum.each(expected, fn {name, spec} ->
  {:ok, terms} = :file.consult(String.to_charlist(Path.join(root, name <> ".config")))
  data = Map.new(terms)
  ^name = data["name"]
  ^name = data["app"]
  true = data["version"] == spec["version"]
  ["MIT"] = data["licenses"]
  true = is_binary(data["description"]) and byte_size(data["description"]) > 0
  requirements = Enum.map(Map.get(data, "requirements", []), &Map.new/1)
  true = Map.new(requirements, &{&1["name"], &1["requirement"]}) == spec["requirements"]
  true = Enum.all?(requirements, fn item ->
    item["repository"] == "hexpm" and not Map.has_key?(item, "path") and
      item["optional"] == (item["name"] in spec["optional"])
  end)
end)
IO.puts("PAIRED_METADATA_OK")
'''
PROBE_PREFIX = r'''
{:ok, [[cookie]]} = :init.get_argument(:setcookie)
expected = System.fetch_env!("PAIRED_COOKIE_SHA256")
^expected = :crypto.hash(:sha256, List.to_string(cookie)) |> Base.encode16(case: :lower)
false = Node.alive?()
true = System.version() == System.fetch_env!("PAIRED_ELIXIR_VERSION")
true = List.to_string(:erlang.system_info(:otp_release)) == System.fetch_env!("PAIRED_OTP_MAJOR")
'''
PROBE_SUFFIX = r'''
expected_apps = System.fetch_env!("PAIRED_EXPECTED_APPS") |> String.split(",") |> Enum.sort()
for {label, apps} <- [{:loaded, Application.loaded_applications()}, {:started, Application.started_applications()}] do
  actual = apps |> Enum.map(fn {app, _, _} -> Atom.to_string(app) end)
    |> Enum.filter(&String.starts_with?(&1, "arbor_")) |> Enum.sort()
  target = if label == :started, do: System.fetch_env!("PAIRED_EXPECTED_STARTED") |> String.split(",") |> Enum.sort(), else: expected_apps
  ^target = actual
end
owners = Map.new(expected_apps, fn name ->
  app = String.to_existing_atom(name)
  {:ok, modules} = :application.get_key(app, :modules)
  true = is_list(modules) and modules != []
  true = Enum.all?(modules, fn module ->
    {:module, ^module} = Code.ensure_loaded(module)
    :application.get_application(module) == {:ok, app}
  end)
  {name, length(modules)}
end)
compiled = :code.get_path() |> Enum.map(&Path.basename(Path.dirname(List.to_string(&1))))
  |> Enum.filter(&String.starts_with?(&1, "arbor_"))
  |> Enum.map(&String.replace(&1, ~r/-\d.*$/, "")) |> Enum.uniq() |> Enum.sort()
^expected_apps = compiled
false = Code.ensure_loaded?(Arbor.KernelRuntime)
false = Code.ensure_loaded?(Arbor.Common)
false = Code.ensure_loaded?(Arbor.Signals)
false = Code.ensure_loaded?(Arbor.Capabilities.OIDC)
false = function_exported?(Arbor.Security, :register_identity_fixture, 1)
{:ok, :arbor_support} = :application.get_application(Arbor.Common.SafePath.NativeReaderArtifact)
artifact = Arbor.Common.SafePath.NativeReaderArtifact
expected_c = System.fetch_env!("PAIRED_C_SOURCE_SHA256")
^expected_c = artifact.source_sha256()
native_sha = artifact.binary_sha256()
^native_sha = :crypto.hash(:sha256, artifact.binary()) |> Base.encode16(case: :lower)
allowed = System.fetch_env!("PAIRED_ALLOWED_CODE_ROOTS") |> String.split("|")
true = Enum.all?(:code.get_path(), fn path ->
  path = Path.expand(List.to_string(path)) <> "/"
  Enum.any?(allowed, &String.starts_with?(path, Path.expand(&1) <> "/"))
end)
if System.fetch_env!("PAIRED_NO_MIX") == "1" do
  false = Code.ensure_loaded?(Mix)
  {:error, :bad_name} = :code.lib_dir(:mix)
  release = Path.expand(System.fetch_env!("PAIRED_RELEASE_ROOT")) <> "/"
  true = String.starts_with?(Path.expand(List.to_string(:code.root_dir())) <> "/", release)
end
false = Node.alive?()
IO.puts("PAIRED_QUALIFICATION_RESULT=" <> Jason.encode!(Map.merge(result, %{
  "first_party" => expected_apps, "compiled_first_party" => compiled, "module_owner_counts" => owners,
  "mix_available" => Code.ensure_loaded?(Mix), "native_binary_sha256" => native_sha
})))
'''

# Public prod metadata only. Optional deps are admitted, never fetched or compiled.
REQUIREMENTS = {
    "arbor_kernel": {"typed_struct": "~> 0.3", "jason": "~> 1.4", "boundary": "~> 0.10"},
    "arbor_custody": {},
    "arbor_support": {"boundary": "~> 0.10"},
    "arbor_oauth": {"jason": "~> 1.4", "req": "~> 0.7.5", "finch": "~> 0.24", "mint": "~> 1.9.3", "boundary": "~> 0.10"},
    "arbor_capabilities": {"arbor_kernel": "~> 2.0.0-dev", "arbor_custody": "~> 0.1.0-dev", "arbor_support": "~> 0.1.0-dev", "arbor_oauth": "~> 0.1.0-dev", "arbor_capabilities_oidc": "~> 0.1.0-dev", "jason": "~> 1.4", "telemetry": "~> 1.0", "plug_crypto": "~> 2.0", "typed_struct": "~> 0.3", "boundary": "~> 0.10"},
    "arbor_persistence": {"jason": "~> 1.4", "typed_struct": "~> 0.3", "telemetry": "~> 1.0"},
    "arbor_trust": {"arbor_kernel": "~> 2.0.0-dev", "arbor_capabilities": "~> 0.1.0-dev", "arbor_support": "~> 0.1.0-dev", "arbor_persistence": "~> 0.1.0-dev", "phoenix_pubsub": "~> 2.1", "telemetry": "~> 1.0", "jason": "~> 1.4", "boundary": "~> 0.10"},
    "arbor_historian": {"arbor_kernel": "~> 2.0.0-dev", "arbor_support": "~> 0.1.0-dev", "arbor_persistence": "~> 0.1.0-dev", "jason": "~> 1.4", "telemetry": "~> 1.0", "typed_struct": "~> 0.3", "boundary": "~> 0.10"},
    "arbor_persistence_sql": {"arbor_persistence": "~> 0.1.0-dev", "ecto_sql": "~> 3.10", "postgrex": "~> 0.18", "ecto_sqlite3": "~> 0.18", "jason": "~> 1.4"},
}
OPTIONAL = {"arbor_capabilities": ["arbor_capabilities_oidc"], "arbor_trust": ["phoenix_pubsub"]}


def lock_records(data):
    return {m.group(1).decode(): m.group(0).strip()
            for m in re.finditer(rb'(?m)^\s*"([^"\n]+)": [^\n]+$', data)}


def make_lock(records, dependencies):
    require(dependencies <= records.keys(), "Root lock lacks an explicit public prod pin")
    return b"%{\n" + b"\n".join(b"  " + records[name] for name in sorted(dependencies)) + b"\n}\n"


def probe(context, phase, no_mix):
    _packages, _deps, _app, module, _phases = CONTEXTS[context]
    if context == "composed":
        call = f'result = {module}.run!(:{phase}, require_no_mix: {str(no_mix).lower()})\n'
    else:
        call = f'result = {module}.verify!(require_no_mix: {str(no_mix).lower()})\n'
    return PROBE_PREFIX + call + PROBE_SUFFIX


def parse_result(path):
    rows = [json.loads(line[len(RESULT):]) for line in path.read_text().splitlines() if line.startswith(RESULT)]
    require(len(rows) == 1, "Missing/ambiguous actual public-probe result")
    require(isinstance(rows[0].get("checks"), list) and rows[0]["checks"], "No actual acceptance checks reported")
    return rows[0]


def fixture_source_root(repository, context):
    path = repository
    for component in Path(FIXTURE_LOCATIONS[context]).parts:
        path = path / component
        require(path.is_dir() and not path.is_symlink(), "Missing/unsafe canonical fixture directory: " + str(path))
    return path


def require_prepared_main_build_policy(args, manifest):
    require(args.main_build_policy in MAIN_BUILD_POLICIES, "Unknown Main build policy")
    require(manifest.get("main_build_policy") == args.main_build_policy,
            "Run Main build policy differs from prepared inputs")
    initial = manifest.get("guard_before", {}).get("main_build")
    require(isinstance(initial, dict) and initial.get("policy") == args.main_build_policy,
            "Prepared Main build snapshot policy differs")
    require(compare_main_build_snapshots(initial, initial)["accepted"],
            "Prepared Main build snapshot is malformed")


def record_main_build_guard(work, sequence, label, initial, root, policy):
    """Retain one immutable Main-build comparison, including capture failure."""
    require(type(sequence) is int and sequence >= 1 and isinstance(label, str) and label,
            "Invalid Main build guard identity")
    current = None
    capture_error = None
    try:
        current = main_build_snapshot(root, policy)
        comparison = compare_main_build_snapshots(initial, current)
    except Exception as error:
        capture_error = {"type": type(error).__name__, "reason": str(error)}
        # Do not follow/re-read an unsafe replacement just to manufacture an
        # after-hash. All initial cache records remain bound; current is explicit
        # unavailable evidence and the guard refuses before the next command.
        initial_caches = initial.get("cache_audit", {}) if isinstance(initial, dict) else {}
        comparison = {"accepted": False, "reasons": ["Main build snapshot capture failed"],
                      "cache_audit": {path: {"before": copy.deepcopy(value), "after": None,
                          "capture_error": dict(capture_error)} for path, value in initial_caches.items()}}
    record = {"schema": "arbor.main-build.guard-comparison.v1", "domain": "Main_build",
              "sequence": sequence, "guard_label": label, "policy": policy,
              "initial_snapshot": initial, "current_snapshot": current,
              "accepted": comparison["accepted"], "reasons": comparison["reasons"],
              "cache_audit": comparison["cache_audit"], "capture_error": capture_error}
    folder = work / "main-build-guards"
    folder.mkdir(mode=0o700, exist_ok=True)
    path = folder / f"{sequence:04d}.json"
    with path.open("x") as output:
        output.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return comparison, {"guard_label": label, "path": str(path.relative_to(work)),
                        "sha256": sha(path.read_bytes()), "accepted": comparison["accepted"],
                        "reasons": comparison["reasons"]}


def prepare(args):
    repository, main, fixture_root, cache = args.repository, args.main_root, args.fixtures_root, args.deps_source_cache
    require(repository != main and not (repository / ".env").exists(), "Use a candidate without dotenv")
    require(fixture_root == repository, "--fixtures-root must be the same reviewed repository root")
    initial_bytes = args.initial_manifest.read_bytes()
    require(sha(initial_bytes) == args.initial_manifest_sha256, "Initial manifest pin differs")
    initial = json.loads(initial_bytes)
    require(initial["main"] == BASE == args.main_head, "Actual predecessor Main pin differs")
    require(str(repository) == initial["worktree"] and args.branch == initial["branch"], "Candidate lease differs")
    for root, head, branch in ((main, args.main_head, "main"), (repository, args.head, args.branch)):
        require(git(root, "rev-parse", "HEAD").decode().strip() == head, "Source head moved")
        require(git(root, "branch", "--show-current").decode().strip() == branch, "Source branch moved")
        require(git(root, "status", "--porcelain=v1", "--untracked-files=all") == b"", "Source must be committed/clean")
    require(git_state(main)["stash_list_sha256"] == initial["stash_list_sha256"], "Stash differs from initial manifest")
    require(not args.work_dir.exists(), "Fresh attempt label required; never overwrite evidence")
    require(not any(args.work_dir.is_relative_to(root) for root in (repository, cache, fixture_root)),
            "Output cannot be inside candidate, read-only cache or fixture sources")
    if args.work_dir.is_relative_to(main):
        require(args.work_dir.is_relative_to(main / "tmp/verification"), "Main output must be ignored verification evidence")
        ignored = subprocess.run(["git", "-C", str(main), "check-ignore", "--quiet", str(args.work_dir)])
        require(ignored.returncode == 0, "Main evidence output is not ignored")
    for root in (main, repository, cache, fixture_root):
        require(not args.work_dir.is_relative_to(root / "_build") and not root.is_relative_to(args.work_dir), "Unsafe output/input overlap")
    tool_paths = {"mix": args.mix, "erl": args.erlang_root / "bin/erl", "epmd": args.erlang_root / "bin/epmd",
                  "elixir": args.elixir_root / "bin/elixir", "elixir_mix": args.elixir_root / "bin/mix",
                  "cc": args.cc, "make": args.make, "rebar3": args.rebar3}
    for name, path in tool_paths.items():
        require(path.is_file() and os.access(path, os.X_OK), "Missing pinned executable " + name)
    sdk = native_sdk_inputs(args)
    tool_versions = (repository / ".tool-versions").read_bytes()
    require(tool_versions == (main / ".tool-versions").read_bytes(), "Toolchain pins differ")
    otp = re.search(rb'(?m)^erlang\s+(\S+)', tool_versions).group(1).decode()
    elixir = re.search(rb'(?m)^elixir\s+(\S+)', tool_versions).group(1).decode().split("-otp-", 1)[0]
    require((args.erlang_root / "releases" / otp.split(".")[0] / "OTP_VERSION").read_text().strip() == otp,
            "Pinned OTP installation differs")
    published = {name: source_files(repository / "packages" / name, spec[1], sources_only=True)
                 for name, spec in PACKAGES.items()}
    fixtures = {name: source_files(fixture_source_root(fixture_root, name), FIXTURE_INPUTS, sources_only=True) for name in CONTEXTS}
    dependencies = {name: source_files(cache / name, excludes=CACHE_EXCLUDES, sources_only=True)
                    for name in sorted(TRUST_PUBLIC | SQL_PUBLIC)}
    require(all(".hex" in files for files in dependencies.values()), "Source cache lacks a Hex checkout marker")
    hex_files = source_files(args.hex_archive)
    require(args.hex_archive.name.startswith("hex-"), "Pin installed Hex tool archive")
    runner_files = {name: sha((Path(__file__).parent / name).read_bytes())
                    for name in (Path(__file__).name, "cold_support.py", NATIVE_PROBE)}
    before = {"main": git_state(main), "candidate": git_state(repository), "main_build": main_build_snapshot(main / "_build", args.main_build_policy),
              "main_dotenv": metadata(main / ".env"), "operator": operator_state()}
    work = args.work_dir
    work.mkdir(mode=0o700, parents=True)
    for folder in ("archives", "metadata", "producers", "contexts", "tool-archives", "mix-home", "hex-home", "rebar-cache", "rebar-config"):
        (work / folder).mkdir(mode=0o700)
    native = work / "native-preflight"
    native.mkdir(mode=0o700)
    with (native / NATIVE_PROBE).open("xb") as output:
        output.write((Path(__file__).parent / NATIVE_PROBE).read_bytes())
    copy_files(args.hex_archive, work / "tool-archives" / args.hex_archive.name, hex_files)
    all_records = lock_records((repository / "mix.lock").read_bytes())
    public_lock = make_lock(all_records, TRUST_PUBLIC | SQL_PUBLIC)
    for name in PACKAGES:
        producer = work / "producers" / name
        copy_files(repository / "packages" / name, producer, published[name])
        (producer / "mix.lock").write_bytes(public_lock)
    for name, (packages, deps, _app, _module, _phases) in CONTEXTS.items():
        context = work / "contexts" / name
        context.mkdir(mode=0o700)
        (context / "packages").mkdir(mode=0o700)
        (context / "deps").mkdir(mode=0o700)
        copy_files(fixture_source_root(fixture_root, name), context / "consumer", fixtures[name])
        (context / "consumer/mix.lock").write_bytes(make_lock(all_records, deps))
        for dep in sorted(deps):
            copy_files(cache / dep, context / "deps" / dep, dependencies[dep])
        for folder in ("runtime/tmp", "runtime/home", "runtime/data", "state/authority", "state/independent-revocations"):
            (context / folder).mkdir(mode=0o700, parents=True, exist_ok=True)
        (context / "runtime/empty.env").write_text("")
        (context / "state/session-secret").write_text(secrets.token_hex(32))
        os.chmod(context / "state/session-secret", 0o600)
    expected_metadata = {name: {"version": spec[0], "requirements": REQUIREMENTS[name], "optional": OPTIONAL.get(name, [])}
                         for name, spec in PACKAGES.items()}
    save_json(work / "expected-metadata.json", expected_metadata)
    manifest = {"schema": "arbor.trust-historian.cold-inputs.v1", "args": {key: str(value) if isinstance(value, Path) else value
                 for key, value in vars(args).items() if key not in ("prepare", "run")},
                "main_build_policy": args.main_build_policy, "guard_before": before, "published": published, "fixtures": fixtures, "dependency_sources": dependencies,
                "hex_tool": hex_files, "tool_sha256": {name: sha(path.read_bytes()) for name, path in tool_paths.items()},
                "runner_files": runner_files, "native_sdk": sdk, "tool_versions_sha256": sha(tool_versions), "otp": otp, "elixir": elixir,
                "root_public_lock_sha256": sha(public_lock), "rollback_manifest_sha256": sha(args.rollback_manifest.read_bytes()) if args.rollback_manifest else None,
                "first_party_cache_seeded": 0, "third_party_cache_seeded": 0}
    save_json(work / "source-manifest.json", manifest)
    save_json(work / "results.json", {"status": "prepared", "source_manifest_sha256": sha((work / "source-manifest.json").read_bytes()), "steps": []})
    print("Prepared source-only immutable attempt:", work)


def run(args):
    work = args.work_dir
    manifest_path = work / "source-manifest.json"
    pinned_manifest = manifest_path.read_bytes()
    manifest = json.loads(pinned_manifest)
    require_prepared_main_build_policy(args, manifest)
    require(manifest["args"] == {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()
                                if key not in ("prepare", "run")}, "Run arguments differ from prepared inputs")
    state = json.loads((work / "results.json").read_text())
    require(state["status"] == "prepared" and state["source_manifest_sha256"] == sha(pinned_manifest), "Attempt already ran or manifest changed")
    cookie = "paired_cold_" + secrets.token_hex(32)
    cookie_sha = sha(cookie.encode())
    state.update(status="running", cookie_sha256=cookie_sha, steps=[], main_build_guards=[])
    daemon = daemon_log = None
    port = None
    save = lambda: save_json(work / "results.json", state)

    def guard(label):
        comparison, reference = record_main_build_guard(
            work, len(state["main_build_guards"]) + 1, label,
            manifest["guard_before"]["main_build"], args.main_root / "_build", args.main_build_policy)
        state["main_build_guards"].append(reference)
        save()
        require(manifest_path.read_bytes() == pinned_manifest, "Prepared manifest changed")
        require(comparison["accepted"], "Main build policy guard changed; HOLD: " + "; ".join(comparison["reasons"]))
        actual_other_guards = {"main": git_state(args.main_root), "candidate": git_state(args.repository),
                               "main_dotenv": metadata(args.main_root / ".env"), "operator": operator_state()}
        initial_other_guards = {key: value for key, value in manifest["guard_before"].items() if key != "main_build"}
        require(actual_other_guards == initial_other_guards,
                "Main/candidate/stash/dotenv/operator guard changed; HOLD")
        require(sha(args.initial_manifest.read_bytes()) == args.initial_manifest_sha256, "Initial manifest changed")
        if args.rollback_manifest:
            require(sha(args.rollback_manifest.read_bytes()) == manifest["rollback_manifest_sha256"], "Pinned predecessor manifest changed")
        require({name: source_files(args.repository / "packages" / name, spec[1], sources_only=True) for name, spec in PACKAGES.items()}
                == manifest["published"], "Published source input changed")
        require({name: source_files(fixture_source_root(args.fixtures_root, name), FIXTURE_INPUTS, sources_only=True) for name in CONTEXTS}
                == manifest["fixtures"], "Consumer draft/source changed")
        require({name: source_files(args.deps_source_cache / name, excludes=CACHE_EXCLUDES, sources_only=True)
                 for name in manifest["dependency_sources"]} == manifest["dependency_sources"], "Read-only source cache changed")
        for name, digest in manifest["runner_files"].items():
            require(sha((Path(__file__).parent / name).read_bytes()) == digest, "Runner source changed")
        paths = {"mix": args.mix, "erl": args.erlang_root / "bin/erl", "epmd": args.erlang_root / "bin/epmd", "elixir": args.elixir_root / "bin/elixir",
                 "elixir_mix": args.elixir_root / "bin/mix", "cc": args.cc, "make": args.make, "rebar3": args.rebar3}
        require({name: sha(path.read_bytes()) for name, path in paths.items()} == manifest["tool_sha256"], "Pinned tool changed")
        require(source_files(args.hex_archive) == manifest["hex_tool"], "Pinned Hex tool changed")
        require(native_sdk_inputs(args) == manifest["native_sdk"], "Pinned SDK/developer/probe inputs changed")
        require(sha((work / "native-preflight" / NATIVE_PROBE).read_bytes()) == manifest["native_sdk"]["probe_source_sha256"],
                "Copied native preflight source changed")
        for context, (packages, _deps, _app, _module, _phases) in CONTEXTS.items():
            folder = work / "contexts" / context
            copied = folder / "source-hidden" if (folder / "source-hidden").exists() else folder
            for package in packages:
                path = copied / "packages" / package
                if path.exists():
                    require(source_files(path, PACKAGES[package][1], sources_only=True) == manifest["published"][package],
                            "Copied artifact source changed: " + context + "/" + package)
            require(source_files(copied / "consumer", FIXTURE_INPUTS, sources_only=True) == manifest["fixtures"][context],
                    "Copied consumer source changed: " + context)
            expected_lock = make_lock(lock_records((args.repository / "mix.lock").read_bytes()), CONTEXTS[context][1])
            require((copied / "consumer/mix.lock").read_bytes() == expected_lock, "Copied exact public lock changed")

    def env_for(label, context=None):
        folder = work / "contexts" / context if context else work / ("producer-runtime-" + label)
        for name in ("runtime/tmp", "runtime/home", "runtime/data"):
            (folder / name).mkdir(mode=0o700, parents=True, exist_ok=True)
        (folder / "runtime/empty.env").touch(exist_ok=True)
        inetrc = folder / "runtime/inetrc"
        aliases = sorted({"localhost", socket.gethostname(), socket.gethostname().split(".")[0]})
        inetrc.write_text('{host, {127,0,0,1}, ' + json.dumps(aliases) + '}.\n{lookup, [file]}.\n')
        env = {"HOME": str(Path.home()), "LANG": "C.UTF-8",
               "PATH": native_path(args),
               "MIX_ENV": "prod", "MIX_BUILD_PATH": str(folder / "_build/prod"),
               "MIX_DEPS_PATH": str(folder / "deps"), "MIX_HOME": str(work / "mix-home"),
               "MIX_ARCHIVES": str(work / "tool-archives"), "HEX_HOME": str(work / "hex-home"), "HEX_OFFLINE": "1",
               "MIX_REBAR3": str(args.rebar3), "REBAR_CACHE_DIR": str(work / "rebar-cache"), "REBAR_GLOBAL_CONFIG_DIR": str(work / "rebar-config"),
               "CC": str(args.cc), "MAKE": str(args.make), "CARGO_NET_OFFLINE": "true",
               "SDKROOT": str(args.sdk_root), "DEVELOPER_DIR": str(args.developer_dir),
               "ARBOR_MIX_CONTAINED": "1", "ARBOR_ERLANG_ROOT": str(args.erlang_root), "ARBOR_ELIXIR_ROOT": str(args.elixir_root),
               "ARBOR_HOME": str(folder / "runtime/home"), "ARBOR_DATA_DIR": str(folder / "runtime/data"),
               "ARBOR_ENV_PATH": str(folder / "runtime/empty.env"), "TMPDIR": str(folder / "runtime/tmp"), "ERL_INETRC": str(inetrc),
               "ERL_EPMD_PORT": str(port), "ERL_EPMD_ADDRESS": "127.0.0.1",
               "ERL_FLAGS": f"+S 4:4 -setcookie {cookie} -kernel inet_dist_use_interface {{127,0,0,1}}",
               "PAIRED_COOKIE_SHA256": cookie_sha, "PAIRED_OTP_MAJOR": manifest["otp"].split(".")[0], "PAIRED_ELIXIR_VERSION": manifest["elixir"],
               "PAIRED_C_SOURCE_SHA256": manifest["published"]["arbor_support"]["c_src/arbor_safe_path_reader.c"],
               "PAIRED_ALLOWED_CODE_ROOTS": "|".join(map(str, (folder, work / "tool-archives", args.erlang_root, args.elixir_root))), "PAIRED_NO_MIX": "0"}
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            env[key] = "http://127.0.0.1:1"
        env.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
        if context:
            packages = CONTEXTS[context][0]
            env.update({key: str(folder / "packages" / package) for key, package in OVERRIDES.items() if package in packages})
            root = folder / "state"
            env.update(PAIRED_STATE_ROOT=str(root), PAIRED_CONTEXT=context, PAIRED_EXPECTED_APPS=",".join(sorted(packages)),
                       PAIRED_EXPECTED_STARTED=",".join(sorted(packages)), PAIRED_PHASE="verify",
                       CAPABILITIES_COLD_STATE_ROOT=str(root), CAPABILITIES_COLD_SESSION_SECRET=(root / "session-secret").read_text(),
                       PAIRED_SQL_DATABASE=str(root / "paired.sqlite3"), PAIRED_METADATA_ROOT=str(work / "metadata"),
                       PAIRED_EXPECTED_METADATA=str(work / "expected-metadata.json"))
        return env

    def scenario_environment(env, folder, context, phase, release):
        env = dict(env, PAIRED_PHASE=phase)
        if context == "trust":
            root = folder / ("release-state-" if release else "normal-state-") / phase
            for path in (root, root / "authority", root / "independent-revocations"):
                path.mkdir(mode=0o700, parents=True, exist_ok=False)
            env.update(TRUST_COLD_SCENARIO=phase, PAIRED_STATE_ROOT=str(root), CAPABILITIES_COLD_STATE_ROOT=str(root),
                       CAPABILITIES_COLD_SESSION_SECRET=secrets.token_hex(32))
            if phase in ("runtime_unavailable", "profile_sync_unavailable"):
                env["PAIRED_EXPECTED_STARTED"] = ",".join(sorted(set(TRUST) - {"arbor_trust"}))
        return env

    def command(label, cwd, env, argv, mix=True):
        guard("before:" + label)
        require(daemon.poll() is None and names(port) == "", "Owned EPMD is not empty before command")
        require(not (cwd / ".env").exists() and Path(env["ARBOR_ENV_PATH"]).read_bytes() == b"", "Unexpected dotenv input")
        if mix:
            require(Path(shutil.which("cc", path=env["PATH"])).resolve() == args.cc, "SafePath cc lookup differs from pin")
        executable = [str(args.mix), *argv] if mix else argv
        entry = {"label": label, "argv": executable, "cwd": str(cwd), "status": "running"}
        state["steps"].append(entry)
        save()
        output, errors = work / (label + ".stdout.log"), work / (label + ".stderr.log")
        began = time.monotonic()
        print("START", label, flush=True)
        with output.open("xb") as out, errors.open("xb") as err:
            process = None
            try:
                process = subprocess.Popen(executable, cwd=cwd, env=env, stdout=out, stderr=err, start_new_session=True)
                entry["owned_pid"] = process.pid
                save()
                phase_timeout = max(args.timeout, 3600) if label == "composed-retirement" else args.timeout
                code = process.wait(timeout=phase_timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
                code = 124
            except BaseException as error:
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                out.flush()
                err.flush()
                entry.update(status="interrupted_or_launch_failed", error=type(error).__name__,
                             stdout_sha256=sha(output.read_bytes()), stderr_sha256=sha(errors.read_bytes()))
                save()
                raise
        entry.update(exit_code=code, elapsed_seconds=round(time.monotonic() - began, 3), status="passed" if code == 0 else "failed",
                     stdout_sha256=sha(output.read_bytes()), stderr_sha256=sha(errors.read_bytes()))
        save()
        guard("after:" + label)
        require(daemon.poll() is None and names(port) == "", "Owned EPMD is not empty after command")
        print("END", label, code, flush=True)
        require(code == 0, label + " failed; HOLD; inspect retained private logs; no retry/fallback")
        return output

    try:
        guard("run-start")
        require(args.rollback_manifest is not None, "Composed acceptance requires an actual predecessor rollback manifest; HOLD")
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        require(port != 4369, "Private non-default EPMD port required")
        daemon_log = (work / "epmd.log").open("xb")
        daemon = subprocess.Popen([str(args.erlang_root / "bin/epmd"), "-port", str(port), "-address", "127.0.0.1"],
                                  env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}, stdout=daemon_log, stderr=subprocess.STDOUT)
        state.update(epmd_pid=daemon.pid, epmd_port=port)
        save()
        for _ in range(100):
            require(daemon.poll() is None, "Owned foreground EPMD exited")
            try:
                require(names(port) == "", "Private realm already occupied")
                break
            except (OSError, TimeoutError):
                time.sleep(0.05)
        else:
            raise RuntimeError("Owned EPMD did not become ready")
        # Harmless native gate before the first package/source compilation.
        # Same direct include/link/execute probe that qualified predecessor05.
        native = work / "native-preflight"
        native_env = env_for("native-preflight")
        native_binary = native / "native-header-link-probe"
        require(not native_binary.exists(), "Native preflight output already exists; no retry")
        command("native-header-link-compile", native, native_env,
                [str(args.cc), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-D_DARWIN_C_SOURCE", "-D_GNU_SOURCE", "-D_POSIX_C_SOURCE=200809L",
                 str(native / NATIVE_PROBE), "-o", str(native_binary)], mix=False)
        command("native-header-link-execute", native, native_env, [str(native_binary)], mix=False)
        state["native_preflight"] = {"passed": True,
            "source_sha256": manifest["native_sdk"]["probe_source_sha256"],
            "binary_sha256": sha(native_binary.read_bytes()),
            "sdk_inputs_sha256": sha(json.dumps(manifest["native_sdk"], sort_keys=True).encode()),
            "SDKROOT": str(args.sdk_root), "DEVELOPER_DIR": str(args.developer_dir)}
        save()
        for name, (version, _files) in PACKAGES.items():
            producer = work / "producers" / name
            env = env_for(name)
            archive = work / "archives" / f"{name}-{version}.tar"
            command("hex-build-" + name, producer, env, ["hex.build", "--output", str(archive)])
            state.setdefault("archives", {})[name] = {}
            for context, (packages, _deps, _app, _module, _phases) in CONTEXTS.items():
                if name in packages:
                    state["archives"][name][context] = unpack_archive(archive, work / "contexts" / context / "packages" / name,
                        manifest["published"][name], work / "metadata" / (name + ".config") if not (work / "metadata" / (name + ".config")).exists()
                        else work / "metadata" / (name + "-" + context + ".config"))
            save()
        for context, (packages, _deps, app, _module, phases) in CONTEXTS.items():
            folder = work / "contexts" / context
            consumer = folder / "consumer"
            env = env_for(context, context)
            command(context + "-deps-compile", consumer, env, ["deps.compile"])
            if context == "composed":
                nif = folder / "_build/prod/lib/exqlite/priv/sqlite3_nif.so"
                require(nif.is_file(), "Fresh source-built SQLite NIF missing")
                state["sqlite_native"] = {"binary_sha256": sha(nif.read_bytes()),
                  "amalgamation_source_sha256": manifest["dependency_sources"]["exqlite"]["c_src/sqlite3.c"],
                  "makefile_sha256": manifest["dependency_sources"]["exqlite"]["Makefile"], "precompiled_seeded": False}
                save()
            for name in packages:
                command(context + "-strict-" + name, folder / "packages" / name, env,
                        ["do", "loadconfig", str(consumer / "config/config.exs") + ",", "compile", "--no-deps-check", "--force", "--warnings-as-errors"])
            command(context + "-strict-consumer", consumer, env, ["compile", "--warnings-as-errors"])
            metadata_log = command(context + "-metadata", consumer, env, ["run", "--no-start", "--no-compile", "-e", METADATA_PROBE])
            require("PAIRED_METADATA_OK" in metadata_log.read_text(), "Actual public Hex metadata gate did not run")
            normal = {}
            scenarios = ("full", "activation_only", "runtime_unavailable", "profile_sync_unavailable") if context == "trust" else phases
            for phase in scenarios:
                if context == "composed" and phase == "namespace_seed":
                    before = namespace_snapshot(folder / "state/authority")
                    snapshot = work / "namespace-pre-seed"
                    snapshot.mkdir(mode=0o700)
                    for name in before:
                        copy_files(folder / "state/authority" / name, snapshot / name,
                                   source_files(folder / "state/authority" / name))
                    state["namespace_before"] = before
                    save()
                phase_env = scenario_environment(env, folder, context, phase, release=False)
                log = command(context + "-" + phase, consumer, phase_env,
                              ["run", "--no-compile", "-e", probe(context, phase, False)])
                normal[phase] = parse_result(log)
                if context == "composed" and phase == "namespace_seed":
                    after = namespace_snapshot(folder / "state/authority")
                    before = state["namespace_before"]
                    require(set(after) == set(before), "Exact public seed unexpectedly changed namespace roster")
                    changed = [name for name in before if set(after[name]) - set(before[name])]
                    require(len(changed) == 1 and len(set(after[changed[0]]) - set(before[changed[0]])) == 1,
                            "Exact grant must add one record to exactly one actual namespace")
                    state["capability_namespace"] = changed[0]
                    state["namespace_after_seed"] = after
                    save()
                if context == "composed" and phase == "retirement":
                    require(normal[phase].get("retirement_qualified") is True,
                            "Original journal-retirement threshold was not proved")
            release = folder / "release"
            command(context + "-release-build", consumer, env, ["release", app, "--path", str(release)])
            require(any(release.glob("erts-*/bin/erl")), "Release must include ERTS")
            if context == "composed":
                copies = list(release.glob("lib/exqlite-*/priv/sqlite3_nif.so"))
                require(len(copies) == 1 and sha(copies[0].read_bytes()) == state["sqlite_native"]["binary_sha256"],
                        "Release did not preserve exact fresh SQLite NIF")
            for vm_args in release.glob("releases/*/vm.args"):
                active = "\n".join(line.split("#", 1)[0] for line in vm_args.read_text().splitlines())
                require(not re.search(r"-(?:name|sname|setcookie)\b", active), "Release contains unqualified node/cookie flags")
            state.setdefault("contexts", {})[context] = {"normal": normal}
            save()
        hidden_global = work / "source-hidden-global"
        hidden_global.mkdir(mode=0o700)
        for item in ("producers", "tool-archives", "mix-home", "hex-home", "rebar-cache", "rebar-config"):
            (work / item).rename(hidden_global / item)
        for context, (packages, _deps, app, _module, _phases) in CONTEXTS.items():
            folder = work / "contexts" / context
            env = env_for(context, context)
            release = folder / "release"
            hidden = folder / "source-hidden"
            hidden.mkdir(mode=0o700)
            for item in ("packages", "deps", "consumer", "_build"):
                (folder / item).rename(hidden / item)
            phases = ("full", "activation_only", "runtime_unavailable", "profile_sync_unavailable") if context == "trust" else ("refused",) if context == "composed" else ("verify",)
            for phase in phases:
                release_env = scenario_environment(env, folder, context, phase, release=True)
                release_env.update(ERL_FLAGS="+S 4:4 -kernel inet_dist_use_interface {127,0,0,1}",
                                   RELEASE_COOKIE=cookie, RELEASE_DISTRIBUTION="none", RELEASE_TMP=str(folder / "runtime/tmp"),
                                   PAIRED_NO_MIX="1", PAIRED_RELEASE_ROOT=str(release), PAIRED_ALLOWED_CODE_ROOTS=str(release),
                                   PATH="/usr/bin:/bin:/usr/sbin:/sbin")
                for key in list(release_env):
                    if key.startswith(("MIX_", "HEX_", "ARBOR_")) and key not in ("ARBOR_HOME", "ARBOR_DATA_DIR", "ARBOR_ENV_PATH"):
                        release_env.pop(key)
                log = command(context + "-source-hidden-release-" + phase, release, release_env,
                              [str(release / "bin" / app), "eval", probe(context, phase, True)], mix=False)
                released = parse_result(log)
                require(released["mix_available"] is False, "Mix was present in source-hidden release")
                require(released["native_binary_sha256"] == next(iter(state["contexts"][context]["normal"].values()))["native_binary_sha256"],
                        "Embedded native binary changed")
                state["contexts"][context].setdefault("source_hidden_release", {})[phase] = released
                save()
        run_candidate_attacks(work, state, command, env_for, cookie)
        run_rollback(args.rollback_manifest, work, state, command, env_for, cookie)
        guard("acceptance-final")
        state["status"] = "passed"
    except BaseException as error:
        state.update(status="HOLD", error=f"{type(error).__name__}: {error}")
        raise
    finally:
        if daemon is not None:
            try:
                state["remaining_names"] = names(port) if daemon.poll() is None else "owned daemon exited"
                require(state["remaining_names"] == "", "Owned EPMD names remain; HOLD")
            except BaseException as error:
                state.update(status="HOLD", cleanup_error=str(error))
            if daemon.poll() is None:
                daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)
            state["epmd_exit_code"] = daemon.returncode
        if daemon_log:
            daemon_log.close()
        try:
            guard("cleanup-final")
            state["final_guards_passed"] = True
        except BaseException as error:
            state.update(status="HOLD", final_guard_error=str(error))
            raise
        finally:
            save()
    require(state["status"] == "passed", "Acceptance HOLD after cleanup")
    print("Passed all three contexts and actual predecessor rollback; retained:", work)


def namespace_snapshot(authority):
    result = {}
    for directory in sorted(authority.glob("ns_*")):
        require(directory.is_dir() and not directory.is_symlink(), "Unsafe owned authority namespace")
        result[directory.name] = sorted(path.name for path in directory.iterdir()
                                        if path.is_file() and not path.name.startswith("."))
    require(result, "Actual authority has no admitted namespace directories")
    return result


def run_candidate_attacks(work, state, command, env_for, cookie):
    """Independent private state branches preserve the clean main/rollback state."""
    source = work / "contexts/composed/state"
    release = work / "contexts/composed/release"
    for phase in ("conflict", "namespace_rollback_attack"):
        target = work / ("candidate-" + phase + "-state")
        copy_files(source, target, source_files(source))
        if phase == "namespace_rollback_attack":
            namespace = state["capability_namespace"]
            current = target / "authority" / namespace
            preserved = work / "namespace-current-preserved"
            preserved.mkdir(mode=0o700)
            current.rename(preserved / namespace)
            old = work / "namespace-pre-seed" / namespace
            copy_files(old, current, source_files(old))
            require(namespace_snapshot(target / "authority")[namespace] == state["namespace_before"][namespace],
                    "Namespace-only restore did not match the actual pre-seed snapshot")
        env = env_for("attack", "composed")
        env.update(PAIRED_STATE_ROOT=str(target), CAPABILITIES_COLD_STATE_ROOT=str(target),
                   CAPABILITIES_COLD_SESSION_SECRET=(target / "session-secret").read_text(), PAIRED_SQL_DATABASE=str(target / "paired.sqlite3"),
                   PAIRED_PHASE=phase, PAIRED_NO_MIX="1", PAIRED_RELEASE_ROOT=str(release), PAIRED_ALLOWED_CODE_ROOTS=str(release),
                   ERL_FLAGS="+S 4:4 -kernel inet_dist_use_interface {127,0,0,1}", RELEASE_COOKIE=cookie,
                   RELEASE_DISTRIBUTION="none", RELEASE_TMP=str(work / "contexts/composed/runtime/tmp"), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        for key in list(env):
            if key.startswith(("MIX_", "HEX_", "ARBOR_")) and key not in ("ARBOR_HOME", "ARBOR_DATA_DIR", "ARBOR_ENV_PATH"):
                env.pop(key)
        log = command("candidate-" + phase, release, env, [str(release / "bin/paired_standalone_consumer"), "eval", probe("composed", phase, True)], mix=False)
        result = parse_result(log)
        require(result.get("pending_conflict") == 1, "Conflict/namespace attack did not retain exact real pending evidence")
        state.setdefault("candidate_attacks", {})[phase] = result
    # These are intentionally non-quiescent evidence branches. Neither is the
    # actual predecessor version rollback, and neither may replace its state.


def run_rollback(path, work, state, command, env_for, cookie):
    """Actual predecessor raw-driver gate. Only its owned state argument is substituted."""
    data = path.read_bytes()
    value = json.loads(data)
    require(value.get("schema") == "arbor.trust-historian.rollback.v1" and value.get("head") == BASE,
            "Actual predecessor rollback manifest required")
    repository = Path(value["repository"])
    require(repository.is_absolute(), "Actual predecessor source path must be absolute")
    require(git(repository, "rev-parse", "HEAD").decode().strip() == BASE and
            git(repository, "status", "--porcelain=v1", "--untracked-files=all") == b"", "Rollback source provenance differs")
    require(git(repository, "rev-parse", "HEAD^{tree}").decode().strip() == value["tree"], "Predecessor tree differs")
    files = value["files"]
    require(isinstance(files, dict) and files and value.get("authority_sources_sha256") and value.get("probe_source_sha256"),
            "Rollback production source/PROD code/driver/config provenance incomplete")
    def rollback_guard():
        require(path.read_bytes() == data, "Rollback manifest changed")
        for name, digest in files.items():
            file = Path(name)
            require(file.is_absolute() and file.is_file() and not file.is_symlink() and sha(file.read_bytes()) == digest,
                    "Pinned rollback input changed")
    rollback_guard()
    argv = value["argv"]
    require(isinstance(argv, list) and argv and all(isinstance(arg, str) and "\0" not in arg for arg in argv), "Invalid driver argv")
    require(Path(argv[0]).is_absolute() and argv[0] in files and os.access(argv[0], os.X_OK), "Unpinned actual predecessor driver")
    require(not any(arg in ("--state-root", "--phase", "-setcookie", "-name", "-sname") for arg in argv), "Only coordinator supplies state/phase/cookie")
    require(value.get("prod_compiled") is True and value.get("driver_compiled") is True and value.get("mix_execution") is False,
            "Actual PROD/sealed compiled raw-driver contract missing; draft producer metadata is not rollback proof")
    original = work / "contexts/composed/state"
    target = work / "rollback-state"
    copy_files(original, target, source_files(original))
    env = env_for("rollback", "composed")
    env.update(PAIRED_STATE_ROOT=str(target), CAPABILITIES_COLD_STATE_ROOT=str(target), PAIRED_SQL_DATABASE=str(target / "paired.sqlite3"),
               CAPABILITIES_COLD_SESSION_SECRET=(target / "session-secret").read_text(), PAIRED_PHASE="refused",
               PAIRED_ROLLBACK_BASE=BASE, ERL_FLAGS=f"+S 4:4 -setcookie {cookie} -kernel inet_dist_use_interface {{127,0,0,1}}",
               PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    for key in list(env):
        if key.startswith(("MIX_", "HEX_", "ARBOR_")) and key not in ("ARBOR_HOME", "ARBOR_DATA_DIR", "ARBOR_ENV_PATH"):
            env.pop(key)
    log = command("actual-predecessor-rollback", Path(value["cwd"]), env,
                  argv + ["--state-root", str(target), "--phase", "verify"], mix=False)
    rows = [json.loads(line.split("=", 1)[1]) for line in log.read_text().splitlines() if line.startswith("PAIRED_ROLLBACK_RESULT=")]
    require(len(rows) == 1 and all(rows[0].get(key) is True for key in
            ("same_authority", "same_profiles", "same_audit_receipts", "revoked_authority_refused", "production_owners_proven", "quiescent")),
            "Actual predecessor compatible-state proof incomplete")
    require(rows[0].get("head") == BASE and rows[0].get("mix_available") is False,
            "Raw predecessor driver did not prove exact actual base/no-Mix execution")
    rollback_guard()
    candidate_release = work / "contexts/composed/release"
    env.update(PAIRED_NO_MIX="1", PAIRED_EXPECTED_APPS=",".join(sorted(PACKAGES)), PAIRED_EXPECTED_STARTED=",".join(sorted(PACKAGES)),
               PAIRED_RELEASE_ROOT=str(candidate_release), PAIRED_ALLOWED_CODE_ROOTS=str(candidate_release),
               ERL_FLAGS="+S 4:4 -kernel inet_dist_use_interface {127,0,0,1}", RELEASE_COOKIE=cookie,
               RELEASE_DISTRIBUTION="none", RELEASE_TMP=str(work / "contexts/composed/runtime/tmp"))
    log = command("candidate-after-rollback", candidate_release, env,
                  [str(candidate_release / "bin/paired_standalone_consumer"), "eval", probe("composed", "refused", True)], mix=False)
    rollback_guard()
    state["rollback"] = {"manifest_sha256": sha(data), "predecessor": rows[0], "candidate_reopened": parse_result(log)}


def build_argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--run", action="store_true")
    for option in ("repository", "main-root", "work-dir", "fixtures-root", "mix", "erlang-root", "elixir-root", "hex-archive",
                   "cc", "make", "rebar3", "deps-source-cache", "initial-manifest", "sdk-root", "developer-dir"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--rollback-manifest", type=Path)
    for option in ("head", "main-head", "branch", "initial-manifest-sha256"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--main-build-policy", choices=MAIN_BUILD_POLICIES, default="strict")
    return parser


def main():
    args = build_argument_parser().parse_args()
    for key, value in vars(args).items():
        if isinstance(value, Path):
            require(value.expanduser().is_absolute(), "All pinned paths must be absolute: " + key)
            setattr(args, key, value.expanduser().resolve())
    require(all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (args.head, args.main_head)), "Full commit pins required")
    require(re.fullmatch(r"[0-9a-f]{64}", args.initial_manifest_sha256) and args.timeout > 0, "Invalid manifest pin/timeout")
    os.umask(0o077)
    if args.prepare:
        prepare(args)
    else:
        run(args)


if __name__ == "__main__":
    main()
