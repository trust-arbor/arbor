#!/usr/bin/env python3
"""Qualify an external consumer and no-Mix production release from fresh outputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def copy_regular_tree(source, destination):
    for path in source.rglob("*"):
        if path.is_symlink():
            raise RuntimeError(f"Source contains an unexpected symlink: {path}")
    shutil.copytree(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True, help="New directory to retain sources and logs")
    parser.add_argument("--mix", type=Path, default=Path("mix"), help="Pinned Mix wrapper or executable")
    parser.add_argument("--offline", action="store_true", help="Resolve from the public Hex cache only")
    args = parser.parse_args()
    package_source = Path(__file__).resolve().parents[1]
    repository = package_source.parents[1]
    work = args.work_dir.expanduser().resolve()
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    package = work / "package"
    package.mkdir()
    for name in ["lib", "mix.exs", "LICENSE", "README.md"]:
        source = package_source / name
        if source.is_symlink():
            raise RuntimeError(f"Source contains an unexpected symlink: {source}")
        if source.is_dir():
            copy_regular_tree(source, package / name)
        else:
            shutil.copy2(source, package / name)
    consumer = work / "consumer"
    consumer.mkdir()
    for name in ["lib", "config", "mix.exs", "mix.lock", "README.md"]:
        source = package_source / "examples/standalone" / name
        if not source.exists():
            continue
        if source.is_symlink():
            raise RuntimeError(f"Source contains an unexpected symlink: {source}")
        if source.is_dir():
            copy_regular_tree(source, consumer / name)
        else:
            shutil.copy2(source, consumer / name)
    shutil.copy2(repository / ".tool-versions", work / ".tool-versions")
    sources = {
        str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest()
        for root in [package, consumer]
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }
    (work / "source-manifest.json").write_text(json.dumps(sources, indent=2) + "\n")
    mix = str(args.mix.expanduser().resolve()) if args.mix != Path("mix") else "mix"
    env = os.environ.copy()
    for key in ["MIX_EXS", "MIX_PATH", "ERL_LIBS"]:
        env.pop(key, None)
    env.update({
        "MIX_ENV": "prod",
        "MIX_BUILD_PATH": str(consumer / "_build/prod"),
        "MIX_DEPS_PATH": str(consumer / "deps"),
        "SIGNALS_PACKAGE_PATH": str(package),
        "ARBOR_HOME": str(work / "runtime"),
    })
    if args.offline:
        env["HEX_OFFLINE"] = "1"
    checks = [
        ("dependencies", [mix, "deps.get", "--only", "prod", "--check-locked"]),
        ("compile", [mix, "compile", "--warnings-as-errors"]),
        ("consumer", [mix, "run", "--no-compile", "-e", ":ok = SignalsStandaloneConsumer.verify!()"]),
        ("release", [mix, "release", "signals_standalone_consumer"]),
    ]
    release_bin = consumer / "_build/prod/rel/signals_standalone_consumer/bin/signals_standalone_consumer"
    checks.append(("release-consumer", [
        str(release_bin), "eval",
        "false = Code.ensure_loaded?(Mix); :ok = SignalsStandaloneConsumer.verify!()",
    ]))
    results = []
    for name, command in checks:
        with (work / f"{name}.log").open("w") as output:
            result = subprocess.run(command, cwd=consumer, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=600)
        results.append({"name": name, "command": command, "exit_code": result.returncode})
        (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{name}: exit {result.returncode}", flush=True)
        if result.returncode:
            print((work / f"{name}.log").read_text()[-6000:], flush=True)
            return result.returncode
    print(f"Standalone qualification passed; retained evidence: {work}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
