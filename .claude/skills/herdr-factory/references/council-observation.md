# Council evidence and live observation

Verified against Arbor source and recorded consultation data on 2026-09-22.
Recheck the named boundaries before relying on this implementation snapshot.

## Persisted text comes first

The running repository was verified as `Ecto.Adapters.Postgres` during the trial
follow-up on 2026-09-22. Ordinary advisory consultations persist the returned text
in `eval_results.actual`, exposed through `Arbor.Consensus.get_consultation/1`.
For example, consultation `ot6vmuoe9d31cb4aedfl5raoqs` contains a 7,231-character
brainstorming response and a 7,118-character emergence response with full written
analysis. Read that text before interpreting votes. The ordinary advisory parser
assigns `approve` while carrying the substantive opinion in its reasoning text;
that field alone is not a semantic endorsement of everything discussed.

The trial consultation `4qa1ardhj6u9j6g11co7bj16h8` used the separate
`design_review` protocol. Its prompt required exactly verdict and concerns, with
no prose or extra fields. The nine 35-character approvals in its export were the
complete stored responses, not clipped explanations. Its four failed seats have
no raw response. Do not generalize that sample into a missing council-text store.
The design-review response contract was updated on 2026-09-22 to require
`{"verdict":"approve","rationale":"...","concerns":[]}` for new calls. Both
`approve` and `rework` require a non-empty written justification tied to design
choices, frozen requirements, evidence, and material assumptions or limitations.
Missing or invalid rationale becomes a reject/rework evaluation with an explicit
parse concern; it cannot count as that seat's approval. The original response is
preserved, so its claimed JSON verdict can differ from the admitted score on a
malformed response. The existing aggregate council policy still owns the gate.

The rationale remains in `eval_results.actual` as part of the complete JSON (and
in `Evaluation.reasoning`); no database migration or historical backfill is needed.
Decode it for explanation while retaining the raw text as evidence. Historical
records remain valid evidence of the protocol used at the time. Check the loaded
runtime before assuming new source has taken effect; an old running node may still
request the old response shape.

Binding code-review verdicts are also persisted in the eval tables, under
`code_review`: the serialized verdict is in `actual`, and full structured review
metadata, including the finding ledger, is in `metadata["review"]`. This is
different from retaining every intermediate assistant message before a terminal
review-report tool call. Do not claim a complete per-seat deliberation transcript
without verifying that producer-to-store path.

The shared-log caveat below concerns live attribution of the binding graph's
per-seat files. It does not prevent reading existing persisted consultations and
code-review evidence from Postgres.

## Council protocols

**Design council.** `Arbor.Consensus.list_consultations/1` discovers persisted
consultations; `Arbor.Consensus.get_consultation/1` returns one exact run with its
perspective results. `ConsultationLog.log_single/5` stores each finished seat,
including provider failures. A running row can therefore be polled by exact run ID
without waiting for all seats. The public list helper's documented status filters
are completed/failed; do not assume a `running` filter works without inspecting
the current API. A bare consultation can have `task_id: nil` even when its question
describes factory work. Discover the design council ID from task/checkpoint
evidence; if it is unavailable until completion, report that limitation.

The seat's `actual` field is the available raw response, `scores["vote"]` is its
recorded vote, and `metadata` contains perspective, provider, model, concerns, and
recommendations. `actual: nil` does not mean approval or an empty successful reply.
Keep the failure concerns visible. A consultation row's `completed` status does
not by itself mean that the design or implementation was accepted.

**Binding code-review council.** `coding-change-v1.dot` calls
`council_review_change`, whose nested graph is owned by
`apps/arbor_actions/priv/pipelines/code-review-council.dot`. It runs parallel seats
and produces the frozen finding ledger and disposition. Read the exact task's
`review_change/status.json`, the task result, and any referenced persisted verdict.
The action's compact result can omit detail: use its recorded verdict run ID and
the public persistence facade to obtain the full record when needed. Read the
actual record shape; do not invent absent seat transcripts from ledger findings.

Current source caveat: `Council.default_review_runner` calls `Consensus.decide`,
and `Evaluators.Consult.decide` builds Engine options without a task-specific
`logs_root` or an observer `on_event`. Engine defaults to a shared temporary
`arbor_orchestrator` directory. LLM nodes write `response.md` at node completion,
but `security/response.md` under that shared root cannot prove task/cycle ownership.
It is unsuitable as a multi-run live council feed. Do not turn those files into
trusted task-attributed output or claim token streaming.

A future live feed should be published by the existing graph execution: bind
task ID, child council run, candidate, review cycle/design attempt, seat, sequence,
and response artifact identity. The observer consumes it; it does not launch the
seats. Persist completed responses, expose them incrementally, and make observer
failure independent of execution. Surface partial/missing evidence explicitly.
This is an observability integration, not a new decision-making agent.

## Export one recorded consultation

Use the available trusted local read surface (for example Tidewave `project_eval`)
to call the public facade. Substitute a verified consultation ID. Do not run a new
consultation to obtain a display, or put credentials in the export.

```elixir
{:ok, run} = Arbor.Consensus.get_consultation("VERIFIED_CONSULTATION_ID")
snapshot = %{
  schema_version: 1,
  source: %{
    kind: "design_consultation",
    run_id: run.id,
    task_id: run.task_id,
    status: run.status,
    recorded_at: run.inserted_at,
    observed_at: DateTime.utc_now(),
    historical: true
  },
  seats: Enum.map(run.results, fn row ->
    meta = row.metadata || %{}
    %{
      id: row.id,
      perspective: row.sample_id,
      provider: meta["provider"],
      model: meta["model"],
      vote: row.scores["vote"],
      confidence: row.scores["confidence"],
      response: row.actual,
      concerns: meta["concerns"] || [],
      recommendations: meta["recommendations"] || [],
      recorded_at: row.inserted_at
    }
  end)
}
IO.puts(Jason.encode!(snapshot))
```

Save those JSON bytes in an operator-owned snapshot outside the candidate tree.
For an actual live, exactly correlated run, set `historical: false`; refresh that
same file from the same facade while the collector is actively running. Preserve
null task identity rather than guessing it. The viewer checks the selected run ID
and retries incomplete reads while following, but snapshots are local display
data, not authenticated acceptance artifacts.

```bash
python3 SKILL_DIR/scripts/council_view.py --snapshot SNAPSHOT --run-id EXACT_ID
python3 SKILL_DIR/scripts/council_view.py --snapshot SNAPSHOT --run-id EXACT_ID --summary
python3 SKILL_DIR/scripts/council_view.py --snapshot SNAPSHOT --run-id EXACT_ID --follow-seconds 300
```

Use a fresh follow process for another run; never silently switch a pane to the
latest council. Preserve the raw export for attribution and detailed inspection.
The view escapes terminal control characters and displays full available response
strings; it does not redact secrets. Export only operator-authorized review fields.

## Steering is a separate control

A Council agent can turn "I disagree with the security seat" into a precise draft:
task and candidate/cycle, seat/finding ID, disputed claim, evidence, requested
correction, and eligible worker phase. The coordinator checks current state and
delivers through the supported task control when authorized.

Do not promise that `arbor_steer_task` changes an in-flight council LLM prompt. It
controls the coding task's worker delivery. Follow the returned control's actual
delivery state. The graph may already advance from review to rework before the
user finishes reading. If intervention must happen first, use a supported explicit
operator gate or propose that product change; reading the pane alone cannot stop it.

## Trial boundary

The initial Herdr trial replayed an existing 13-seat design consultation, including
four provider-error abstentions and nine recorded approvals. It tested pane
creation, preserved focus, complete response display, and observer interpretation.
It did not dispatch a new coding change, obtain a new council verdict, or prove
live binding-review steering. Never report a replay as that proof.

The read-only observer correctly kept provider-error abstentions separate from
design objections and drafted an action without sending it. Its initial claim
that short approvals meant shallow review was not established by the evidence;
the skill now explicitly guards against that inference. The viewer's eight
behavior checks cover exact-run selection, missing responses, incremental change
detection, terminal control escaping, malformed snapshots, replay labels, and
duplicate seat records. A process-level follow test publishes another seat after
the viewer displays its first snapshot, then verifies the same process displays
the new response without repeating the original one. Run the checks with
`PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_council_view.py` from this skill's
directory.
