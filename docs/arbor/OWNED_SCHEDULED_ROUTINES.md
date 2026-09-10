# Owner-bound scheduled routines

Source packet prepared 2026-09-10. This is a closed, opt-in lane for the reviewed
`morning_digest` program. Deployment activation, an enrolled v2 manifest and
standing Trust policy are separate work; the bundled unsigned artifact does not
enable this lane.

## Public contract

`Arbor.Scheduler.prepare_routine_intent(principal, "morning_digest", scheduled_at,
request_id)` returns an unsigned intent using the configured manifest and current
held capability IDs. Preparation confers no authority. `routine_request_payload/2`
returns the canonical bytes to sign with `SignedRequest`:

- `:enqueue`: a closed version-1 intent containing routine, manifest digest,
  scheduled UTC time, request ID, and exact selected parent capability IDs and
  signed-payload digests. `enqueue_routine(intent, proof)` returns a public job
  projection after fresh signature, nonce, owner authority and SQL admission.
- `:list`: closed string-key filters `limit` (1–100, default 20) and optional
  `before_id`. `list_owned_routines(filters, proof)` returns verified owned
  projections and an owned cursor. SQL filters by the retained principal as a
  non-authoritative hint; every candidate still requires historical signature
  verification. Invalid rows are omitted. A bounded page may therefore be short.
- `:cancel`: the positive job ID. `cancel_owned_routine(id, proof)` reauthenticates
  the exact owner and cancels the exact observed SQL row through Oban. A state
  race requires a fresh request and observation; it never cancels a replacement.

The signing principal owns the schedule. An agent tool execution signs as that
agent; Session human metadata never changes ownership. A directly authenticated
human principal can sign the same public protocol. Copying an owner ID, capability
ID, request ID, or an old operation proof cannot authenticate a new request.

The tool adapters are `scheduler_enqueue_routine`, `scheduler_list_routines`, and
`scheduler_cancel_routine` (also ordinary canonical dot aliases). The existing
ActionsExecutor source signing boundary signs a second, operation-specific
request. Actions receive signed data, never a signing authority or signing
callback. Enqueue and cancel remain denied under the private-turn memory write
policy. This lane does not qualify private-human scheduling through an agent
signer.

The scheduled time is canonical UTC ISO8601 at whole seconds, within 30 days of
ingress (60 seconds of past clock tolerance). Request IDs are 16–96 ASCII letters,
digits, underscores or hyphens, beginning with a letter or digit. The exact owner
and request ID determine an opaque SQL uniqueness key. Fresh retries with the
same exact intent return the retained job; conflicting intent reports
`:routine_request_conflict`. Idempotency lasts while the authoritative Oban row
is retained. Pruning or operator deletion removes that retention guarantee.

## Effect admission

The worker reloads the actual Oban row rather than trusting supplied worker args.
It verifies the original signature, active identity, current manifest, selected
original grants and effective Trust mode. Original root-issued ordinary grants
must be unscoped and have no delegation, counters or nonempty constraints. Their
current signature, signed-payload digest, expiry, not-before and revocation remain
conjunctive. Another covering grant never substitutes for the selected grant.
`:ask` and `:block` refuse autonomous execution.

SQL atomically claims one holder for the exact stored job, attempt, execution
metadata and envelope using a random token digest. RunLease then binds that token
to its monitored owner and ephemeral execution principal. This is a
**Scheduler-admitted execution holder**, not proof that an arbitrary caller PID
was authenticated by Oban. The source-created token travels through nonresumable
Engine options to the resolved digest action only. It is absent from graph
context, checkpoint data, provider data and public job projections. Lease status
formatting and public failure results redact private admission data.

Each actual read, temporary-file write and final publication requires the normal
ephemeral FileGuard gate and the original owner's current gate. The latter
rechecks the exact SQL attempt/token, cancellation, original signature, current
manifest, current identity/capability/Trust authority, and exact permitted path.
The lease checks holder liveness and monotonic expiry before and after blocking
admission work. A missing, retired or malformed lease is an authorization refusal;
idempotent cleanup success is never reused as effect authorization.

Cancellation and revocation apply to future, unadmitted effects. They cannot roll
back an already admitted OS operation. These sequential boundaries are not an
atomic transaction with external filesystem operations. Digest success acknowledges
rename, not directory-fsync durability. Holder/BEAM death may leave a temporary
file or an indeterminate prior effect. This lane does not promise exactly-once
filesystem effects after an ambiguous failure, arbitrary graph confinement,
private-key protection from arbitrary same-VM code, or protection against hostile
SQL schema replacement.

## Deployment prerequisites

Apply the existing Repo owner's migration
`20260909000001_unique_owned_routine_requests.exs` to the selected deployment
before enabling ingress. It adds a partial unique expression index on the existing
`oban_jobs` table for this worker only. SQLite and Postgres forms are explicit.
The migration never deletes or merges existing jobs; duplicate preexisting keys
require operator review. Enqueue refuses with `:routine_store_migration_required`
when the required index is absent. Only the default SQL schema is supported.
Every Oban insert result is reconciled against a positive committed SQL row and
its exact key, signature and intent. An advisory-lock loser or `DO NOTHING` result
with no visible winner returns `:routine_enqueue_not_committed`; it never reports
a queued job with a missing ID. This is a bounded observation, not a background
retry or a promise that an unobserved concurrent winner failed.

Configure `:arbor_scheduler, :morning_digest_pipeline` and `:pipeline_roots` to the
reviewed exact source graph with a valid v2 issuer attestation, exact initial args
and a canonical existing workdir. This first lane deliberately refuses spaces and
URI-special characters in workdirs; it accepts bounded absolute ASCII directory
paths using letters, digits, `_`, `.`, `-` and `/`. Concrete file resources use the
public Security path normalizer, then the reviewed manifest appends only its
trailing directory wildcard. Required directories are:

- `reports/upstream-deps`
- `reports/upstream-deps-summary`
- `reports/morning-digest`

The manifest and issuer envelope need the exact report action, two scoped read
grants and one scoped output write grant. The original owner additionally needs
the orchestrator lobby (`arbor://orchestrator/execute`); the execution identity
receives that implicit lobby separately, so it need not be repeated in the
manifest. The effective owner policy must explicitly permit the exact output
directory. Default write `:ask`
remains a refusal; caps-file metadata is not standing owner consent. The execution
also retains its normal ephemeral capabilities. `routine_logs_root` can select a
source-owned log directory; no runtime credential is accepted in intent options.

No deployment has been selected, signed, enrolled, migrated or enabled by this
packet. PostgreSQL DDL follows the existing adapter contracts but the supplied
isolated journey targets SQLite.

### Persistent isolated one-shot configuration

The dev/prod runtime loader accepts these two explicit settings after its existing
dotenv loading:

```dotenv
ARBOR_OWNED_DIGEST_ENABLED=true
ARBOR_OWNED_DIGEST_ROOT=/absolute/operator-owned/dedicated-root
```

Prepare the dedicated root separately. It and every ancestor must already be
canonical, nonsymlink directories; the path is limited to 2–2,048 ASCII bytes
using the workdir alphabet above. These children must already exist:

- Directories: `pipelines`, `logs`, `reports/upstream-deps`,
  `reports/upstream-deps-summary`, `reports/morning-digest`.
- Regular nonsymlink files: `pipelines/morning_digest.dot` and
  `pipelines/morning_digest.caps.json`.

The bridge selects that DOT file as `morning_digest_pipeline`, the `logs` child
as `routine_logs_root`, and registers the `pipelines` child under the reserved
`pipeline_roots` key `laptop_digest_verification`. It adds only the URI-prefix
ceiling `arbor://fs/write` followed by the exact absolute
`reports/morning-digest` path with mode `:allow`. Existing root entries and ceiling
overrides remain intact; conflicting values for these exact reserved entries
refuse startup. Global write ceilings and bundled cron configuration are unchanged.
Use a separate copy of the graph and manifest: signing the bundled manifest in
place can make the existing bundled cron executable.

The v2 signed manifest must name the dedicated root as its workdir. The manifest
remains the workdir authority; there is no separate runtime workdir override.
Configuration checks filesystem shape only, without reading, signing or trusting
the manifest contents. The existing catalog, issuer, owner and effect gates still
apply. No files, grants, enrollment or jobs are created by this bridge. The
filesystem checks describe startup observations, not descriptor-bound protection
against later concurrent directory replacement.

Prepare a fresh, absent current-UTC-date output and enqueue one explicitly signed
job through the public protocol above. This setting introduces no cadence.
Preserve a committed job ID and inspect it after an ambiguous result; do not
blindly repeat a potentially completed write. A standing schedule and permission
to overwrite previously produced reports need separate review.

The Trust policy owner freezes ceilings for the BEAM lifetime, so activating or
removing this ceiling requires a managed BEAM restart. An unset flag or exact
`false` emits no settings and preserves programmatic configuration; it does not
cancel jobs, revoke grants or undo a ceiling supplied elsewhere. Tests ignore this
environment surface entirely, including malformed values loaded by dotenv. Invalid
opt-in values refuse configuration without echoing their contents.

## Qualification boundary

`owned_routine_security_regression_test.exs` uses a private SQLite database with
real migrations, real Oban manual drain, real signatures/capabilities/Trust and the
actual Engine/digest path. Its source-owned observer only pauses; every operation
still reaches the actual gate. SQL telemetry pauses actual query completion to
exercise concurrent insert conflicts and holder death/expiry during admission.
An injected engine reproduces the pinned Postgres Basic advisory-lock loser and
ambiguous insert return contracts against the real SQLite owner; it does not
claim a live PostgreSQL run. Cold Repo reconstruction proves durable queued
envelope reconstruction, not whole-BEAM restoration of Security authority.
Separate Actions and ActionsExecutor
public tests cover tool signing transport and private-turn denial. The preexisting
public digest boundary also has a malformed/missing token no-I/O regression.

Exact revision results belong in the roadmap qualification ledger. These tests
require no provider, external network, live deployment or live runtime calls.
