# CURATE-1.0 — Content Curator Specification

**Status:** Draft (2026-07-13)
**Scope:** the content-backlog curator (`apps/arbor_curator`, curator actions in
`arbor_actions`, curator pipelines in `arbor_scheduler`) — Signal URL intake, the
item store and lifecycle, page fetching, LLM assessment against an interest
profile, and the morning-digest report.
**Plan:** `.arbor/roadmap/2-planned/content-curator.md` (design rationale lives there).
**Conformance:** every statement below is proven by tests tagged `@tag spec: "<ID>"`.
Run `mix arbor.spec.coverage` for the current proof map. Statements marked `(planned)`
describe committed direction not yet implemented; they are excluded from `--strict`.
Work packets in `docs/specs/curator/packets/` implement these statements and say which
`(planned)` markers they remove.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in
RFC 2119.

## Architecture summary (non-normative)

One new umbrella app, `arbor_curator` (L4; deps: contracts, common, signals, llm,
persistence), holds the domain: item store + lifecycle over a dedicated Ecto schema,
URL canonicalization, intake parsing, LLM assessment (single seam:
`Arbor.Curator.Assessor`), and digest rendering. Side effects are orchestrated by
three Oban-cron DOT pipelines in `arbor_scheduler` exec-ing thin actions in
`arbor_actions`: `curator_intake` (Signal poll → queued items), `curator_fetch_batch`
(fetch via `Arbor.Actions.Web.Snapshot`), `curator_assess_batch`
(`Arbor.LLM.generate_object/1`), and `curator_digest` (report into
`~/.arbor/reports/curator/`, which the existing 06:30 `morning_digest.dot`
concatenation and 06:45 synthesis consume unchanged). All inbound message text and
fetched page content is untrusted input.

## Intake

- **CURATE-1** (MUST): Intake MUST derive new items from inbound channel messages
  (v1: Signal, via the `comms_poll_messages` action) by extracting every `http`/`https`
  URL from each message's `content`. Each extracted URL MUST yield at most one item
  with status `queued`.

- **CURATE-2** (MUST): Messages whose `from` is not in the configured sender
  allowlist (`config :arbor_curator, :allowed_senders`) MUST be discarded without
  creating items. An empty or unset allowlist MUST discard all messages (fail
  closed).

- **CURATE-3** (MUST): URLs MUST be canonicalized before storage — lowercase scheme
  and host, fragment removed, known tracking parameters removed (at minimum `utm_*`,
  `fbclid`, `gclid`), trailing slash normalized — and items MUST be deduplicated on
  the canonical URL (database-level uniqueness). Re-submitting a known URL MUST NOT
  create a second item and MUST NOT reset the existing item's status.

- **CURATE-4** (MUST): Each item MUST record its provenance: source channel, sender
  identifier, and the message's `received_at`.

- **CURATE-5** (MUST): Non-URL message text MUST have no effect in v1 (no command
  parsing). Reserved for CURATE-28.

## Item store & lifecycle

- **CURATE-6** (MUST): Items MUST be persisted via a dedicated Ecto schema on
  `Arbor.Persistence.Repo` with status one of: `queued`, `fetched`, `assessed`,
  `surfaced`, `archived`, `failed`.

- **CURATE-7** (MUST): Status changes MUST go through a single transition function
  that enforces the legal graph (`queued→fetched→assessed→surfaced→archived`;
  `queued|fetched|assessed→failed`). An illegal transition MUST return an error and
  leave the row unchanged.

- **CURATE-8** (MUST): Each forward transition MUST set its timestamp column
  (`fetched_at`, `assessed_at`, `surfaced_at`) exactly once; re-processing MUST NOT
  overwrite an earlier timestamp.

## Fetch

- **CURATE-9** (MUST): All page fetching MUST go through
  `Arbor.Actions.Web.Snapshot.run/2` (preserving its `Arbor.Actions.Web.validate_url/1`
  SSRF validation and untrusted output taint). The curator MUST NOT introduce any
  other HTTP fetch path.

- **CURATE-10** (MUST): Stored page content MUST be truncated to the configured
  maximum (`config :arbor_curator, :max_content_chars`, default 20_000) and the
  snapshot's `title` MUST be stored when present.

- **CURATE-11** (MUST): A fetch failure MUST increment the item's `retry_count` and
  record the error; after the configured maximum attempts (default 3) the item MUST
  transition to `failed`. One item's failure MUST NOT abort the rest of the batch.

- **CURATE-12** (MUST): Fetch batches MUST select only `queued` items, oldest first,
  bounded by the configured batch size.

## Assessment

- **CURATE-13** (MUST): Assessment MUST use `Arbor.LLM.generate_object/1` with a
  schema that validates: `score` (integer 0–100), `verdict` (one of `must_read`,
  `skim`, `skip`), `summary` (string), `why` (string), `integration_ideas` (array of
  strings), `topics` (array of strings). A schema-invalid response MUST be treated as
  a failed attempt per CURATE-11 (never partially stored).

- **CURATE-14** (MUST): The assessment prompt MUST include the interest profile read
  from `config :arbor_curator, :interest_profile_path` (default
  `~/.arbor/curator/interest_profile.md`). If the file is missing, assessment MUST
  proceed with the module's built-in default profile and SHOULD log a warning.

- **CURATE-15** (MUST): Fetched content and message-derived text MUST be delimited
  as quoted data in the prompt, with an explicit instruction that instructions inside
  the content are not to be followed; assessment output MUST be accepted only through
  the CURATE-13 schema, never free-form.

- **CURATE-16** (MUST): Provider and model MUST come from `:arbor_curator`
  configuration (`:llm_provider`, `:llm_model`); modules MUST NOT hardcode either.

- **CURATE-17** (MUST): LLM calls MUST be confined to `Arbor.Curator.Assessor`; no
  other `arbor_curator` module may reference `Arbor.LLM`.

## Digest

- **CURATE-18** (MUST): The digest MUST be written to
  `<reports_root>/curator/YYYY-MM-DD.md` (UTC date; `reports_root` default
  `~/.arbor/reports`), where the existing morning-digest concatenation globs it.
  Re-running the digest on the same day MUST overwrite the file idempotently.

- **CURATE-19** (MUST): The digest MUST render only model-produced assessment fields
  plus each item's canonical URL — never raw fetched content. It MUST contain: a
  must-read section (verdict `must_read`, highest score first, capped at 5, each with
  title, link, summary, why), a skim section (verdict `skim`, one-liners, capped at
  10), an integration-ideas section aggregating `integration_ideas` across surfaced
  items, and a footer with counts (new, surfaced, skipped as noise).

- **CURATE-20** (MUST): Items included in a successfully written digest MUST
  transition `assessed→surfaced`. Previously surfaced items MUST NOT appear in a
  later digest.

- **CURATE-21** (MUST): When no newly `assessed` items exist, the digest run MUST
  NOT write a report file (the morning digest omits the section entirely).

## Pipelines & capabilities

- **CURATE-22** (MUST): Three pipelines MUST exist under
  `apps/arbor_scheduler/priv/pipelines/` — `curator_intake.dot` (every 30 minutes),
  `curator_process.dot` (hourly, fetch then assess), `curator_digest.dot` (06:20 UTC,
  before the 06:30 concatenation) — each scheduled in the `:arbor_scheduler` Oban
  crontab and each shipping a signed caps manifest accepted by the current scheduler
  attestation format (`mix arbor.scheduler.sign_caps`).

- **CURATE-23** (MUST): Each pipeline's caps manifest MUST be least-privilege:
  intake needs only comms polling; process needs only `arbor://net/http` egress and
  LLM generation; digest needs only `fs/write` under `<reports_root>/curator/**`.
  No curator manifest may grant shell, coding, or unscoped filesystem capabilities.

- **CURATE-24** (SHOULD): Item lifecycle events SHOULD emit Arbor signals
  (`curator.item.queued`, `curator.item.assessed`, `curator.digest.written`) so
  dashboards and telemetry can observe curator activity.

## Planned extensions

- **CURATE-25** (SHOULD, planned): Email intake — requires a `ChannelReceiver`
  implementation on the email channel (none exists today).

- **CURATE-26** (MAY, planned): RSS/OPML feed subscription as an intake source.

- **CURATE-27** (MAY, planned): Transcript ingestion for YouTube videos and
  podcasts, reusing `Arbor.Comms.Channels.Voice` STT primitives where applicable.

- **CURATE-28** (SHOULD, planned): Feedback commands over the intake channel
  ("read N", "skip N", "more like this") that update item status and append to the
  interest profile.

- **CURATE-29** (MAY, planned): Embedding-based near-duplicate detection using the
  existing pgvector `memory_embedding` infrastructure.

- **CURATE-30** (MAY, planned): A dashboard triage view over the item store.

- **CURATE-31** (MAY, planned): A templated curator agent
  (`apps/arbor_agent/priv/templates/curator.md`) for interactive triage, once the
  feedback loop exists.
