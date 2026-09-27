#!/usr/bin/env python3
"""Qualify the journal with isolated OS BEAMs and a retained SQLite artifact.

Run after candidate test compilation, with no concurrent Mix compiler:
  python3 apps/arbor_comms/test/support/conversation_journal_qualify.py

No Arbor application, Session, provider, credential, or live database is used.
"""

import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import threading
import time
import uuid


WORKSPACE = Path(__file__).resolve().parents[4]
STAMP = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
RUN = WORKSPACE.parent / f"conversation-journal-qualification-{STAMP}-{uuid.uuid4().hex[:8]}"
RUN.mkdir()
DB = RUN / "journal.sqlite3"
WORKER = WORKSPACE / "apps/arbor_comms/test/support/conversation_journal_worker.exs"
ENV = dict(os.environ, MIX_ENV="test")
children = []
trace = []
checks = []
lock = threading.Lock()


def redact(value):
    if isinstance(value, dict):
        return {key: redact(item) for key, item in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
        return {"claim_token_sha256": hashlib.sha256(value.encode()).hexdigest()}
    return value


def spawn(operation, *args):
    command = [str(WORKSPACE / "bin/mix"), "run", "--no-start", "--no-compile",
               str(WORKER), str(RUN), str(DB), operation, *args]
    child = subprocess.Popen(command, cwd=WORKSPACE, env=ENV, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, start_new_session=True)
    with lock:
        children.append(child)
    return child


def record(operation, child, result, output):
    with lock:
        trace.append({"operation": operation, "process": child.pid,
                      "returncode": child.poll(), "result": redact(result),
                      "diagnostics": [line for line in output.splitlines()
                                      if not line.startswith("JOURNAL_RESULT ")]})


def parse(output):
    lines = [line.removeprefix("JOURNAL_RESULT ") for line in output.splitlines()
             if line.startswith("JOURNAL_RESULT ")]
    if len(lines) != 1:
        raise AssertionError(f"Expected one worker result; output: {output[-4000:]}")
    return json.loads(lines[0])


def call(operation, *args):
    child = spawn(operation, *args)
    output, _ = child.communicate(timeout=40)
    result = parse(output)
    record(operation, child, result, output)
    assert child.returncode == 0, (operation, child.returncode, output[-4000:])
    return result


def hold(operation, *args):
    child = spawn(operation, *args)
    deadline = time.monotonic() + 40
    output = ""
    while time.monotonic() < deadline:
        ready, _, _ = select.select([child.stdout], [], [], max(0, min(0.25, deadline - time.monotonic())))
        if ready:
            chunk = os.read(child.stdout.fileno(), 65536)
            if not chunk:
                break
            output += chunk.decode("utf-8", errors="replace")
            if any(line.startswith("JOURNAL_RESULT ") for line in output.splitlines(keepends=True) if line.endswith("\n")):
                result = parse(output)
                record(operation, child, result, output)
                return child, result
    raise AssertionError(f"Held worker failed to report: {output[-4000:]}")


def kill(child):
    os.killpg(child.pid, signal.SIGKILL)
    child.wait(timeout=10)
    assert child.returncode == -signal.SIGKILL
    with lock:
        trace.append({"operation": "SIGKILL", "process": child.pid,
                      "returncode": child.returncode, "reaped": True})
    child.stdout.close()


def check(name, condition):
    checks.append({"name": name, "passed": bool(condition)})
    assert condition, name


failure = None
try:
    check("isolated database initialized", call("init")["ok"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        admissions = list(pool.map(lambda _: call("admit", "race", "exact α"), range(4)))
    check("four independent BEAMs preserve one exact admission",
          all(item["ok"] for item in admissions) and
          len({json.dumps(item["value"], sort_keys=True) for item in admissions}) == 1 and
          len({item["runtime"]["os_pid"] for item in admissions}) == 4)
    check("changed retry conflicts after restart",
          call("admit", "race", "changed").get("error") == ":command_conflict")

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        claims = list(pool.map(lambda _: call("claim", "race"), range(4)))
    winners = [item for item in claims if item["ok"]]
    check("four independent claimers produce one winner",
          len(winners) == 1 and sum(item.get("error") == ":already_claimed" for item in claims) == 3)
    token = winners[0]["value"]
    settled = call("settle", "race", token)
    reopened = call("get", "race")
    check("completed outcome survives another BEAM",
          settled["ok"] and settled["value"]["status"] == "completed" and
          reopened["ok"] and reopened["value"] == settled["value"])
    check("equal settlement retry preserves exact terminal", call("settle", "race", token)["value"] == settled["value"])

    admitted_child, admitted = hold("hold-admit", "before_claim", "admitted before abrupt loss")
    check("admission committed before abrupt BEAM loss", admitted["ok"] and admitted["value"]["status"] == "admitted")
    kill(admitted_child)
    recovered_claim = call("claim", "before_claim")
    check("unclaimed admission can be claimed after BEAM loss", recovered_claim["ok"])
    check("recovered admission can complete", call("settle", "before_claim", recovered_claim["value"])["value"]["status"] == "completed")

    check("second command admitted", call("admit", "after_claim", "claim before abrupt loss")["ok"])
    claimed_child, claimed = hold("hold-claim", "after_claim")
    check("claim committed before abrupt BEAM loss", claimed["ok"])
    kill(claimed_child)
    unresolved = call("get", "after_claim")
    check("claimed command remains factual unresolved after BEAM loss",
          unresolved["ok"] and unresolved["value"]["status"] == "dispatch_started" and
          unresolved["value"]["outcome"] is None)
    check("saved claim cannot be reacquired after BEAM loss",
          call("claim", "after_claim").get("error") == ":already_claimed")
    replay = call("events")
    check("durable replay has eight contiguous events and no claim capability",
          replay["ok"] and replay["value"]["head"] == 8 and
          [event["cursor"] for event in replay["value"]["events"]] == list(range(1, 9)) and
          "claim_token" not in json.dumps(replay["value"]))
except BaseException as error:
    failure = f"{type(error).__name__}: {error}"
finally:
    for child in children:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=10)
        if child.stdout and not child.stdout.closed:
            child.stdout.close()
    closed = all(child.poll() is not None for child in children)
    sources = [
        "apps/arbor_comms/lib/arbor/comms/config.ex",
        "apps/arbor_comms/lib/arbor/comms/conversation_journal.ex",
        "apps/arbor_comms/lib/arbor/comms/conversation_journal_core.ex",
        "apps/arbor_comms/test/arbor/comms/conversation_journal_test.exs",
        "apps/arbor_comms/test/arbor/comms/conversation_journal_core_test.exs",
        "apps/arbor_comms/test/support/conversation_journal_sqlite.exs",
        "apps/arbor_comms/test/support/conversation_journal_worker.exs",
        "apps/arbor_comms/test/support/conversation_journal_qualify.py",
        "apps/arbor_persistence/lib/arbor/persistence.ex",
    ]
    hashes = {path: hashlib.sha256((WORKSPACE / path).read_bytes()).hexdigest() for path in sources}
    report = {"passed": failure is None and closed, "failure": failure, "checks": checks,
              "worker_count": len(children), "all_workers_reaped": closed,
              "database": str(DB), "sources_sha256": hashes,
              "limits": ["Journal qualification only; no Session turn or external effect executed.",
                         "No distributed lease, orphan terminalizer, or partition recovery is claimed.",
                         "SQLite BEAM-kill durability, not machine power-loss qualification."]}
    (RUN / "trace.json").write_text(json.dumps(trace, indent=2) + "\n")
    (RUN / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'} {sum(c['passed'] for c in checks)}/{len(checks)}: {RUN}")
    if failure:
        print(failure, file=sys.stderr)
sys.exit(0 if report["passed"] else 1)
