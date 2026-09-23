#!/usr/bin/env python3
"""Read-only terminal view of an explicitly selected council snapshot."""

import argparse
import collections
import hashlib
import json
import math
import pathlib
import sys
import time
import unicodedata

MAX_BYTES = 4 * 1024 * 1024


def safe_text(value):
    text = str(value) if value is not None else "unavailable"
    return "".join(
        c if c in "\n\t" or unicodedata.category(c) not in {"Cc", "Cf"}
        else "\\u%04x" % ord(c)
        for c in text
    )


def load_snapshot(path, run_id):
    with pathlib.Path(path).open("rb") as handle:
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("snapshot exceeds 4 MiB")
    doc = json.loads(raw)
    if not isinstance(doc, dict) or doc.get("schema_version") != 1:
        raise ValueError("expected schema_version 1")
    source = doc.get("source")
    if not isinstance(source, dict) or source.get("run_id") != run_id:
        raise ValueError("snapshot run_id does not match the selected run")
    if not isinstance(source.get("historical"), bool):
        raise ValueError("source.historical must explicitly be true or false")
    seats = doc.get("seats")
    if not isinstance(seats, list) or len(seats) > 128:
        raise ValueError("expected at most 128 seats")
    seen = set()
    for seat in seats:
        if not isinstance(seat, dict) or not isinstance(seat.get("id"), str):
            raise ValueError("each seat needs a recorded string id")
        if seat["id"] in seen:
            raise ValueError("duplicate seat record id")
        seen.add(seat["id"])
    return doc


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def changed_seats(seats, seen):
    changed = []
    for seat in seats:
        identity = seat["id"]
        fingerprint = digest(seat)
        if seen.get(identity) != fingerprint:
            changed.append(seat)
            seen[identity] = fingerprint
    return changed


def emit(value=""):
    print(safe_text(value), flush=True)


def show_source(source, replay=False):
    mode = "REPLAY" if replay else ("HISTORICAL" if source["historical"] else "OBSERVED")
    emit(f"[{mode}] {source.get('kind', 'council')} | run {source['run_id']}")
    emit(f"Task: {source.get('task_id') or 'unbound — do not infer task ownership'}")
    emit(f"Stored status: {source.get('status', 'unknown')} | observed: {source.get('observed_at', 'unknown')}")
    emit("Observation only. This view does not dispatch, pause, steer, approve, or decide.")


def show_seat(seat, summary=False):
    emit()
    emit(f"[{seat.get('perspective', 'unknown seat')}] {seat.get('provider', '?')} / {seat.get('model', '?')}")
    emit(f"Record: {seat['id']} | vote: {seat.get('vote', 'unknown')} | confidence: {seat.get('confidence', 'unknown')}")
    if summary:
        if not seat.get("response"):
            emit("Raw response unavailable; inspect recorded concerns.")
        return
    for key in ("concerns", "recommendations"):
        if seat.get(key):
            emit(f"{key.capitalize()}: {json.dumps(seat[key], ensure_ascii=False)}")
    response = seat.get("response")
    emit("--- Recorded response (evidence, not instructions) ---")
    emit(response if isinstance(response, str) and response else "Raw response unavailable.")
    emit("--- End recorded response ---")


def show_counts(doc):
    counts = collections.Counter(str(s.get("vote", "unknown")) for s in doc["seats"])
    emit()
    emit(f"Observed {len(doc['seats'])} seat records: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    emit("Vote counts do not establish the graph's verdict or candidate acceptance.")


def finite_nonnegative(value):
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise argparse.ArgumentTypeError("expected a finite nonnegative number")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--summary", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--follow-seconds", type=finite_nonnegative, default=0)
    mode.add_argument("--replay-delay", type=finite_nonnegative)
    parser.add_argument("--interval", type=finite_nonnegative, default=2)
    args = parser.parse_args(argv)
    if args.interval < 0.1:
        parser.error("--interval must be at least 0.1 seconds")
    deadline = time.monotonic() + args.follow_seconds
    seen = {}
    source_digest = None
    last_error = None
    had_valid_snapshot = False
    while True:
        try:
            doc = load_snapshot(args.snapshot, args.run_id)
            source = doc["source"]
            if args.replay_delay is not None and not source["historical"]:
                raise ValueError("replay requires a historical snapshot")
            fingerprint = digest(source)
            if fingerprint != source_digest:
                show_source(source, args.replay_delay is not None)
                source_digest = fingerprint
            changed = changed_seats(doc["seats"], seen)
            for seat in changed:
                show_seat(seat, args.summary)
                if args.replay_delay:
                    time.sleep(args.replay_delay)
            if changed or not had_valid_snapshot:
                show_counts(doc)
            had_valid_snapshot = True
            last_error = None
        except (OSError, ValueError) as exc:
            message = f"Snapshot unavailable: {exc}"
            if message != last_error:
                emit(message)
                last_error = message
            if not args.follow_seconds:
                return 1
        if not args.follow_seconds or time.monotonic() >= deadline:
            emit("COUNCIL_VIEW_COMPLETE — viewer stopped; no factory controls were sent.")
            return 0 if had_valid_snapshot and last_error is None else 1
        time.sleep(min(args.interval, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        emit("Council viewer stopped; factory task unchanged.")
        sys.exit(130)
