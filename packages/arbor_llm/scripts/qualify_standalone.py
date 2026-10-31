#!/usr/bin/env python3
"""Offline five-archive LLM qualification; explicit prepare, then pinned run.

Preparation copies only reviewed sources/tools into a new private directory.
Run builds actual Hex archives, fresh dependencies/native code, strict package
and consumer code, and an ERTS release evaluated after owned sources are hidden.
Never fetches, publishes, seeds BEAM caches, edits source, or deletes evidence.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

GUARD_SHA256 = "8beec5f29d2efc13880db83aaa4d871b505f017efbcc1cf99a675d71a034fbd5"
PACKAGES = {
    "arbor_kernel": ("2.0.0-dev", ("lib", "mix.exs", "README.md", "LICENSE", "docs/ADOPTION.md"),
                     {"typed_struct": "~> 0.3", "jason": "~> 1.4", "boundary": "~> 0.10"}),
    "arbor_support": ("0.1.0-dev", ("lib", "c_src", "mix.exs", "README.md", "LICENSE"),
                      {"arbor_kernel": "~> 2.0.0-dev", "boundary": "~> 0.10"}),
    "arbor_oauth": ("0.1.0-dev", ("lib", "mix.exs", "README.md", "LICENSE"),
                    {"jason": "~> 1.4", "req": "~> 0.7.5", "finch": "~> 0.24", "mint": "~> 1.9.3", "boundary": "~> 0.10"}),
    "arbor_signals": ("0.2.0-dev", ("lib", "mix.exs", "README.md", "LICENSE"),
                      {"arbor_kernel": "~> 2.0.0-dev", "jason": "~> 1.4", "typed_struct": "~> 0.3", "telemetry": "~> 1.0", "boundary": "~> 0.10"}),
    "arbor_llm": ("0.1.0", ("lib", "priv", "mix.exs", "README.md", "LICENSE"),
                  {"arbor_kernel": "~> 2.0.0-dev", "arbor_support": "~> 0.1.0-dev", "arbor_oauth": "~> 0.1.0-dev", "arbor_signals": "~> 0.2.0-dev",
                   "jason": "~> 1.4", "telemetry": "~> 1.2", "plug_cowboy": "~> 2.9", "plug": "~> 1.14", "ranch": "~> 2.3", "cowboy": "~> 2.19",
                   "req": "~> 0.7.5", "finch": "~> 0.24", "mint": "~> 1.9.3", "llm_db": "~> 2026.9.6", "req_llm": "~> 1.25.0", "boundary": "~> 0.10"}),
}
DEPENDENCIES = ("abnf_parsec", "boundary", "cowboy", "cowboy_telemetry", "cowlib", "dotenvy", "finch", "hpax", "idna", "jason", "jsv", "llm_db", "mime", "mint", "nimble_options", "nimble_parsec", "nimble_pool", "plug", "plug_cowboy", "plug_crypto", "ranch", "req", "req_llm", "server_sent_events", "splode", "telemetry", "texture", "toml", "typed_struct", "websockex", "zoi")
CONSUMER_FILES = ("lib", "config", "mix.exs", "mix.lock", "README.md")
EXCLUDES = frozenset(("_build", "deps", ".git", ".elixir_ls", "cover", "doc", "ebin"))
POLICIES = ("strict", "reviewed-boundary-view-v2", "reviewed-boundary-view-v2-nine")
SDK_INPUTS = ("SDKSettings.json", "SDKSettings.plist", "usr/lib/libSystem.B.tbd", "usr/include/errno.h", "usr/include/fcntl.h", "usr/include/inttypes.h", "usr/include/stdint.h", "usr/include/stdio.h", "usr/include/stdlib.h", "usr/include/string.h", "usr/include/sys/stat.h", "usr/include/sys/types.h", "usr/include/unistd.h")
NATIVE_PROBE = """#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
int main(void) { return 0; }
"""

# This is build-only projection of existing declared first-party tuples. It does
# not invent dependencies, change versions/runtime options, or edit artifacts.
# Ordinary consumer dependency convergence must pass before this strict rerun.
STRICT_PACKAGE = r'''
app = System.fetch_env!("LLM_COLD_STRICT_APP") |> String.to_existing_atom()
path = System.fetch_env!("LLM_COLD_STRICT_PATH")
roots = Map.new(~w(kernel support oauth signals llm), fn suffix ->
  {String.to_existing_atom("arbor_" <> suffix), System.fetch_env!("ARBOR_" <> String.upcase(suffix) <> "_PATH")}
end)
Mix.Project.in_project(app, path, [], fn _ ->
  deps = Enum.map(Mix.Project.config()[:deps], fn dep ->
    case Map.fetch(roots, elem(dep, 0)) do
      :error -> dep
      {:ok, root} ->
        opts = if tuple_size(dep) == 3, do: elem(dep, 2), else: []
        {elem(dep, 0), elem(dep, 1), opts |> Keyword.put(:path, root) |> Keyword.put(:override, true)}
    end
  end)
  :ok = Mix.ProjectStack.merge_config(deps: deps)
  true = Path.expand(Mix.Project.build_path()) == Path.expand(System.fetch_env!("MIX_BUILD_PATH"))
  true = Path.expand(Mix.Project.deps_path()) == Path.expand(System.fetch_env!("MIX_DEPS_PATH"))
  Mix.Task.clear()
  Mix.Task.run("compile", ["--no-deps-check", "--force", "--warnings-as-errors"])
end)
'''

PROBE_COMMON = r'''
{:ok, [[cookie]]} = :init.get_argument(:setcookie)
expected_cookie = System.fetch_env!("LLM_COLD_COOKIE_SHA256")
^expected_cookie = :crypto.hash(:sha256, List.to_string(cookie)) |> Base.encode16(case: :lower)
false = Node.alive?()
true = System.version() == System.fetch_env!("LLM_COLD_ELIXIR_VERSION")
true = List.to_string(:erlang.system_info(:otp_release)) == System.fetch_env!("LLM_COLD_OTP_MAJOR")
expected_apps = ~w(arbor_kernel arbor_llm arbor_oauth arbor_signals arbor_support)a
# Read real .app terms across the entire fresh output, rather than inferring
# compiled ownership from directory names or the active code path.
approot = System.fetch_env!("LLM_COLD_APP_ROOT")
app_specs = Path.wildcard(Path.join(approot, "*/ebin/*.app")) |> Enum.flat_map(fn file ->
  {:ok, [{:application, app, properties}]} = :file.consult(String.to_charlist(file))
  if String.starts_with?(Atom.to_string(app), "arbor_"), do: [{app, properties}], else: []
end)
^expected_apps = app_specs |> Enum.map(&elem(&1, 0)) |> Enum.sort()
all_modules = Enum.flat_map(app_specs, fn {_app, properties} -> Keyword.fetch!(properties, :modules) end)
true = length(all_modules) == length(Enum.uniq(all_modules))
expected_callbacks = %{arbor_kernel: nil, arbor_support: nil, arbor_oauth: nil,
                      arbor_signals: Arbor.Signals.Application, arbor_llm: Arbor.LLM.Application}
expected_runtime_edges = %{arbor_kernel: [], arbor_support: [:arbor_kernel], arbor_oauth: [],
                          arbor_signals: [:arbor_kernel], arbor_llm: [:arbor_kernel, :arbor_oauth, :arbor_support]}
Enum.each(app_specs, fn {app, properties} ->
  callback = case Keyword.get(properties, :mod) do nil -> nil; {module, []} -> module end
  true = callback == Map.fetch!(expected_callbacks, app)
  dependencies = Keyword.fetch!(properties, :applications) |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "arbor_")) |> Enum.sort()
  true = dependencies == Map.fetch!(expected_runtime_edges, app)
end)
# Load every actual canonical .app module, including modules not in the fixture's
# representative owner list, and verify the real OTP owner/BEAM/source origin.
module_origins = Map.new(expected_apps, fn app ->
  :ok = case Application.load(app) do :ok -> :ok; {:error, {:already_loaded, ^app}} -> :ok end
  {:ok, modules} = :application.get_key(app, :modules)
  true = modules == (List.keyfind(app_specs, app, 0) |> elem(1) |> Keyword.fetch!(:modules))
  true = is_list(modules) and modules != []
  sources = Map.new(modules, fn module ->
    {:module, ^module} = Code.ensure_loaded(module)
    ^app = :application.get_application(module) |> then(fn {:ok, value} -> value end)
    beam = :code.which(module) |> List.to_string() |> Path.expand()
    source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string() |> Path.expand()
    {Atom.to_string(module), %{beam: beam, source: source}}
  end)
  {Atom.to_string(app), sources}
end)
# Exercise the freshly embedded native reader through its public API too.
root = System.fetch_env!("LLM_COLD_STATE_ROOT")
native_path = Path.join(root, "native-public-read.txt")
:ok = File.write(native_path, "llm-public-native-read\n", [:exclusive])
{:ok, "llm-public-native-read\n", ^native_path} = Arbor.Common.SafePath.read_within(native_path, root)
expected_c = System.fetch_env!("LLM_COLD_C_SHA256")
^expected_c = Arbor.Common.SafePath.NativeReaderArtifact.source_sha256()
native_sha = Arbor.Common.SafePath.NativeReaderArtifact.binary_sha256()
'''

NORMAL_PROBE = PROBE_COMMON + r'''
roots = Map.new(~w(kernel support oauth signals llm), fn suffix ->
  {"arbor_" <> suffix, Path.expand(System.fetch_env!("ARBOR_" <> String.upcase(suffix) <> "_PATH")) <> "/"}
end)
Enum.each(module_origins, fn {owner, modules} ->
  Enum.each(modules, fn {module, origin} ->
    true = String.starts_with?(origin.beam, Path.expand(System.fetch_env!("MIX_BUILD_PATH")) <> "/")
    if module == "Elixir.Arbor.Common.SafePath.NativeReaderArtifact" do
      true = String.starts_with?(origin.source, Path.expand(System.fetch_env!("MIX_BUILD_PATH")) <> "/generated/arbor_support/")
    else
      true = String.starts_with?(origin.source, Map.fetch!(roots, owner))
    end
  end)
end)
allowed = System.fetch_env!("LLM_COLD_ALLOWED_CODE_ROOTS") |> String.split("|")
true = Enum.all?(:code.get_path(), fn path ->
  path = Path.expand(List.to_string(path)) <> "/"
  Enum.any?(allowed, &String.starts_with?(path, &1 <> "/"))
end)
metadata = Map.new(~w(arbor_kernel arbor_support arbor_oauth arbor_signals arbor_llm), fn name ->
  {:ok, terms} = :file.consult(String.to_charlist(Path.join(System.fetch_env!("LLM_COLD_METADATA_ROOT"), name <> ".config")))
  item = Map.new(terms)
  {name, %{
    name: item["name"], app: item["app"], version: item["version"], licenses: item["licenses"],
    description: item["description"], links: Map.new(item["links"]), requirements: Enum.map(item["requirements"], &Map.new/1)
  }}
end)
result = LLMStandaloneConsumer.run!()
IO.puts("LLM_QUALIFICATION_RESULT=" <> IO.iodata_to_binary(:json.encode(Map.merge(result, %{module_origins: module_origins, archive_metadata: metadata, native_binary_sha256: native_sha}))))
'''

RELEASE_PROBE = PROBE_COMMON + r'''
root = Path.expand(System.fetch_env!("LLM_COLD_RELEASE_ROOT")) <> "/"
true = String.starts_with?(Path.expand(List.to_string(:code.root_dir())) <> "/", root)
true = Enum.all?(:code.get_path(), &(String.starts_with?(Path.expand(List.to_string(&1)) <> "/", root)))
Enum.each(module_origins, fn {_owner, modules} ->
  Enum.each(modules, fn {_module, origin} -> true = String.starts_with?(origin.beam, root) end)
end)
result = LLMStandaloneConsumer.run!(require_no_mix: true)
IO.puts("LLM_QUALIFICATION_RESULT=" <> IO.iodata_to_binary(:json.encode(Map.merge(result, %{module_origins: module_origins, runtime_root: List.to_string(:code.root_dir()), native_binary_sha256: native_sha}))))
'''


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_guard(path):
    require(path.is_file() and not path.is_symlink() and sha(path.read_bytes()) == GUARD_SHA256,
            "Guard tooling differs from the explicitly reviewed helper; HOLD")
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("llm_cold_reviewed_guard", path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


def public_lock(data):
    records = {}
    for line in data.decode().splitlines():
        match = re.match(r'^  "([^"\n]+)":', line)
        if match and match[1] in DEPENDENCIES:
            name = match[1]
            require(name not in records and line.startswith(f'  "{name}": {{:hex, :{name}, ') and
                    re.search(r', "hexpm", "[0-9a-f]{64}"\},$', line), "Invalid/duplicate public Hex record")
            records[name] = line
    require(set(records) == set(DEPENDENCIES), "Missing reviewed public dependency record")
    return ("%{\n" + "\n".join(records[name] for name in DEPENDENCIES) + "\n}\n").encode()


def check_lock(project, data):
    path = project / "mix.lock"
    require(project.is_dir() and not project.is_symlink() and path.is_file() and not path.is_symlink(), "Private project/lock disappeared")
    value = path.lstat()
    require(stat.S_ISREG(value.st_mode) and value.st_nlink == 1 and path.read_bytes() == data,
            "Private exact public lock changed; HOLD")


def install_lock(project, data):
    with (project / "mix.lock").open("xb") as output:
        output.write(data)
    check_lock(project, data)



def private_input_root(work, relative):
    """Find exactly one retained normal/hidden root; never accept a replacement link."""
    path = Path(relative)
    require(not path.is_absolute() and str(path) == relative and ".." not in path.parts,
            "Noncanonical private input root")
    candidates = (work / path, work / "source-hidden" / path)
    present = [item for item in candidates if item.exists() or item.is_symlink()]
    require(len(present) == 1 and present[0].is_dir() and not present[0].is_symlink(),
            "Private input root missing, ambiguous or replaced by a link")
    require(present[0].resolve(strict=True) == present[0], "Private input has a symlinked ancestor")
    return present[0]


def check_private_inputs(work, records, helper):
    """Exact copied inputs, retaining only explicit compiler-output exclusions."""
    for relative, record in records.items():
        root = private_input_root(work, relative)
        # Rebar emits only private _build/ebin outputs in dependency sources.
        # EXCLUDES also matches the reviewed source-only cache selection; it is
        # never applied to first-party packages, the consumer or the Hex tool.
        excludes = EXCLUDES if record["dependency"] else frozenset()
        actual = helper.source_files(root, excludes=excludes, sources_only=record["dependency"])
        require(actual == record["files"], "Copied private source/tool input changed: " + relative)



def check_archives(work, records, published):
    """Recheck the exact bytes admitted by the original strict Hex unpacker."""
    for name, record in records.items():
        require(name in PACKAGES, "Unknown private archive owner")
        archive = work / "archives" / (name + "-" + PACKAGES[name][0] + ".tar")
        metadata = work / "metadata" / (name + ".config")
        require(archive.is_file() and not archive.is_symlink() and sha(archive.read_bytes()) == record["archive_sha256"] and
                metadata.is_file() and not metadata.is_symlink() and sha(metadata.read_bytes()) == record["metadata_sha256"] and
                record["files"] == published[name], "Verified archive/member/metadata input changed")


def tool_pin(path, root=None):
    require(path.is_file() and os.access(path, os.X_OK), f"Missing pinned executable: {path}")
    target = path.resolve(strict=True)
    if root is not None:
        require(target.is_relative_to(root), "Pinned tool link escapes its installation")
    return {"path": str(path), "target": str(target), "link": os.readlink(path) if path.is_symlink() else None,
            "sha256": sha(target.read_bytes())}


def native_path(args):
    return os.pathsep.join(dict.fromkeys(map(str, (args.cc.parent, args.make.parent, args.erlang_root / "bin",
                                                  args.elixir_root / "bin", Path("/usr/bin"), Path("/bin"), Path("/usr/sbin"), Path("/sbin")))))


def sdk_inputs(args):
    require(args.sdk_root.is_dir() and args.sdk_root.is_relative_to(args.developer_dir / "SDKs"), "SDK must be inside the pinned developer SDKs")
    result = {}
    for relative in SDK_INPUTS:
        path = args.sdk_root / relative
        target = path.resolve(strict=True)
        require(target.is_relative_to(args.sdk_root) and target.is_file(), "SDK critical input escapes pinned SDK")
        result[relative] = {"target": str(target), "sha256": sha(target.read_bytes())}
    selected = shutil.which("cc", path=native_path(args))
    require(selected is not None and Path(selected).resolve() == args.cc.resolve(), "Effective cc differs from pinned compiler")
    return {"SDKROOT": str(args.sdk_root), "DEVELOPER_DIR": str(args.developer_dir), "files": result,
            "probe_sha256": sha(NATIVE_PROBE.encode()), "effective_cc": str(Path(selected).resolve())}


def no_startup_files(roots, *, home):
    # ReqLLM reads cwd/.env only. Home is not a dotenv search root, while its
    # actual VM startup files remain forbidden. If Home is an actual cwd, it
    # is also an explicit root and its .env is rejected in that context.
    contexts = [(root, (".env", ".erlang", ".iex.exs")) for root in roots]
    contexts.append((home, (".erlang", ".iex.exs")))
    for root, names in contexts:
        for name in names:
            path = root / name
            require(not path.exists() and not path.is_symlink(), f"Startup/dotenv input is not qualified: {path}")


def source_inputs(args, helper):
    published = {name: helper.source_files(args.repository / "packages" / name, spec[1]) for name, spec in PACKAGES.items()}
    fixture = helper.source_files(args.repository / "packages/arbor_llm/examples/standalone", CONSUMER_FILES)
    lock = public_lock((args.repository / "mix.lock").read_bytes())
    require((args.repository / "packages/arbor_llm/examples/standalone/mix.lock").read_bytes() == lock,
            "Consumer lock differs from the reviewed 31 public Root records")
    dependencies = {name: helper.source_files(args.deps_source_cache / name, excludes=EXCLUDES, sources_only=True) for name in DEPENDENCIES}
    require(all(".hex" in files for files in dependencies.values()), "Missing pinned Hex source marker")
    return {"published": published, "consumer": fixture, "dependencies": dependencies,
            "hex_tool": helper.source_files(args.hex_archive), "public_lock_sha256": sha(lock)}, lock


def git_guards(args, helper):
    for root, head, branch in ((args.repository, args.head, args.branch), (args.main_root, args.main_head, "main")):
        require(helper.git(root, "rev-parse", "HEAD").decode().strip() == head, "Qualified HEAD moved")
        require(helper.git(root, "branch", "--show-current").decode().strip() == branch, "Qualified branch moved")
        require(helper.git(root, "status", "--porcelain=v1", "--untracked-files=all") == b"", "Qualified source must be clean")
        require(all(record[:1] == b"H" for record in helper.git(root, "ls-files", "-v", "-z").split(b"\0") if record), "Hidden Git index flags are not qualified")
    return {"main": helper.git_state(args.main_root), "candidate": helper.git_state(args.repository),
            "operator": helper.operator_state(), "main_dotenv_metadata": helper.metadata(args.main_root / ".env")}


def validate_metadata(metadata):
    require(isinstance(metadata, dict) and set(metadata) == set(PACKAGES), "Archive metadata must contain exactly five packages")
    for name, (version, _files, requirements) in PACKAGES.items():
        value = metadata[name]
        require(value.get("name") == name and value.get("app") == name and value.get("version") == version, "Archive identity/version mismatch")
        require(value.get("licenses") == ["MIT"] and isinstance(value.get("description"), str) and value["description"].strip() and
                value.get("links") == {"GitHub": "https://github.com/trust-arbor/arbor"}, "Archive public metadata mismatch")
        actual = {}
        for dep in value.get("requirements", []):
            require(isinstance(dep, dict) and set(dep) <= {"name", "app", "requirement", "repository", "optional"} and
                    dep.get("name") not in actual and dep.get("app", dep.get("name")) == dep.get("name") and
                    dep.get("repository") == "hexpm" and dep.get("optional") is False, "Private, duplicate, optional or invalid archive dependency")
            actual[dep["name"]] = dep.get("requirement")
        require(actual == requirements, "Public archive dependency requirements differ")


def result_from(path):
    prefix = "LLM_QUALIFICATION_RESULT="
    values = [json.loads(line[len(prefix):]) for line in path.read_text().splitlines() if line.startswith(prefix)]
    require(len(values) == 1, "Missing/ambiguous actual consumer result")
    value = values[0]
    require(value.get("schema") == "arbor.llm.standalone-consumer.v1" and isinstance(value.get("checks"), list) and len(value["checks"]) >= 17,
            "Missing public acceptance checks")
    require(value.get("facade_groups") == 5 and value.get("tool_effects") == 1 and value.get("audited_effects") == 1 and
            value.get("required_port_refusal_groups") == 3 and value.get("early_stream_halt_closed_wire") is True, "Public LLM behavior gate incomplete")
    expected = sorted(PACKAGES)
    require(value.get("compiled_applications") == expected and value.get("loaded_applications") == expected and
            value.get("started_applications") == sorted(set(expected) - {"arbor_signals"}), "Available/loaded/started application closure differs")
    require(set(value.get("module_origins", {})) == set(expected) and value.get("module_owners") and value.get("bundled_resources"), "Missing real module/resource evidence")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--run", action="store_true")
    path_options = ("repository", "main-root", "work-dir", "mix", "erlang-root", "elixir-root", "hex-archive", "cc", "make", "rebar3", "sdk-root", "developer-dir", "deps-source-cache", "guard-helper")
    for name in path_options:
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("head", "main-head", "branch"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--manifest-sha256")
    parser.add_argument("--main-build-policy", choices=POLICIES, default="strict")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    for name in path_options:
        key = name.replace("-", "_")
        value = getattr(args, key).expanduser()
        require(value.is_absolute() and str(value) == os.path.normpath(str(value)), "Canonical absolute input paths required")
        # Retain exact bin tool symlinks in their separate pinned tool records.
        if key not in ("mix", "cc", "make", "rebar3"):
            require(not value.is_symlink() and value.resolve() == value, "Symlinked source/tool roots are not qualified")
        setattr(args, key, value)
    require(re.fullmatch(r"[0-9a-f]{40}", args.head) and re.fullmatch(r"[0-9a-f]{40}", args.main_head) and args.timeout > 0, "Full reviewed heads/positive timeout required")
    require(args.repository != args.main_root, "Candidate must be a separate worktree")
    work = args.work_dir
    for source in (args.repository, args.main_root, args.deps_source_cache, args.erlang_root, args.elixir_root, args.hex_archive, args.sdk_root):
        require(not work.is_relative_to(source) and not source.is_relative_to(work) or source == args.main_root and work.is_relative_to(source / "tmp/verification"), "Evidence overlaps a source/tool/build input")
    no_startup_files((args.repository, Path.cwd(), work), home=Path.home())
    helper = load_guard(args.guard_helper)
    script = Path(__file__).resolve()
    tools = {"mix": args.mix, "erl": args.erlang_root / "bin/erl", "epmd": args.erlang_root / "bin/epmd", "elixir_mix": args.elixir_root / "bin/mix", "elixir": args.elixir_root / "bin/elixir", "cc": args.cc, "make": args.make, "rebar3": args.rebar3}
    tool_roots = {"erl": args.erlang_root, "epmd": args.erlang_root, "elixir_mix": args.elixir_root, "elixir": args.elixir_root}
    erts = sorted(args.erlang_root.glob("erts-*/bin/beam.smp"))
    require(len(erts) == 1, "Pinned OTP installation has ambiguous/missing BEAM executable")
    tools.update(beam_smp=erts[0], erl_child_setup=erts[0].parent / "erl_child_setup")
    tool_roots.update(beam_smp=args.erlang_root, erl_child_setup=args.erlang_root)
    pins = {name: tool_pin(path, tool_roots.get(name)) for name, path in tools.items()}
    source, lock = source_inputs(args, helper)
    tool_versions = (args.repository / ".tool-versions").read_bytes()
    require(tool_versions == (args.main_root / ".tool-versions").read_bytes(), "Main/candidate tool versions differ")
    otp = re.search(rb"(?m)^erlang\s+(\S+)", tool_versions)[1].decode()
    elixir = re.search(rb"(?m)^elixir\s+(\S+)", tool_versions)[1].decode().split("-otp", 1)[0]
    require((args.erlang_root / "releases" / otp.split(".", 1)[0] / "OTP_VERSION").read_text().strip() == otp, "Pinned OTP differs from source version")
    options = {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items() if key not in ("prepare", "run", "manifest_sha256")}
    inputs = {"options": options, "script_sha256": sha(script.read_bytes()), "guard_sha256": GUARD_SHA256,
              "tool_pins": pins, "tool_versions_sha256": sha(tool_versions), "native_sdk": sdk_inputs(args), **source,
              "strict_override_plan": {name: sorted(set(spec[2]) & set(PACKAGES)) for name, spec in PACKAGES.items()}}
    original = git_guards(args, helper)
    private_records = {
        **{"producer-" + name: {"files": {**source["published"][name], "mix.lock": sha(lock)}, "dependency": False} for name in PACKAGES},
        "consumer": {"files": source["consumer"], "dependency": False},
        **{"deps/" + name: {"files": source["dependencies"][name], "dependency": True} for name in DEPENDENCIES},
        "tool-archives/" + args.hex_archive.name: {"files": source["hex_tool"], "dependency": False},
    }
    inputs["private_input_records"] = private_records.copy()
    if args.prepare:
        require(not work.exists(), "Preparation requires a fresh evidence directory")
        work.mkdir(mode=0o700, parents=True)
        initial_build = helper.main_build_snapshot(args.main_root / "_build", args.main_build_policy)
        manifest = {"schema": "arbor.llm.cold-inputs.v1", "inputs": inputs, "preservation": original, "main_build": initial_build,
                    "first_party_beam_seeds": 0, "third_party_beam_seeds": 0, "prepare_runs_no_VM_or_native_code": True}
        save(work / "source-manifest.json", manifest)
        for directory in ("tooling", "archives", "metadata", "unpacked", "mix-home", "hex-home", "tool-archives", "deps", "native-preflight", "rebar-cache", "rebar-config"):
            (work / directory).mkdir(mode=0o700)
        shutil.copyfile(args.guard_helper, work / "tooling/cold_support.py")
        require(sha((work / "tooling/cold_support.py").read_bytes()) == GUARD_SHA256, "Copied guard differs")
        helper.copy_files(args.hex_archive, work / "tool-archives" / args.hex_archive.name, source["hex_tool"])
        for name in PACKAGES:
            helper.copy_files(args.repository / "packages" / name, work / ("producer-" + name), source["published"][name])
            install_lock(work / ("producer-" + name), lock)
        helper.copy_files(args.repository / "packages/arbor_llm/examples/standalone", work / "consumer", source["consumer"])
        check_lock(work / "consumer", lock)
        for name in DEPENDENCIES:
            helper.copy_files(args.deps_source_cache / name, work / "deps" / name, source["dependencies"][name])
        (work / "native-preflight/probe.c").write_text(NATIVE_PROBE)
        (work / ".tool-versions").write_bytes(tool_versions)
        save(work / "results.json", {"status": "prepared_no_runtime_credit", "manifest_sha256": sha((work / "source-manifest.json").read_bytes())})
    else:
        require(args.manifest_sha256 and sha((work / "source-manifest.json").read_bytes()) == args.manifest_sha256, "Run requires the exact reviewed prepared manifest SHA")
        manifest = json.loads((work / "source-manifest.json").read_text())
        require(manifest["inputs"] == inputs and manifest["preservation"] == original, "Prepared inputs/options/source guards changed")
        require(json.loads((work / "results.json").read_text())["status"] == "prepared_no_runtime_credit", "No retry/resume of an existing run")
        helper = load_guard(work / "tooling/cold_support.py")
    guard_count = 0
    projects = ["producer-" + name for name in PACKAGES] + ["consumer"]
    state = {"status": "preparing" if args.prepare else "running", "steps": [], "manifest_sha256": sha((work / "source-manifest.json").read_bytes()),
             "main_build_policy": args.main_build_policy, "first_party_beam_seeds": 0, "third_party_beam_seeds": 0}
    daemon, daemon_log, port, cookie = None, None, None, None
    handles = []

    def guard(label):
        nonlocal guard_count
        guard_count += 1
        audit = {"label": label, "initial": manifest["main_build"]}
        try:
            audit["current"] = helper.main_build_snapshot(args.main_root / "_build", args.main_build_policy)
            audit["comparison"] = helper.compare_main_build_snapshots(audit["initial"], audit["current"])
        except BaseException as error:
            audit["capture_failure"] = type(error).__name__
            raise
        finally:
            save(work / f"main-build-{'prepare' if args.prepare else 'run'}-audit-{guard_count:03d}.json", audit)
        require(audit["comparison"]["accepted"], "Main compiled/static input guard changed; HOLD")
        require(sha((work / "source-manifest.json").read_bytes()) == state["manifest_sha256"], "Input manifest changed")
        require(git_guards(args, helper) == manifest["preservation"], "Source, stash, operator or dotenv changed")
        no_startup_files((args.repository, Path.cwd(), work), home=Path.home())
        require(sha(script.read_bytes()) == inputs["script_sha256"] and sha(args.guard_helper.read_bytes()) == GUARD_SHA256 and
                sha((work / "tooling/cold_support.py").read_bytes()) == GUARD_SHA256, "Qualification tooling changed")
        require(source_inputs(args, helper) == (source, lock) and sdk_inputs(args) == inputs["native_sdk"], "Published/dependency/native source changed")
        require({name: tool_pin(path, tool_roots.get(name)) for name, path in tools.items()} == pins, "Pinned executable changed")
        require((args.repository / ".tool-versions").read_bytes() == tool_versions, "Source tool pins changed")
        check_private_inputs(work, private_records, helper)
        for relative in projects:
            check_lock(private_input_root(work, relative), lock)
        check_archives(work, state.get("archives", {}), source["published"])

    def save_state():
        save(work / "results.json", state)

    def env_for(label):
        runtime = work / "runtime" / label
        for name in ("home", "data", "security", "revocations", "tmp", "state", "xdg-config", "xdg-cache"):
            (runtime / name).mkdir(mode=0o700, parents=True, exist_ok=False)
        aliases = sorted({"localhost", socket.gethostname(), socket.gethostname().split(".")[0]})
        (runtime / "inetrc").write_text('{host, {127,0,0,1}, ' + json.dumps(aliases) + '}.\n{lookup, [file]}.\n')
        env = {"HOME": str(Path.home()), "LANG": "C.UTF-8", "PATH": native_path(args), "SDKROOT": str(args.sdk_root), "DEVELOPER_DIR": str(args.developer_dir),
               "MIX_ENV": "prod", "MIX_BUILD_PATH": str(work / "build/prod"), "MIX_DEPS_PATH": str(work / "deps"), "MIX_HOME": str(work / "mix-home"),
               "MIX_ARCHIVES": str(work / "tool-archives"), "MIX_REBAR3": str(args.rebar3), "HEX_HOME": str(work / "hex-home"), "HEX_OFFLINE": "1",
               "REBAR_CACHE_DIR": str(work / "rebar-cache"), "REBAR_GLOBAL_CONFIG_DIR": str(work / "rebar-config"), "CARGO_NET_OFFLINE": "true",
               "ARBOR_MIX_CONTAINED": "1", "ARBOR_ERLANG_ROOT": str(args.erlang_root), "ARBOR_ELIXIR_ROOT": str(args.elixir_root),
               "ARBOR_HOME": str(runtime / "home"), "ARBOR_DATA_DIR": str(runtime / "data"), "ARBOR_ENV_PATH": str(runtime / "absent.env"),
               "ARBOR_SECURITY_STATE_DIR": str(runtime / "security"), "ARBOR_SECURITY_REVOCATION_LEDGER_PATH": str(runtime / "revocations/ledger.json"),
               "XDG_CONFIG_HOME": str(runtime / "xdg-config"), "XDG_CACHE_HOME": str(runtime / "xdg-cache"),
               "TMPDIR": str(runtime / "tmp"), "ERL_INETRC": str(runtime / "inetrc"), "ERL_EPMD_PORT": str(port), "ERL_EPMD_ADDRESS": "127.0.0.1",
               "ERL_FLAGS": f"+S 4:4 -setcookie {cookie} -kernel inet_dist_use_interface {{127,0,0,1}}",
               "LLM_COLD_COOKIE_SHA256": sha(cookie.encode()), "LLM_COLD_ELIXIR_VERSION": elixir, "LLM_COLD_OTP_MAJOR": otp.split(".", 1)[0],
               "LLM_COLD_STATE_ROOT": str(runtime / "state"), "LLM_COLD_C_SHA256": source["published"]["arbor_support"]["c_src/arbor_safe_path_reader.c"],
               "LLM_COLD_APP_ROOT": str(work / "build/prod/lib"), "LLM_COLD_METADATA_ROOT": str(work / "metadata"), "LLM_COLD_ALLOWED_CODE_ROOTS": "|".join(map(str, (work, args.erlang_root, args.elixir_root))),
               "http_proxy": "http://127.0.0.1:1", "https_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
               "ALL_PROXY": "http://127.0.0.1:1", "all_proxy": "http://127.0.0.1:1", "NO_PROXY": "127.0.0.1,localhost,::1", "no_proxy": "127.0.0.1,localhost,::1"}
        env.update({"ARBOR_" + name.removeprefix("arbor_").upper() + "_PATH": str(work / "unpacked" / name) for name in PACKAGES})
        return env

    closed_groups = set()

    def terminate_owned(handle):
        if handle.pid in closed_groups:
            return
        # start_new_session pins a private process group. Clean descendants even
        # if their foreground parent has already exited; retain/wait the handle.
        try:
            os.killpg(handle.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            handle.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(handle.pid, signal.SIGKILL)
            handle.wait(timeout=10)
        for _ in range(100):
            try:
                os.killpg(handle.pid, 0)
            except ProcessLookupError:
                closed_groups.add(handle.pid)
                return
            time.sleep(0.05)
        try:
            os.killpg(handle.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for _ in range(100):
            try:
                os.killpg(handle.pid, 0)
            except ProcessLookupError:
                closed_groups.add(handle.pid)
                return
            time.sleep(0.05)
        raise RuntimeError("Owned process group did not become empty")

    def command(label, cwd, env, argv, mix=True):
        guard("before-" + label)
        no_startup_files((cwd,), home=Path.home())
        require(daemon.poll() is None and helper.names(port) == "", "Owned EPMD unavailable/occupied before command")
        executable = [str(args.mix), *argv] if mix else list(map(str, argv))
        stdout, stderr = work / (label + ".stdout.log"), work / (label + ".stderr.log")
        step = {"label": label, "cwd": str(cwd), "argv": executable, "status": "running"}
        state["steps"].append(step)
        save_state()
        print("START", label, flush=True)
        with stdout.open("xb") as output, stderr.open("xb") as errors:
            handle = subprocess.Popen(executable, cwd=cwd, env=env, stdout=output, stderr=errors, start_new_session=True)
            handles.append(handle)
            step["pid"] = handle.pid
            save_state()
            try:
                code = handle.wait(timeout=args.timeout)
            except BaseException:
                terminate_owned(handle)
                step.update(status="HOLD_interrupted_or_timeout", exit_code=handle.returncode)
                raise
            finally:
                terminate_owned(handle)
                step["owned_process_group_closed"] = True
                step.update(stdout_sha256=sha(stdout.read_bytes()), stderr_sha256=sha(stderr.read_bytes()))
                save_state()
        step.update(exit_code=code, status="passed" if code == 0 else "failed")
        save_state()
        guard("after-" + label)
        require(daemon.poll() is None and helper.names(port) == "", "Owned EPMD occupied after command")
        print("END", label, code, flush=True)
        require(code == 0, label + " failed; HOLD, no retry/fetch/repair")
        return stdout

    try:
        guard("prepared" if args.prepare else "run-start")
        if args.prepare:
            state["status"] = "prepared_no_runtime_credit"
            save_state()
            print("MANIFEST_SHA256=" + state["manifest_sha256"], flush=True)
            return
        for name in PACKAGES:
            require(helper.source_files(work / ("producer-" + name), PACKAGES[name][1]) == source["published"][name], "Copied producer input changed")
        require(helper.source_files(work / "consumer", CONSUMER_FILES) == source["consumer"], "Copied fixture changed")
        require({name: helper.source_files(work / "deps" / name, excludes=EXCLUDES, sources_only=True) for name in DEPENDENCIES} == source["dependencies"], "Copied dependency input changed")
        require(helper.source_files(work / "tool-archives" / args.hex_archive.name) == source["hex_tool"], "Copied Hex tool changed")
        cookie = "llm_cold_" + secrets.token_hex(24)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        require(port != 4369, "Private EPMD must not use default realm")
        daemon_log = (work / "epmd.log").open("xb")
        daemon = subprocess.Popen([str(tools["epmd"]), "-port", str(port), "-address", "127.0.0.1"], env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}, stdout=daemon_log, stderr=subprocess.STDOUT, start_new_session=True)
        state.update(epmd_pid=daemon.pid, epmd_port=port, cookie_sha256=sha(cookie.encode()))
        save_state()
        for _ in range(100):
            require(daemon.poll() is None, "Owned foreground EPMD exited")
            try:
                require(helper.names(port) == "", "Private realm occupied")
                break
            except (OSError, TimeoutError):
                time.sleep(0.05)
        else:
            raise RuntimeError("Private foreground EPMD did not start")
        native = work / "native-preflight"
        require((native / "probe.c").read_text() == NATIVE_PROBE, "Native probe changed")
        command("native-sdk-includes", native, env_for("native-sdk-includes"), [args.cc, "-E", "-v", "-x", "c", "/dev/null", "-o", native / "includes.i"], mix=False)
        includes = (work / "native-sdk-includes.stderr.log").read_text()
        require(str(args.sdk_root / "usr/include") in includes, "Compiler did not select the pinned SDK include tree")
        command("native-header-link-compile", native, env_for("native-header-link-compile"), [args.cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-D_DARWIN_C_SOURCE", "-D_GNU_SOURCE", "-D_POSIX_C_SOURCE=200809L", native / "probe.c", "-o", native / "probe"], mix=False)
        command("native-header-link-execute", native, env_for("native-header-link-execute"), [native / "probe"], mix=False)
        state["native_preflight"] = {"binary_sha256": sha((native / "probe").read_bytes()), "sdk": inputs["native_sdk"]}
        for name, (version, _files, _requirements) in PACKAGES.items():
            env = env_for("producer-" + name)
            for key in tuple(env):
                if key.startswith("ARBOR_") and key.endswith("_PATH"):
                    env.pop(key)
            archive = work / "archives" / (name + "-" + version + ".tar")
            command("hex-build-" + name, work / ("producer-" + name), env, ["hex.build", "--output", str(archive)])
            state.setdefault("archives", {})[name] = helper.unpack_archive(archive, work / "unpacked" / name, source["published"][name], work / "metadata" / (name + ".config"))
            install_lock(work / "unpacked" / name, lock)
            projects.append("unpacked/" + name)
            private_records["unpacked/" + name] = {"files": {**source["published"][name], "mix.lock": sha(lock)}, "dependency": False}
            save_state()
        consumer = work / "consumer"
        command("consumer-deps-compile", consumer, env_for("consumer-deps-compile"), ["deps.compile"])
        for name in PACKAGES:
            env = env_for("strict-" + name)
            env.update(LLM_COLD_STRICT_APP=name, LLM_COLD_STRICT_PATH=str(work / "unpacked" / name))
            command("strict-" + name, consumer, env, ["run", "--no-start", "--no-compile", "-e", STRICT_PACKAGE])
        command("consumer-strict-compile", consumer, env_for("consumer-strict-compile"), ["compile", "--warnings-as-errors"])
        build = work / "build/prod"
        def code_outputs():
            return {path.relative_to(build).as_posix(): sha(path.read_bytes()) for path in sorted(build.rglob("*")) if path.is_file() and path.suffix in (".beam", ".app", ".so", ".dylib")}
        strict_outputs = code_outputs()
        require(strict_outputs, "Fresh strict build emitted no executable artifacts")
        command("consumer-strict-repeat", consumer, env_for("consumer-strict-repeat"), ["compile", "--warnings-as-errors"])
        require(code_outputs() == strict_outputs, "Repeat strict compile changed executable artifacts")
        state["strict_outputs"] = strict_outputs
        normal_log = command("consumer-run", consumer, env_for("consumer-run"), ["run", "--no-start", "--no-compile", "-e", NORMAL_PROBE])
        normal = result_from(normal_log)
        validate_metadata(normal.get("archive_metadata"))
        state["consumer"] = normal
        release = work / "release"
        command("release-build", consumer, env_for("release-build"), ["release", "llm_standalone_consumer", "--path", str(release)])
        require(len(list(release.glob("erts-*/bin/erl"))) == 1, "Actual ERTS missing/ambiguous in release")
        for path in release.glob("releases/*/vm.args"):
            active = "\n".join(line.split("#", 1)[0] for line in path.read_text().splitlines())
            require(not re.search(r"-(?:setcookie|name|sname)\b", active), "Unexpected release identity flags")
        hidden = work / "source-hidden"
        hidden.mkdir(mode=0o700)
        for name in (*("producer-" + name for name in PACKAGES), "unpacked", "consumer", "deps", "tool-archives", "mix-home", "hex-home", "build", "native-preflight"):
            (work / name).rename(hidden / name)
        env = env_for("release-run")
        env.update(ERL_FLAGS="+S 4:4 -kernel inet_dist_use_interface {127,0,0,1}", RELEASE_COOKIE=cookie,
                   RELEASE_DISTRIBUTION="none", RELEASE_TMP=env["TMPDIR"], LLM_COLD_RELEASE_ROOT=str(release), LLM_COLD_APP_ROOT=str(release / "lib"), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        for key in tuple(env):
            if key.startswith(("MIX_", "HEX_")) or key in ("ARBOR_MIX_CONTAINED", "ARBOR_ERLANG_ROOT", "ARBOR_ELIXIR_ROOT"):
                env.pop(key)
        release_log = command("source-hidden-release-run", release, env, [release / "bin/llm_standalone_consumer", "eval", RELEASE_PROBE], mix=False)
        result = result_from(release_log)
        require(result.get("mix_available") is False, "Mix present in ERTS release")
        require(result["native_binary_sha256"] == normal["native_binary_sha256"] and result["bundled_resources"] == normal["bundled_resources"], "Release native/bundled inputs differ")
        state["release"] = result
        state["status"] = "passed"
    except BaseException as error:
        state.update(status="HOLD", error_class=type(error).__name__, error=str(error))
        raise
    finally:
        cleanup = []
        for handle in handles:
            try:
                terminate_owned(handle)
                require(handle.poll() is not None, "Owned child still live")
            except BaseException as error:
                cleanup.append(type(error).__name__)
        if daemon is not None:
            try:
                require(daemon.poll() is None and helper.names(port) == "", "Owned EPMD not empty/live at teardown")
                state["epmd_names_before_stop"] = ""
            except BaseException as error:
                cleanup.append(type(error).__name__)
            try:
                terminate_owned(daemon)
                state["epmd_exit_code"] = daemon.returncode
            except BaseException as error:
                cleanup.append(type(error).__name__)
        if daemon_log is not None:
            daemon_log.close()
        try:
            guard("final")
            state["final_guards_passed"] = True
        except BaseException as error:
            state["final_guards_passed"] = False
            cleanup.append(type(error).__name__)
        state["cleanup_errors"] = cleanup
        if cleanup:
            state["status"] = "HOLD"
        save_state()
        if cleanup:
            raise RuntimeError("Cleanup/preservation HOLD; inspect retained receipt")


if __name__ == "__main__":
    main()
