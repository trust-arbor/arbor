#!/usr/bin/env python3
"""Qualify copied Core source in an external consumer and a no-Mix release."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time


PACKAGE_INPUTS = ("lib", "mix.exs", "mix.lock", "LICENSE", "README.md")
CONSUMER_INPUTS = ("lib", "config", "mix.exs", "mix.lock", "README.md")
LOCK_NAMES = {"jason", "telemetry", "typed_struct"}
MARKER = "PERSISTENCE_CORE_STANDALONE_OK"
ADAPTERS = {"sql": "arbor_persistence_sql", "eventstore": "arbor_persistence_eventstore"}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def copy_regular(source, destination):
    if source.is_symlink():
        raise RuntimeError(f"Source contains an unexpected symlink: {source}")
    if source.is_dir():
        for path in source.rglob("*"):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise RuntimeError(f"Source contains a nonregular entry: {path}")
        shutil.copytree(source, destination)
    elif source.is_file():
        shutil.copy2(source, destination)
    else:
        raise RuntimeError(f"Missing regular source input: {source}")


def input_manifest(inputs, tool_versions):
    result = {}
    for prefix, directory, names in inputs:
        for name in names:
            root = directory / name
            if root.is_symlink():
                raise RuntimeError(f"Source input became a symlink: {root}")
            paths = sorted(root.rglob("*")) if root.is_dir() else [root]
            for path in paths:
                if path.is_symlink():
                    raise RuntimeError(f"Copied source became a symlink: {path}")
                if path.is_file():
                    relative = Path(prefix) / path.relative_to(directory)
                    result[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
                elif not path.is_dir():
                    raise RuntimeError(f"Copied source input disappeared: {path}")
    if tool_versions.is_symlink() or not tool_versions.is_file():
        raise RuntimeError(f"Missing regular toolchain input: {tool_versions}")
    result[".tool-versions"] = hashlib.sha256(tool_versions.read_bytes()).hexdigest()
    return result


def source_manifest(work, layout):
    inputs = [(prefix, work / prefix, names) for prefix, names in layout]
    return input_manifest(inputs, work / ".tool-versions")


def verify_manifest(work, expected, layout):
    if json.loads((work / "source-manifest.json").read_text()) != expected:
        raise RuntimeError("Retained source SHA-256 manifest changed")
    actual = source_manifest(work, layout)
    if actual != expected:
        changed = sorted(key for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key))
        raise RuntimeError(f"Copied source SHA-256 manifest changed: {changed}")


def run_step(work, consumer, env, results, name, command, manifest, layout,
             marker=None, postgres=None, sealed=None, validator=None):
    verify_manifest(work, manifest, layout)
    verify_sealed(work, sealed)
    if postgres:
        verify_postgres_fixture(postgres)
    entry = {"name": name, "command": command, "status": "running"}
    results.append(entry)
    write_json(work / "results.json", results)
    began = time.monotonic()
    stdout_path = work / f"{name}.stdout.log"
    stderr_path = work / f"{name}.stderr.log"
    with stdout_path.open("w") as output, stderr_path.open("w") as errors:
        process = subprocess.Popen(command, cwd=consumer, env=env, stdout=output, stderr=errors,
                                   start_new_session=True)
        try:
            exit_code = process.wait(timeout=600)
            status = "passed" if exit_code == 0 else "failed"
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            exit_code, status = 124, "timeout"
    entry.update(exit_code=exit_code, status=status, elapsed_seconds=round(time.monotonic() - began, 3))
    write_json(work / "results.json", results)
    verify_manifest(work, manifest, layout)
    verify_sealed(work, sealed)
    entry["source_manifest_verified"] = True
    if exit_code == 0 and marker and marker not in stdout_path.read_text():
        entry.update(exit_code=1, status="missing_canary_marker")
        exit_code = 1
    write_json(work / "results.json", results)
    if exit_code == 0 and validator:
        try:
            validator(stdout_path)
        except Exception:
            entry.update(status="validation_failed", process_exit_code=0, exit_code=1)
            write_json(work / "results.json", results)
            raise RuntimeError("PostgreSQL connection identity validation failed before database creation") from None
    print(f"{name}: {entry['status']} (exit {exit_code})", flush=True)
    if exit_code and not postgres:
        for path in [stdout_path, stderr_path]:
            print(f"--- {path.name} ---\n{path.read_text()[-4000:]}", flush=True)
    elif exit_code:
        print("Private database attempt failed; details remain in private stdout/stderr logs.", flush=True)
    return exit_code


def verify_sealed(work, sealed):
    for relative, expected in (sealed or {}).items():
        path = work / relative
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("A sealed private qualification input disappeared")
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("A sealed private qualification input changed")


def load_postgres_fixture(path):
    path = path.expanduser().absolute()
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("PostgreSQL requires a regular explicit owned-cluster manifest")
    stat = path.stat()
    if stat.st_uid != os.geteuid() or stat.st_mode & 0o077:
        raise RuntimeError("PostgreSQL fixture manifest must be private and owned by this user")
    value = json.loads(path.read_text())
    required = {"owned", "root", "data_dir", "pid", "postmaster_start_epoch",
                "pg_ctl", "postgres", "host", "port", "user", "password"}
    if not required <= value.keys() or value["owned"] is not True:
        raise RuntimeError("PostgreSQL fixture does not attest an owned cluster")
    try:
        loopback = ipaddress.ip_address(value["host"]).is_loopback
    except ValueError:
        loopback = False
    if not loopback or type(value["port"]) is not int or not 1024 <= value["port"] <= 65535:
        raise RuntimeError("PostgreSQL fixture must select an explicit private loopback port")
    if type(value["pid"]) is not int or value["pid"] <= 1:
        raise RuntimeError("PostgreSQL fixture has an invalid server identity")
    for field in ["user", "password"]:
        if not isinstance(value[field], str) or any(c in value[field] for c in "\r\n\0"):
            raise RuntimeError("PostgreSQL fixture credentials have an invalid shape")
    if not value["user"]:
        raise RuntimeError("PostgreSQL fixture requires its explicit owner role")
    result = {"path": path.resolve(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
              "value": value}
    verify_postgres_fixture(result)
    return result


def verify_postgres_fixture(fixture):
    path, value = fixture["path"], fixture["value"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != fixture["sha256"]:
        raise RuntimeError("Owned PostgreSQL fixture manifest changed")
    root = Path(value["root"]).resolve(strict=True)
    data = Path(value["data_dir"]).resolve(strict=True)
    if root == data or root not in data.parents:
        raise RuntimeError("PostgreSQL data directory is outside its owned root")
    for directory in [root, data]:
        stat = directory.stat()
        if not directory.is_dir() or stat.st_uid != os.geteuid() or stat.st_mode & 0o077:
            raise RuntimeError("PostgreSQL root and data directory must remain private and user-owned")
    lines = (data / "postmaster.pid").read_text().splitlines()
    if (len(lines) < 6 or int(lines[0]) != value["pid"] or
            Path(lines[1]).resolve() != data or int(lines[2]) != int(value["postmaster_start_epoch"]) or
            int(lines[3]) != value["port"]):
        raise RuntimeError("PostgreSQL postmaster PID/data-root/start-time/port proof does not match")
    listeners = [item.strip() for item in lines[5].split(",")]
    try:
        if not listeners or not all(ipaddress.ip_address(item).is_loopback for item in listeners):
            raise RuntimeError("PostgreSQL postmaster is not confined to loopback")
    except ValueError:
        raise RuntimeError("PostgreSQL postmaster has an invalid loopback address") from None
    os.kill(value["pid"], 0)
    postgres = Path(value["postgres"]).resolve(strict=True)
    pg_ctl = Path(value["pg_ctl"]).resolve(strict=True)
    status = subprocess.run([str(pg_ctl), "-D", str(data), "status"], capture_output=True, text=True)
    command = subprocess.run(["ps", "-ww", "-p", str(value["pid"]), "-o", "command="],
                             capture_output=True, text=True)
    arguments = shlex.split(command.stdout.strip()) if command.returncode == 0 else []
    if status.returncode or not arguments or Path(arguments[0]).resolve() != postgres:
        raise RuntimeError("PostgreSQL owned executable/PID verification failed")
    if "-D" not in arguments or Path(arguments[arguments.index("-D") + 1]).resolve() != data:
        raise RuntimeError("PostgreSQL running process has a different data directory")
    psql = postgres.parent / "psql"
    if not psql.is_file() or not os.access(psql, os.X_OK):
        raise RuntimeError("Owned PostgreSQL installation has no executable psql")


def erlang_value(value):
    if isinstance(value, int):
        return str(value)
    return "<<" + ",".join(str(byte) for byte in value.encode()) + ">>"


def private_database_config(work, kind, postgres):
    private = work / "private"
    private.mkdir(mode=0o700)
    database = "arbor_cold_" + ("es" if kind == "eventstore" else "sql") + "_" + os.urandom(8).hex()
    if postgres:
        source = postgres["value"]
        copy_regular(postgres["path"], private / "postgres-fixture.json")
        (private / "postgres-fixture.json").chmod(0o600)
        options = {"database": database, "hostname": source["host"], "port": source["port"],
                   "username": source["user"], "password": source["password"]}
        def pgpass_field(value):
            return str(value).replace("\\", "\\\\").replace(":", "\\:")
        pgpass = private / "pgpass"
        pgpass.write_text(":".join(pgpass_field(value) for value in
                                   [source["host"], source["port"], "*", source["user"], source["password"]]) + "\n")
        pgpass.chmod(0o600)
    else:
        database = str(work / "runtime/data/adapter.sqlite3")
        options = {"database": database, "busy_timeout": 5000}
    config = private / "database.config"
    config.write_text("[" + ",".join("{" + key + "," + erlang_value(value) + "}"
                                      for key, value in options.items()) + "].\n")
    config.chmod(0o600)
    return config, database


def postgres_commands(postgres, database):
    value = postgres["value"]
    psql = Path(value["postgres"]).resolve().parent / "psql"
    base = [str(psql), "-X", "--no-password", "--set", "ON_ERROR_STOP=1", "--host", value["host"],
            "--port", str(value["port"]), "--username", value["user"], "--dbname", "postgres",
            "--tuples-only", "--no-align"]
    identity = "SELECT json_build_object('data_directory', current_setting('data_directory'), " \
               "'start_epoch', floor(extract(epoch from pg_postmaster_start_time()))::bigint, " \
               "'host', host(inet_server_addr()), 'port', inet_server_port())"
    return [("postgres-identity", base + ["--command", identity]),
            ("postgres-database", base + ["--command", "CREATE DATABASE " + database])]


def validate_postgres_connection(path, fixture):
    value = json.loads(path.read_text())
    expected = fixture["value"]
    if (Path(value["data_directory"]).resolve() != Path(expected["data_dir"]).resolve() or
            value["start_epoch"] != int(expected["postmaster_start_epoch"]) or
            value["port"] != expected["port"] or not ipaddress.ip_address(value["host"]).is_loopback):
        raise RuntimeError("PostgreSQL connection did not reach the attested private postmaster")


def validate_locations(args, work):
    package_source = Path(__file__).resolve().parents[1]
    repository = package_source.parents[1]
    source_roots = [repository] + [
        ancestor for ancestor in repository.parents
        if (ancestor / "apps/arbor_kernel/mix.exs").is_file()
    ]
    if any(work == root or root in work.parents for root in source_roots):
        raise RuntimeError("--work-dir must be outside all Arbor source checkouts")
    mix = args.mix.expanduser().resolve(strict=True)
    if not mix.is_file() or not os.access(mix, os.X_OK):
        raise RuntimeError("--mix must name an executable pinned Mix wrapper")
    database = args.database or ("postgres" if args.adapter == "eventstore" else "sqlite")
    if args.adapter == "core" and (args.database or args.postgres_fixture):
        raise RuntimeError("Core qualification does not accept database options")
    if args.adapter == "eventstore" and database != "postgres":
        raise RuntimeError("EventStore qualification requires PostgreSQL")
    postgres = None
    if args.adapter != "core" and database == "postgres":
        if not args.postgres_fixture:
            raise RuntimeError("PostgreSQL requires --postgres-fixture for the owned loopback cluster")
        postgres = load_postgres_fixture(args.postgres_fixture)
    elif args.postgres_fixture:
        raise RuntimeError("--postgres-fixture requires a PostgreSQL adapter selection")
    return package_source, repository, mix, database, postgres


def qualify(args, work, package_source, repository, mix, database_kind, postgres):
    if args.adapter == "core":
        selected_source = package_source
        package_prefix = "package"
        sources = [(package_prefix, package_source, PACKAGE_INPUTS)]
    else:
        selected_name = ADAPTERS[args.adapter]
        selected_source = repository / "packages" / selected_name
        package_prefix = "packages/" + selected_name
        sources = [("packages/arbor_persistence", package_source, PACKAGE_INPUTS),
                   (package_prefix, selected_source, PACKAGE_INPUTS + ("priv",))]
    sources.append(("consumer", selected_source / "examples/standalone", CONSUMER_INPUTS))
    expected = input_manifest(sources, repository / ".tool-versions")
    layout = [(prefix, names) for prefix, _source, names in sources]
    package, consumer = work / package_prefix, work / "consumer"
    consumer.mkdir()
    for prefix, source, names in sources:
        destination = work / prefix
        destination.mkdir(parents=True, exist_ok=True)
        for name in names:
            copy_regular(source / name, destination / name)
    copy_regular(repository / ".tool-versions", work / ".tool-versions")
    lock = (package / "mix.lock").read_bytes()
    if lock != (consumer / "mix.lock").read_bytes():
        raise RuntimeError("Selected package and consumer must retain the same immutable lockfile")
    core_lock = (package_source / "mix.lock").read_bytes()
    if set(re.findall(rb'^\s*"([^\"]+)":', core_lock, re.MULTILINE)) != {name.encode() for name in LOCK_NAMES}:
        raise RuntimeError("Expected only the three owned public lock records")
    for record in core_lock.splitlines():
        if any(re.match(rb'\s*"' + name.encode() + rb'":', record) for name in LOCK_NAMES):
            if record.strip() not in {line.strip() for line in lock.splitlines()}:
                raise RuntimeError("Selected adapter lock disagrees with an immutable Core dependency")
    manifest = source_manifest(work, layout)
    if manifest != expected or expected != input_manifest(sources, repository / ".tool-versions"):
        raise RuntimeError("Source changed during copying or copied SHA-256 values differ")
    write_json(work / "source-manifest.json", manifest)

    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("MIX_", "ARBOR_", "PERSISTENCE_", "SIGNALS_", "RELEASE_", "PG"))
        and key not in {"ERL_LIBS", "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ELIXIR_ERL_OPTIONS"}
    }
    runtime = work / "runtime"
    for directory in [runtime, runtime / "tmp", runtime / "data"]:
        directory.mkdir(mode=0o700)
    (runtime / "empty.env").write_text("")
    env.update({"MIX_ENV": "prod", "MIX_BUILD_PATH": str(consumer / "_build/prod"),
                "MIX_DEPS_PATH": str(consumer / "deps"), "PERSISTENCE_PACKAGE_PATH": str(package),
                "ARBOR_HOME": str(runtime), "ARBOR_DATA_DIR": str(runtime / "data"),
                "ARBOR_ENV_PATH": str(runtime / "empty.env"), "TMPDIR": str(runtime / "tmp"),
                "ERL_FLAGS": "+S 4:4"})
    env.pop("HEX_OFFLINE", None)
    if args.offline:
        env["HEX_OFFLINE"] = "1"
    sealed = {}
    database = None
    if args.adapter != "core":
        config, database = private_database_config(work, args.adapter, postgres)
        env.update({"PERSISTENCE_DATABASE_KIND": database_kind,
                    "PERSISTENCE_DATABASE_CONFIG": str(config),
                    "PERSISTENCE_ACK_PATH": str(runtime / "acknowledgment.term")})
        if postgres:
            env.update({"PGPASSFILE": str(work / "private/pgpass"), "PGCONNECT_TIMEOUT": "5",
                        "PGSSLMODE": "disable"})
        sealed = {str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (work / "private").iterdir() if path.is_file()}
    write_json(work / "qualification.json", {
        "adapter": args.adapter, "database_kind": None if args.adapter == "core" else database_kind,
        "database": database, "package_source": str(selected_source), "mix": str(mix),
        "work_dir": str(work), "postgres_fixture_sha256": postgres["sha256"] if postgres else None,
        "source_layout": [{"path": prefix, "inputs": names} for prefix, names in layout],
    })
    release_name = {"core": "persistence_standalone_consumer", "sql": "sql_standalone_consumer",
                    "eventstore": "eventstore_standalone_consumer"}[args.adapter]
    release_bin = consumer / "_build/prod/rel" / release_name / "bin" / release_name
    checks = [
        ("toolchain", [str(mix), "--version"], None),
        ("dependencies", [str(mix), "deps.get", "--only", "prod", "--check-locked"], None),
        ("compile", [str(mix), "compile", "--warnings-as-errors"], None),
    ]
    no_mix = "false = Code.ensure_loaded?(Mix); {:error, :bad_name} = :code.lib_dir(:mix); "
    if args.adapter == "core":
        expression = ":ok = PersistenceStandaloneConsumer.verify!()"
        checks.extend([
            ("consumer", [str(mix), "run", "--no-compile", "-e", expression], MARKER),
            ("release", [str(mix), "release", release_name], None),
            ("release-consumer", [str(release_bin), "eval", no_mix + expression], MARKER),
        ])
    else:
        if postgres:
            checks.extend((name, command, None) for name, command in postgres_commands(postgres, database))
        module = "SQLStandaloneConsumer" if args.adapter == "sql" else "EventStoreStandaloneConsumer"
        marker = "PERSISTENCE_SQL" if args.adapter == "sql" else "PERSISTENCE_EVENTSTORE"
        for name, function, suffix in [("migration", "install", "INSTALL"),
                                       ("writer", "write", "WRITE"),
                                       ("fresh-reader", "read", "READ")]:
            checks.append((name, [str(mix), "run", "--no-compile", "-e",
                                  f":ok = {module}.{function}!()"], marker + "_" + suffix + "_OK"))
        checks.extend([
            ("release", [str(mix), "release", release_name], None),
            ("release-reader", [str(release_bin), "eval", no_mix + f":ok = {module}.read!()"],
             marker + "_READ_OK"),
        ])
    results = []
    for name, command, marker in checks:
        validator = (lambda path: validate_postgres_connection(path, postgres)) if name == "postgres-identity" else None
        exit_code = run_step(work, consumer, env, results, name, command, manifest, layout,
                             marker, postgres, sealed, validator)
        if exit_code:
            return exit_code
        if name == "writer":
            receipt = runtime / "acknowledgment.term"
            digest = hashlib.sha256(receipt.read_bytes()).hexdigest()
            sealed[str(receipt.relative_to(work))] = digest
            write_json(work / "receipt-manifest.json", {"path": str(receipt.relative_to(work)), "sha256": digest})
            sealed["receipt-manifest.json"] = hashlib.sha256((work / "receipt-manifest.json").read_bytes()).hexdigest()
    verify_manifest(work, manifest, layout)
    verify_sealed(work, sealed)
    print(f"{args.adapter} qualification passed; retained evidence: {work}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True, help="New private directory outside Arbor")
    parser.add_argument("--mix", type=Path, required=True, help="Executable pinned Mix wrapper")
    parser.add_argument("--adapter", choices=["core", "sql", "eventstore"], default="core")
    parser.add_argument("--database", choices=["sqlite", "postgres"], help="SQL defaults to SQLite; EventStore requires PostgreSQL")
    parser.add_argument("--postgres-fixture", type=Path, help="Explicit private owned-loopback PostgreSQL fixture manifest")
    parser.add_argument("--offline", action="store_true", help="Use only the existing public Hex cache")
    args = parser.parse_args()
    work = args.work_dir.expanduser().resolve()
    # Never write into or reuse an earlier attempt, even when handling failure.
    if work.exists():
        parser.error("--work-dir already exists; choose a new directory")
    created = False
    try:
        locations = validate_locations(args, work)
        work.mkdir(mode=0o700, parents=True, exist_ok=False)
        created = True
        return qualify(args, work, *locations)
    except Exception as error:
        if created:
            write_json(work / "failure.json", {"type": type(error).__name__, "message": str(error)})
        print(f"Qualification failed: {error}; retained attempt: {work}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
