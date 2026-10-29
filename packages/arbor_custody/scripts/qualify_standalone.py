#!/usr/bin/env python3
"""Prepare or qualify an offline consumer of an actual locally built Hex package."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def files_at(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError(f"Unexpected source symlink: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = sha256(path.read_bytes())
        elif not path.is_dir():
            raise RuntimeError(f"Unexpected source file type: {path}")
    return result


def copy_source(source, destination):
    if source.is_symlink():
        raise RuntimeError(f"Unexpected source symlink: {source}")
    if source.is_dir():
        files_at(source)
        shutil.copytree(source, destination)
    elif source.is_file():
        shutil.copy2(source, destination)
    else:
        raise RuntimeError(f"Missing source: {source}")


def unpack_package(archive, destination, expected):
    if archive.stat().st_size > 8 * 1024 * 1024:
        raise RuntimeError("Package tar exceeds the qualification bound")
    with tarfile.open(archive, "r:") as outer:
        members = outer.getmembers()
        names = [member.name for member in members]
        if len(set(names)) != len(names) or set(names) != {
            "VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"
        }:
            raise RuntimeError(f"Unexpected Hex tar members: {names}")
        if any(not member.isfile() for member in members):
            raise RuntimeError("Hex tar has a nonregular member")
        payload = outer.extractfile("contents.tar.gz").read()
        metadata = outer.extractfile("metadata.config").read()
        version = outer.extractfile("VERSION").read()
    if version != b"3":
        raise RuntimeError(f"Unexpected Hex tar format: {version!r}")
    observed = {}
    total = 0
    destination.mkdir(mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as contents:
        for count, member in enumerate(contents, 1):
            name = PurePosixPath(member.name)
            if count > 256 or name.is_absolute() or ".." in name.parts or not name.parts:
                raise RuntimeError("Unsafe or excessive package contents")
            if member.isdir():
                continue
            if not member.isfile() or member.name in observed:
                raise RuntimeError(f"Nonregular or duplicate package member: {member.name}")
            total += member.size
            if total > 4 * 1024 * 1024:
                raise RuntimeError("Unpacked package exceeds the qualification bound")
            data = contents.extractfile(member).read()
            observed[member.name] = sha256(data)
            target = destination.joinpath(*name.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    if observed != expected:
        raise RuntimeError("Built package payload differs from its declared source bytes")
    return {
        "tar_sha256": sha256(archive.read_bytes()),
        "metadata_sha256": sha256(metadata),
        "contents_tar_gz_sha256": sha256(payload),
        "payload_files": observed,
    }


def main():
    package_source = Path(__file__).resolve().parents[1]
    repository = package_source.parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True, help="New directory; all attempts are retained")
    parser.add_argument("--mix", type=Path, default=repository / "bin/mix", help="Pinned Mix wrapper")
    parser.add_argument("--run", action="store_true", help="Execute after preparing; default prepares source only")
    args = parser.parse_args()
    work = args.work_dir.expanduser().resolve()
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    package = work / "package-source"
    package.mkdir(mode=0o700)
    for name in ["lib", "mix.exs", "README.md", "LICENSE"]:
        copy_source(package_source / name, package / name)
    consumer = work / "consumer"
    copy_source(package_source / "examples/standalone", consumer)
    copy_source(repository / ".tool-versions", work / ".tool-versions")
    expected = files_at(package)
    manifest = {"package-source": expected, "consumer": files_at(consumer)}
    (work / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    receipt = {"status": "prepared_only", "offline": True, "mix_executed": False, "checks": []}
    receipt_path = work / "qualification.json"

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")

    save()
    if not args.run:
        print(f"Prepared source only: {work}")
        print("No Mix process started. Execute with --run and another fresh --work-dir.")
        return

    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("MIX_", "ARBOR_", "ERL_", "ELIXIR_", "RELEASE_")):
            env.pop(key)
    runtime = work / "runtime"
    for name in ["home", "data", "security", "tmp"]:
        (runtime / name).mkdir(mode=0o700, parents=True)
    env.update({
        "MIX_ENV": "prod", "MIX_DEPS_PATH": str(work / "deps"),
        "HEX_OFFLINE": "1", "ERL_FLAGS": "+S 4:4",
        "ARBOR_HOME": str(runtime / "home"), "ARBOR_DATA_DIR": str(runtime / "data"),
        "ARBOR_SECURITY_STATE_DIR": str(runtime / "security"),
        "ARBOR_SECURITY_REVOCATION_LEDGER_PATH": str(runtime / "revocations.json"),
        "ARBOR_SQLITE_PATH": str(runtime / "data/unused.sqlite3"),
        "ARBOR_ENV_PATH": str(runtime / "missing.env"), "TMPDIR": str(runtime / "tmp"),
    })
    mix = str(args.mix.expanduser().resolve())

    def check(name, argv, cwd, overrides=None):
        step_env = dict(env, **(overrides or {}))
        log = work / f"{len(receipt['checks']) + 1:02d}-{name}.log"
        step = {"name": name, "argv": argv, "cwd": str(cwd), "log": log.name}
        receipt["checks"].append(step)
        receipt["mix_executed"] = True
        save()
        print(f"Running {name}; log={log}", flush=True)
        with log.open("w") as output:
            proc = subprocess.run(argv, cwd=cwd, env=step_env, stdout=output, stderr=subprocess.STDOUT, timeout=300)
        step["exit"] = proc.returncode
        save()
        if proc.returncode:
            raise RuntimeError(f"{name} exited {proc.returncode}")

    try:
        archive = work / "arbor_custody.tar"
        check("hex-build", [mix, "hex.build", "--output", str(archive)], package,
              {"MIX_BUILD_PATH": str(work / "package-build")})
        unpacked = work / "unpacked-package"
        receipt["built_package"] = unpack_package(archive, unpacked, expected)
        save()
        env.update({"MIX_BUILD_PATH": str(work / "consumer-build"),
                    "CUSTODY_PACKAGE_PATH": str(unpacked)})
        # This is a path-only dependency graph with no Hex dependencies. No deps.get is needed.
        check("compile", [mix, "compile", "--warnings-as-errors"], consumer)
        check("consumer", [mix, "run", "--no-compile", "-e", ":ok = CustodyStandaloneConsumer.verify!()"], consumer,
              {"CUSTODY_PROBE_REPORT": str(work / "consumer-closure.exs")})
        release = work / "release"
        check("release", [mix, "release", "custody_standalone_consumer", "--path", str(release)], consumer)
        if not list(release.glob("erts-*/bin/erl")):
            raise RuntimeError("Production release does not contain its ERTS")
        if files_at(package) != expected or files_at(unpacked) != expected:
            raise RuntimeError("Package source changed during qualification")
        hidden = work / "hidden-sources"
        hidden.mkdir(mode=0o700)
        for source in [package, unpacked, consumer]:
            source.rename(hidden / source.name)
        neutral = work / "neutral"
        neutral.mkdir(mode=0o700)
        for path in release.rglob("*"):
            if path.is_file() and path.suffix in [".ex", ".exs"]:
                raise RuntimeError(f"Elixir source left in production release: {path}")
            if path.is_symlink() and str(path.resolve()).startswith(str(hidden) + os.sep):
                raise RuntimeError(f"Release points back to hidden source: {path}")
        for key in list(env):
            if key.startswith("MIX_") or key == "CUSTODY_PACKAGE_PATH":
                env.pop(key)
        env.update({"RELEASE_DISTRIBUTION": "none", "CUSTODY_RELEASE_ROOT": str(release)})
        check("release-consumer", [str(release / "bin/custody_standalone_consumer"), "eval",
                                   ":ok = CustodyStandaloneConsumer.verify!(require_no_mix: true)"], neutral,
              {"CUSTODY_PROBE_REPORT": str(work / "release-closure.exs")})
        receipt.update({"status": "passed", "source_copies_hidden": True,
                        "release_cwd": str(neutral), "network_resolution": False})
    except Exception as error:
        receipt.update({"status": "failed", "error": str(error)})
        save()
        raise
    save()
    print(f"PASS: {receipt_path}")


if __name__ == "__main__":
    main()
