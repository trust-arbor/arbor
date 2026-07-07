# TRUST-1.0 — Trust Resolution & Graduation Specification

**Status:** Draft (2026-06-10)
**Scope:** `Arbor.Trust` — effective-mode resolution, security ceilings, graduation
(confirm-then-automate), freezing, and profile persistence safety.
**Conformance:** every statement below is proven by tests tagged `@tag spec: "<ID>"`.
Run `mix arbor.spec.coverage` for the current proof map. Statements marked `(planned)`
describe committed direction not yet implemented; they are excluded from `--strict`.

The key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as described in
RFC 2119.

## Resolution

- **TRUST-1** (MUST): The effective mode for an agent and resource URI MUST be the most
  restrictive of: the user's profile rule (or baseline), the system security ceiling,
  and any model-class constraint. Ordering: `block > ask > allow > auto`.
- **TRUST-2** (MUST): Security ceilings MUST NOT be overridable by user preferences.
  In particular, filesystem/code writes and shell/governance operations MUST resolve to
  at least `:ask` even for the most permissive profiles.
- **TRUST-3** (MUST): When no trust profile exists for a principal (or the trust system
  is unavailable), authorization MUST fail closed: effective mode `:ask` /
  confirmation `:gated`, never `:auto`.
- **TRUST-4** (MUST): Unknown, malformed, or missing mode values MUST normalize to
  `:ask` (fail-safe), never to a more permissive mode.
- **TRUST-5** (MUST): Profile rule resolution MUST use longest-prefix matching; a URI
  matching no rule MUST resolve to the profile's baseline mode.

## Graduation (confirm-then-automate)

- **TRUST-6** (MUST, planned): Reaching a graduation threshold MUST produce a *suggestion* only;
  the system MUST NOT auto-promote a capability to `:auto` without explicit user
  acceptance.
  > ⚠️ **Spec/code conflict found during spec extraction (2026-06-10):** the
  > ConfirmationTracker moduledoc and ask-mode roadmap both state suggestion-only, but
  > `confirmation_tracker_test.exs` ("suggests graduation after reaching threshold")
  > asserts `graduated?/2` is **true immediately after the third approval** — the code
  > auto-promotes and emits a "suggestion" signal after the fact. Intentionally left
  > unproven until Hysun decides: fix the code to match this statement, or rewrite the
  > statement to match the code (and update the moduledoc + council-decision docs).
- **TRUST-7** (MUST): A rejection MUST reset the approval streak for that prefix to
  zero, and MUST revert an existing graduation for that prefix.
- **TRUST-8** (MUST): `arbor://shell` and `arbor://governance` prefixes (including their
  canonical action-URI forms) MUST NOT be graduatable to `:auto`, regardless of approval
  count.
- **TRUST-9** (MUST): Resetting an agent's confirmation history (e.g., on trust
  demotion) MUST clear all streaks and graduations for that agent, and MUST NOT affect
  other agents.

## Profile integrity

- **TRUST-10** (MUST): Profiles restored from persistence MUST coerce string-form modes
  and tiers to validated atoms; a string-form mode MUST NOT bypass ceiling comparison.
  *(Regression: 2026-04-07 — a string baseline slipped past `most_restrictive/1`.)*
- **TRUST-11** (MUST): A frozen profile MUST block trust-gated authorization
  (`:trust_frozen`) until explicitly unfrozen.
- **TRUST-12** (MUST): Changing a profile's tier label MUST NOT modify its baseline or
  rules. User customizations are sacrosanct across tier transitions.
  *(Regression: graduation previously overwrote user rules — see
  trust-tiers-mental-model-review.)*
- **TRUST-13** (MUST): Trust gating MUST apply to the canonical authorization
  URI for each operation: action-backed operations use
  `arbor://action/<category>/<name>`, while facade resource operations use their
  resource namespaces such as `arbor://fs/read` and
  `arbor://shell/exec/<command>`. The retired
  `arbor://actions/execute/<name>` namespace MUST NOT be used for new grants.
  *(Regression: 2026-04-07 — `shell.execute` auto-ran because ceilings matched only one
  namespace shape.)*

## Planned

- **TRUST-14** (MUST, planned): Graduated state MUST survive process restart (durable
  persistence). Until implemented, restart resets all graduation — conservative but
  breaks the earned-autonomy promise. *(See ask-mode phase 5 prerequisite, 2026-06-10.)*
- **TRUST-15** (MUST, planned): For operations whose effect class is egress, process
  spawn, financial, or identity-mutating, an effective mode of `:auto`/`:allow` MUST
  degrade to at least `:ask` when the operation's inputs carry `untrusted` or `hostile`
  taint. *(The taint conjunct — capability-risk-profiles + taint-tracking-rebuild.)*
