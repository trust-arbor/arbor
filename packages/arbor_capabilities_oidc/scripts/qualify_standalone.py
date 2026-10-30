#!/usr/bin/env python3
"""Cold, offline two-Hex-archive consumer and source-hidden release qualification.

Writes only a new private evidence directory. Uses explicit pinned tools and
private dependency source copies; never fetches, publishes, seeds application
build caches, mutates Git, or deletes source/evidence. Stop on the first failure.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import socket
import stat
import subprocess
import tarfile
import time


PACKAGES = {
    "arbor_oauth": {
        "version": "0.1.0-dev",
        "files": ("lib", "mix.exs", "README.md", "LICENSE"),
    },
    "arbor_capabilities_oidc": {
        "version": "0.1.0-dev",
        "files": ("lib", "mix.exs", "README.md", "LICENSE"),
    },
}
DEPENDENCIES = ("boundary", "jason", "req", "finch", "mint", "hpax", "mime",
                "nimble_options", "nimble_pool", "telemetry", "joken", "jose", "plug_crypto")
CONSUMER_FILES = ("lib", "config", "mix.exs", "mix.lock", "README.md")
CACHE_EXCLUDES = frozenset(("_build", "deps", ".git", ".elixir_ls", "cover", "doc", "ebin"))
MAX_ARCHIVE_BYTES = 100_000_000

# This probe runs only after strict compilation from the unpacked artifact.
# Erlang terms, rather than a text search, validate real Hex dependency metadata.
CONSUMER_PROBE = r'''
{:ok, [[cookie]]} = :init.get_argument(:setcookie)
expected_cookie = System.fetch_env!("OIDC_COLD_COOKIE_SHA256")
^expected_cookie = :crypto.hash(:sha256, List.to_string(cookie)) |> Base.encode16(case: :lower)
false = Node.alive?()
true = System.version() == System.fetch_env!("OIDC_COLD_ELIXIR_VERSION")
true = List.to_string(:erlang.system_info(:otp_release)) == System.fetch_env!("OIDC_COLD_OTP_MAJOR")

metadata_root = System.fetch_env!("OIDC_COLD_METADATA_ROOT")
expected_packages = %{
  "arbor_oauth" => %{"boundary" => "~> 0.10", "jason" => "~> 1.4", "req" => "~> 0.7.5", "finch" => "~> 0.24", "mint" => "~> 1.9.3"},
  "arbor_capabilities_oidc" => %{"arbor_oauth" => "~> 0.1.0-dev", "boundary" => "~> 0.10", "jason" => "~> 1.4", "joken" => "~> 2.7", "plug_crypto" => "~> 2.0"}
}
archive_metadata = Map.new(expected_packages, fn {name, expected} ->
  {:ok, terms} = :file.consult(String.to_charlist(Path.join(metadata_root, name <> ".config")))
  properties = Map.new(terms)
  ^name = Map.fetch!(properties, "name")
  ^name = Map.fetch!(properties, "app")
  "0.1.0-dev" = Map.fetch!(properties, "version")
  ["MIT"] = Map.fetch!(properties, "licenses")
  true = is_binary(properties["description"]) and byte_size(properties["description"]) > 0
  true = map_size(Map.new(properties["links"])) > 0
  requirements = properties |> Map.fetch!("requirements") |> Enum.map(&Map.new/1)
  ^expected = Map.new(requirements, &{Map.fetch!(&1, "name"), Map.fetch!(&1, "requirement")})
  true = Enum.all?(requirements, fn requirement ->
    requirement["repository"] == "hexpm" and requirement["optional"] == false and not Map.has_key?(requirement, "path")
  end)
  first_party = requirements |> Enum.map(&Map.fetch!(&1, "name")) |> Enum.filter(&String.starts_with?(&1, "arbor_")) |> Enum.sort()
  true = first_party == if(name == "arbor_capabilities_oidc", do: ["arbor_oauth"], else: [])
  {name, %{requirements: requirements}}
end)
result = OIDCStandaloneConsumer.verify!()
sources = Map.new(result.code_paths, fn {name, _beam} ->
  module = String.to_existing_atom(name)
  owner = if String.starts_with?(name, "Elixir.Arbor.Capabilities.OIDC"), do: "ARBOR_CAPABILITIES_OIDC_PATH", else: "ARBOR_OAUTH_PATH"
  root = Path.expand(System.fetch_env!(owner)) <> "/"
  source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string() |> Path.expand()
  true = String.starts_with?(source, root)
  {name, source}
end)
allowed_roots = System.fetch_env!("OIDC_COLD_ALLOWED_CODE_ROOTS") |> String.split("|")
true = Enum.all?(:code.get_path(), fn path ->
  path = path |> List.to_string() |> Path.expand()
  Enum.any?(allowed_roots, &String.starts_with?(path <> "/", &1 <> "/"))
end)
result = Map.merge(result, %{source_paths: sources, archive_metadata: archive_metadata})
IO.puts("OIDC_QUALIFICATION_RESULT=" <> Jason.encode!(result))
'''

RELEASE_PROBE = r'''
{:ok, [[cookie]]} = :init.get_argument(:setcookie)
expected_cookie = System.fetch_env!("OIDC_COLD_COOKIE_SHA256")
^expected_cookie = :crypto.hash(:sha256, List.to_string(cookie)) |> Base.encode16(case: :lower)
false = Node.alive?()
true = System.version() == System.fetch_env!("OIDC_COLD_ELIXIR_VERSION")
true = List.to_string(:erlang.system_info(:otp_release)) == System.fetch_env!("OIDC_COLD_OTP_MAJOR")
result = OIDCStandaloneConsumer.verify!(require_no_mix: true)
root = Path.expand(System.fetch_env!("OIDC_COLD_RELEASE_ROOT")) <> "/"
true = Enum.all?(:code.get_path(), fn path ->
  String.starts_with?(Path.expand(List.to_string(path)) <> "/", root)
end)
true = String.starts_with?(Path.expand(List.to_string(:code.root_dir())) <> "/", root)
result = Map.merge(result, %{runtime_root: List.to_string(:code.root_dir()), otp_release: List.to_string(:erlang.system_info(:otp_release))})
IO.puts("OIDC_QUALIFICATION_RESULT=" <> Jason.encode!(result))
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def git_state(root):
    return {
        "head": git(root, "rev-parse", "HEAD").decode().strip(),
        "branch": git(root, "branch", "--show-current").decode().strip(),
        "status_sha256": sha(git(root, "status", "--porcelain=v1", "--untracked-files=all")),
        "index_sha256": sha(git(root, "ls-files", "--stage", "-z")),
        "stash_list_sha256": sha(git(root, "stash", "list", "--format=%H%x09%gd%x09%gs")),
    }


def metadata(path):
    if not path.exists() and not path.is_symlink():
        return None
    value = path.lstat()
    return [value.st_ino, value.st_mtime_ns, value.st_ctime_ns, value.st_size, value.st_mode]


def build_metadata(root):
    """Fingerprint Main's ignored build without reading or altering BEAM files."""
    if not root.exists():
        return None
    entries = [(".", metadata(root))]
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        for name in sorted(subdirectories + files):
            path = Path(directory) / name
            entries.append((path.relative_to(root).as_posix(), metadata(path)))
    return {"entries": len(entries), "metadata_sha256": sha(json.dumps(sorted(entries)).encode())}


def operator_state():
    node_id = Path.home() / ".arbor/node_id"
    node = metadata(node_id)
    if node is not None:
        require(node_id.is_file() and not node_id.is_symlink(), "Unsafe operator node_id; HOLD")
    return {
        "node_id_metadata": node,
        "node_id_sha256": sha(node_id.read_bytes()) if node is not None else None,
        # Never read the operator cookie contents.
        "cookie_metadata": metadata(Path.home() / ".erlang.cookie"),
    }


def source_files(root, allowed=None, excludes=frozenset(), sources_only=False):
    require(root.is_dir() and not root.is_symlink(), f"Missing/unsafe source root: {root}")
    paths = []
    for name in (allowed if allowed is not None else (".",)):
        path = root / name
        require(path.exists() and not path.is_symlink(), f"Missing/unsafe source input: {path}")
        paths.extend([path] if path.is_file() else sorted(path.rglob("*")))
    result = {}
    for path in paths:
        relative = path.relative_to(root)
        if any(part in excludes for part in relative.parts):
            continue
        require(not path.is_symlink(), f"Source symlink is not qualified: {path}")
        if path.is_dir():
            continue
        require(stat.S_ISREG(path.stat().st_mode), f"Non-regular source input: {path}")
        if sources_only:
            require(path.suffix not in (".beam", ".ez", ".so", ".dylib", ".dll", ".o"),
                    f"Compiled dependency input is not allowed: {path}")
        result[relative.as_posix()] = sha(path.read_bytes())
    require(result, f"Empty source input: {root}")
    return dict(sorted(result.items()))


def copy_files(source, destination, manifest):
    destination.mkdir(mode=0o700)
    for relative, expected in manifest.items():
        data = (source / relative).read_bytes()
        require(sha(data) == expected, f"Source changed while copying: {source / relative}")
        target = destination / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(data)


def names(port):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as stream:
        stream.sendall(b"\x00\x01n")
        data = b""
        while part := stream.recv(65536):
            data += part
    require(len(data) >= 4 and int.from_bytes(data[:4], "big") == port, "Wrong EPMD realm")
    return data[4:].decode("ascii")


def unpack_archive(archive, destination, expected, metadata_path):
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_size < MAX_ARCHIVE_BYTES,
            f"Missing/unsafe/oversized Hex archive: {archive}")
    with tarfile.open(archive, "r:") as outer:
        members = outer.getmembers()
        require(len(members) == 4 and
                {m.name for m in members} == {"VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"} and
                all(m.isfile() and m.size < MAX_ARCHIVE_BYTES for m in members),
                "Unexpected, duplicate or unsafe Hex outer archive entries")
        version = outer.extractfile("VERSION").read()
        checksum = outer.extractfile("CHECKSUM").read()
        package_metadata = outer.extractfile("metadata.config").read()
        compressed = outer.extractfile("contents.tar.gz").read()
    require(version == b"3", "Unexpected Hex archive format")
    require(checksum.decode("ascii").lower() == sha(version + package_metadata + compressed),
            "Hex archive checksum mismatch")
    destination.mkdir(mode=0o700)
    actual, seen, total_size = {}, set(), 0
    directories = {parent.as_posix() for relative in expected
                   for parent in PurePosixPath(relative).parents if parent.as_posix() != "."}
    with tarfile.open(fileobj=io.BytesIO(compressed), mode="r:gz") as contents:
        for member in contents:
            path = PurePosixPath(member.name)
            relative = path.as_posix()
            canonical_name = member.name.rstrip("/") if member.isdir() else member.name
            require(not path.is_absolute() and ".." not in path.parts and relative not in ("", ".") and
                    canonical_name == relative and relative not in seen,
                    f"Unsafe/duplicate package path: {member.name}")
            seen.add(relative)
            require(member.isfile() or member.isdir(), f"Unsafe package member: {member.name}")
            if member.isdir():
                require(relative in directories, f"Unexpected package directory: {relative}")
                continue
            require(relative in expected and member.size <= 10_000_000,
                    f"Unexpected/oversized package file: {relative}")
            total_size += member.size
            require(total_size < MAX_ARCHIVE_BYTES, "Oversized unpacked package")
            data = contents.extractfile(member).read()
            require(sha(data) == expected[relative], f"Published package bytes differ: {relative}")
            target = destination / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(data)
            actual[relative] = sha(data)
    require(actual == expected, "Hex archive omitted published source files")
    with metadata_path.open("xb") as output:
        output.write(package_metadata)
    return {
        "archive_sha256": sha(archive.read_bytes()),
        "metadata_sha256": sha(package_metadata),
        "files": actual,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("work-dir", "mix", "erlang-root", "elixir-root", "hex-archive",
                   "rebar3", "deps-source-cache", "main-root"):
        parser.add_argument("--" + option, type=Path, required=True)
    for option in ("head", "main-head", "branch"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--timeout", type=int, default=900, help="Maximum seconds per command")
    args = parser.parse_args()
    for option in ("work_dir", "mix", "erlang_root", "elixir_root", "hex_archive",
                   "rebar3", "deps_source_cache", "main_root"):
        path = getattr(args, option).expanduser()
        require(path.is_absolute(), f"--{option.replace('_', '-')} must be an absolute pinned path")
        setattr(args, option, path.resolve())
    require(args.timeout > 0, "Timeout must be positive")
    require(re.fullmatch(r"[0-9a-f]{40}", args.head) and re.fullmatch(r"[0-9a-f]{40}", args.main_head),
            "Supply full reviewed Main and branch commit IDs")
    package_source = Path(__file__).resolve().parents[1]
    repository = package_source.parents[1]
    work = args.work_dir
    require(repository != args.main_root, "Run from a candidate worktree, never Main")
    require(not (repository / ".env").exists(), "Refuse candidate worktree dotenv loading")
    for source_root in (repository, args.main_root):
        require(not work.is_relative_to(source_root / "_build"), "Evidence must not be inside an umbrella build")
        require(git(source_root, "status", "--porcelain=v1", "--untracked-files=all") == b"",
                f"Reviewed source tree must be clean: {source_root}")
    require(not work.is_relative_to(args.deps_source_cache), "Evidence must not be inside the source cache")
    require(git(repository, "rev-parse", "HEAD").decode().strip() == args.head, "Candidate HEAD moved; HOLD")
    require(git(repository, "branch", "--show-current").decode().strip() == args.branch, "Candidate branch moved; HOLD")
    require(git(args.main_root, "rev-parse", "HEAD").decode().strip() == args.main_head, "Main HEAD moved; HOLD")
    require(git(args.main_root, "branch", "--show-current").decode().strip() == "main", "Main is not checked out; HOLD")
    tools = {
        "mix": args.mix,
        "erl": args.erlang_root / "bin/erl",
        "epmd": args.erlang_root / "bin/epmd",
        "elixir_mix": args.elixir_root / "bin/mix",
        "elixir": args.elixir_root / "bin/elixir",
        "rebar3": args.rebar3,
    }
    for name, path in tools.items():
        require(path.is_file() and os.access(path, os.X_OK), f"Missing executable pinned {name}: {path}")
    tool_versions = (repository / ".tool-versions").read_bytes()
    require(tool_versions == (args.main_root / ".tool-versions").read_bytes(), "Main/candidate tool pins differ")
    otp_version = re.search(rb"(?m)^erlang\s+(\S+)", tool_versions).group(1).decode()
    elixir_version = re.search(rb"(?m)^elixir\s+(\S+)", tool_versions).group(1).decode().split("-otp-", 1)[0]
    otp_major = otp_version.split(".", 1)[0]
    require((args.erlang_root / "releases" / otp_major / "OTP_VERSION").read_text().strip() == otp_version,
            "Pinned Erlang installation does not match .tool-versions")
    published = {name: source_files(repository / "packages" / name, spec["files"])
                 for name, spec in PACKAGES.items()}
    consumer_source = package_source / "examples/standalone"
    consumer_files = source_files(consumer_source, CONSUMER_FILES)
    lock = (consumer_source / "mix.lock").read_bytes()
    dependency_files = {}
    for name in DEPENDENCIES:
        require(re.search(rb'(?m)^\s*"' + name.encode() + rb'":', lock), f"Missing locked production dependency: {name}")
        dependency_files[name] = source_files(args.deps_source_cache / name, excludes=CACHE_EXCLUDES, sources_only=True)
        require(".hex" in dependency_files[name], f"Missing Hex checkout marker for cached {name}")
    hex_files = source_files(args.hex_archive)
    require(args.hex_archive.name.startswith("hex-"), "Expected an explicitly pinned installed Hex archive")
    inputs = {
        "published": published,
        "consumer": consumer_files,
        "dependency_sources": dependency_files,
        "hex_tool_archive": hex_files,
        "tool_sha256": {name: sha(path.read_bytes()) for name, path in tools.items()},
        "tool_versions_sha256": sha(tool_versions),
    }

    def repository_state():
        return {
            "main": git_state(args.main_root),
            "candidate": git_state(repository),
            "main_build": build_metadata(args.main_root / "_build"),
            "main_dotenv_metadata": metadata(args.main_root / ".env"),
            "operator": operator_state(),
        }

    before = repository_state()

    def guard():
        require(repository_state() == before, "Repository, Main build, stash or operator guard changed; HOLD")
        require((repository / ".tool-versions").read_bytes() == tool_versions, "Tool pins changed; HOLD")
        require({name: source_files(repository / "packages" / name, spec["files"])
                 for name, spec in PACKAGES.items()} == published, "Published package inputs changed; HOLD")
        require(source_files(consumer_source, CONSUMER_FILES) == consumer_files, "Consumer inputs changed; HOLD")
        require({name: source_files(args.deps_source_cache / name, excludes=CACHE_EXCLUDES, sources_only=True)
                 for name in DEPENDENCIES} == dependency_files, "Private dependency source inputs changed; HOLD")
        require(source_files(args.hex_archive) == hex_files, "Pinned Hex tool changed; HOLD")
        require({name: sha(path.read_bytes()) for name, path in tools.items()} == inputs["tool_sha256"],
                "Pinned executable changed; HOLD")

    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    state = {
        "status": "preparing",
        "guard_before": before,
        "inputs": inputs,
        "steps": [],
        "first_party_cache_seeded": 0,
        "third_party_cache_seeded": 0,
        "producer_packages_compiled": False,
        "offline": True,
    }
    save = lambda: save_json(work / "results.json", state)
    save()
    daemon, daemon_log = None, None
    port = None
    try:
        for directory in ("mix-home", "hex-home", "tool-archives", "hex-output", "metadata",
                          "unpacked", "consumer-deps", "rebar-cache", "rebar-config"):
            (work / directory).mkdir(mode=0o700)
        copy_files(args.hex_archive, work / "tool-archives" / args.hex_archive.name, hex_files)
        for name in PACKAGES:
            producer = work / ("producer-" + name)
            copy_files(repository / "packages" / name, producer, published[name])
            (producer / "mix.lock").write_bytes(lock)
            (work / ("producer-deps-" + name)).mkdir(mode=0o700)
        copy_files(consumer_source, work / "consumer", consumer_files)
        for name in DEPENDENCIES:
            copy_files(args.deps_source_cache / name, work / "consumer-deps" / name, dependency_files[name])
        (work / ".tool-versions").write_bytes(tool_versions)
        save_json(work / "source-manifest.json", inputs)
        guard()
        cookie = "oidc_cold_" + secrets.token_hex(24)
        cookie_sha256 = sha(cookie.encode())
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        require(port != 4369, "Private EPMD must not use the operator port")
        state.update(status="running", epmd_port=port, cookie_sha256=cookie_sha256)
        daemon_log = (work / "epmd.log").open("xb")
        daemon = subprocess.Popen(
            [str(tools["epmd"]), "-port", str(port), "-address", "127.0.0.1"],
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            stdout=daemon_log, stderr=subprocess.STDOUT,
        )
        state["epmd_pid"] = daemon.pid
        save()
        for _ in range(100):
            require(daemon.poll() is None, "Owned EPMD exited during startup")
            try:
                require(names(port) == "", "Private EPMD realm is unexpectedly occupied")
                break
            except (OSError, TimeoutError):
                time.sleep(0.05)
        else:
            raise RuntimeError("Owned foreground EPMD did not become ready")

        def environment(label, deps):
            runtime = work / (label + "-runtime")
            for name in ("home", "data", "security", "revocations", "tmp"):
                (runtime / name).mkdir(mode=0o700, parents=True, exist_ok=True)
            aliases = sorted({"localhost", socket.gethostname(), socket.gethostname().split(".")[0], socket.getfqdn()})
            (runtime / "inetrc").write_text('{host, {127,0,0,1}, ' + json.dumps(aliases) + '}.\n{lookup, [file,dns]}.\n')
            # Do not inherit VM flags, node names, cookie settings or build paths.
            # Do not change HOME/-home or read the operator cookie.
            return {
                "HOME": str(Path.home()),
                "LANG": "C.UTF-8",
                "PATH": f"{args.erlang_root}/bin:{args.elixir_root}/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "MIX_ENV": "prod", "MIX_BUILD_PATH": str(work / (label + "-build/prod")),
                "MIX_DEPS_PATH": str(deps), "MIX_HOME": str(work / "mix-home"),
                "MIX_ARCHIVES": str(work / "tool-archives"), "MIX_REBAR3": str(args.rebar3),
                "HEX_HOME": str(work / "hex-home"), "HEX_OFFLINE": "1",
                "REBAR_CACHE_DIR": str(work / "rebar-cache"),
                "REBAR_GLOBAL_CONFIG_DIR": str(work / "rebar-config"),
                "ARBOR_MIX_CONTAINED": "1", "ARBOR_ERLANG_ROOT": str(args.erlang_root),
                "ARBOR_ELIXIR_ROOT": str(args.elixir_root),
                "ARBOR_HOME": str(runtime / "home"), "ARBOR_DATA_DIR": str(runtime / "data"),
                "ARBOR_ENV_PATH": str(runtime / "absent.env"),
                "ARBOR_SECURITY_STATE_DIR": str(runtime / "security"),
                "ARBOR_SECURITY_REVOCATION_LEDGER_PATH": str(runtime / "revocations/ledger.json"),
                "TMPDIR": str(runtime / "tmp"), "ERL_INETRC": str(runtime / "inetrc"),
                "ERL_EPMD_PORT": str(port), "ERL_EPMD_ADDRESS": "127.0.0.1",
                # Exactly one synthetic -setcookie for ordinary Mix invocations.
                "ERL_FLAGS": f"+S 4:4 -setcookie {cookie} -kernel inet_dist_use_interface {{127,0,0,1}}",
                "ARBOR_OAUTH_PATH": str(work / "unpacked/arbor_oauth"),
                "ARBOR_CAPABILITIES_OIDC_PATH": str(work / "unpacked/arbor_capabilities_oidc"),
                "OIDC_COLD_COOKIE_SHA256": cookie_sha256,
                "OIDC_COLD_ELIXIR_VERSION": elixir_version, "OIDC_COLD_OTP_MAJOR": otp_major,
                "OIDC_COLD_METADATA_ROOT": str(work / "metadata"),
                "OIDC_COLD_ALLOWED_CODE_ROOTS": "|".join(map(str, (work, args.erlang_root, args.elixir_root))),
            }

        def command(label, cwd, env, argv, mix=True):
            guard()
            require(not (cwd / ".env").exists(), f"Refuse fixture dotenv loading from {cwd}")
            require(not Path(env["ARBOR_ENV_PATH"]).exists(), "Private absent dotenv path appeared; HOLD")
            require(daemon.poll() is None and names(port) == "", "Private EPMD changed before command; HOLD")
            executable = [str(args.mix), *argv] if mix else argv
            step = {"label": label, "cwd": str(cwd), "argv": executable, "status": "running"}
            state["steps"].append(step)
            save()
            print("START", label, flush=True)
            stdout_path, stderr_path = work / (label + ".stdout.log"), work / (label + ".stderr.log")
            with stdout_path.open("xb") as output, stderr_path.open("xb") as errors:
                result = subprocess.run(executable, cwd=cwd, env=env, stdout=output,
                                        stderr=errors, timeout=args.timeout)
            step.update(exit_code=result.returncode, status="passed" if result.returncode == 0 else "failed",
                        stdout_sha256=sha(stdout_path.read_bytes()), stderr_sha256=sha(stderr_path.read_bytes()))
            save()
            guard()
            require(daemon.poll() is None and names(port) == "", "Private EPMD changed after command; HOLD")
            print("END", label, result.returncode, flush=True)
            require(result.returncode == 0, f"{label} failed; HOLD; inspect retained log, no automatic retry/fetch/repair")

        for name, spec in PACKAGES.items():
            producer = work / ("producer-" + name)
            env = environment("producer-" + name, work / ("producer-deps-" + name))
            # Producers must describe public dependencies, never the consumer's
            # local unpacked override. Hex metadata is checked from the archive.
            env.pop("ARBOR_OAUTH_PATH", None)
            env.pop("ARBOR_CAPABILITIES_OIDC_PATH", None)
            archive = work / "hex-output" / f"{name}-{spec['version']}.tar"
            # Hex builds publication inputs/metadata, not producer BEAM outputs.
            # A task requiring unresolved producer deps is an explicit HOLD gate.
            command("hex-build-" + name, producer, env, ["hex.build", "--output", str(archive)])
            state.setdefault("hex_archives", {})[name] = unpack_archive(
                archive, work / "unpacked" / name, published[name], work / "metadata" / (name + ".config")
            )
            save()
        consumer = work / "consumer"
        env = environment("consumer", work / "consumer-deps")
        command("consumer-deps-compile", consumer, env, ["deps.compile"])
        # The consumer's --warnings-as-errors applies only to its own project.
        # Force strict compilation of each unpacked package against the same
        # fresh dependency/build outputs so dependency warnings also fail.
        for name in PACKAGES:
            command("artifact-strict-compile-" + name, work / "unpacked" / name, env,
                    ["compile", "--no-deps-check", "--force", "--warnings-as-errors"])
        command("consumer-strict-compile", consumer, env, ["compile", "--warnings-as-errors"])
        command("consumer-verify", consumer, env, ["run", "--no-compile", "-e", CONSUMER_PROBE])
        release = work / "release"
        command("release-build", consumer, env,
                ["release", "oidc_standalone_consumer", "--path", str(release)])
        require(any(release.glob("erts-*/bin/erl")), "Release did not include ERTS")
        for vm_args in release.glob("releases/*/vm.args"):
            active = "\n".join(line.split("#", 1)[0] for line in vm_args.read_text().splitlines())
            require(not re.search(r"-(?:setcookie|name|sname)\b", active), "Unqualified release VM identity flags")
        hidden = work / "source-hidden"
        hidden.mkdir(mode=0o700)
        for name in ("producer-arbor_oauth", "producer-deps-arbor_oauth",
                     "producer-arbor_capabilities_oidc", "producer-deps-arbor_capabilities_oidc",
                     "unpacked", "consumer", "consumer-deps",
                     "tool-archives", "mix-home", "hex-home"):
            (work / name).rename(hidden / name)
        release_env = environment("release", work / "unused-release-deps")
        # The release launcher supplies its one synthetic cookie. OTP rejects
        # duplicate inherited -setcookie flags, so remove that ordinary flag.
        release_env.update(
            ERL_FLAGS="+S 4:4 -kernel inet_dist_use_interface {127,0,0,1}",
            RELEASE_COOKIE=cookie, RELEASE_DISTRIBUTION="none",
            RELEASE_TMP=str(work / "release-runtime/tmp"),
            OIDC_COLD_RELEASE_ROOT=str(release),
            PATH="/usr/bin:/bin:/usr/sbin:/sbin",
        )
        for key in list(release_env):
            if key.startswith(("MIX_", "HEX_")) or key in ("ARBOR_MIX_CONTAINED", "ARBOR_ERLANG_ROOT", "ARBOR_ELIXIR_ROOT"):
                release_env.pop(key)
        command("source-hidden-release-verify", release, release_env,
                [str(release / "bin/oidc_standalone_consumer"), "eval", RELEASE_PROBE], mix=False)
        for label in ("consumer-verify", "source-hidden-release-verify"):
            results = [json.loads(line.split("=", 1)[1])
                       for line in (work / (label + ".stdout.log")).read_text().splitlines()
                       if line.startswith("OIDC_QUALIFICATION_RESULT=")]
            require(len(results) == 1, f"Missing/ambiguous qualification result: {label}")
            state[label] = results[0]
        require(state["source-hidden-release-verify"]["mix_available"] is False, "Mix is present in release")
        guard()
        state["status"] = "passed"
    except BaseException as error:
        state.update(status="HOLD", error=f"{type(error).__name__}: {error}")
        raise
    finally:
        teardown_error = None
        if daemon is not None:
            try:
                state["remaining_names"] = names(port) if daemon.poll() is None else "owned EPMD exited"
            except (OSError, RuntimeError) as error:
                state["epmd_query_error"] = str(error)
            if state["status"] == "passed" and state.get("remaining_names") != "":
                teardown_error = RuntimeError("Private EPMD changed during teardown; HOLD")
                state.update(status="HOLD", error=str(teardown_error))
            if daemon.poll() is None:
                daemon.terminate()  # Only the exact foreground child PID we own.
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()  # Exact owned child only; never epmd -kill/killall.
                daemon.wait(timeout=5)
        if daemon_log is not None:
            daemon_log.close()
        try:
            guard()
            state["guard_after"] = repository_state()
        except BaseException as error:
            state.update(status="HOLD", final_guard_error=f"{type(error).__name__}: {error}")
            raise
        finally:
            save()
        if teardown_error is not None:
            raise teardown_error
    print(f"Standalone qualification passed; retained evidence: {work}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
