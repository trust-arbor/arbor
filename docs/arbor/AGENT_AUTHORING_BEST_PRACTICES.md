# Authoring an Agent — Capabilities & Trust, Secure by Default

**Created:** 2026-07-06. Companion to `AGENT_TEMPLATE_REFERENCE.md` (field
format) and the two 2026-07-06 kernel reviews (capability-kernel,
capability-policy-model). This is the *how to think about it* doc: what to
put in a manifest, why, and how the system keeps it safe without making
authoring miserable.

## The two axes, stated for authors

Every agent needs two independent things to act, and you author both:

1. **Capabilities — what it may touch.** An allowlist of resource URIs.
   Deny by default: if it isn't granted, the agent cannot do it. This is
   the security primitive; it is unforgeable and enumerable.
2. **Trust profile — how it touches them.** Per-URI *modes*
   (block/ask/allow/auto) plus a baseline. This decides confirmation, not
   permission. Earned autonomy lives here (a mode graduating ask→auto).

**The load-bearing rule (from the capability-policy review):** the profile
*modulates* capabilities; it must not *replace* them. A profile mode only
matters for a URI the agent already holds a capability for. Authoring both
explicitly is what keeps that true — and what makes the manifest the single
place a reviewer reads to know what the agent can do.

## The five best practices

### 1. Author BOTH in the template, together
Capabilities and profile modes belong in the same manifest, reviewed as one
artifact. A capability grant with no mode, or a mode with no grant, is a
bug the validator should catch. (Today the template carries only
`required_capabilities`; the profile is chosen from a preset at creation —
see "The template gap" below. Until that's fixed, author the intended modes
in a comment beside each capability so the reviewer sees both.)

### 2. Least privilege, per capability, with a reason
Each capability is the narrowest URI that works, and carries a one-line
*why*. `arbor://shell/exec/git` not `arbor://shell`. `arbor://fs/read/docs`
not `arbor://fs/read`. The reason is not decoration — it's what the security
reviewer (human or the Security Auditor agent) checks the grant against.

### 3. Baseline is `:block` or `:ask` — never `:auto`
This is the polarity rule from the capability-policy review, stated for
authors: an `:auto` *baseline* means "anything not explicitly forbidden is
silently allowed" — it inverts deny-by-default into a denylist, and the
whole agent's safety then rests on the system ceiling list being complete.
Don't. Baseline `:block` (deny unmatched) or `:ask` (confirm unmatched).
`:auto` is a per-URI *rule* the agent *earns*, never a starting posture.

### 4. Dangerous domains stay `:ask` regardless of what you write
Shell, governance, network egress, filesystem write, code hot-load have
system ceilings that cap their mode at `:ask` no matter what the profile
says. Don't fight the ceiling; if your agent legitimately needs unattended
shell, that's a design conversation (a scoped sub-URI, a sandbox), not a
profile override. The ceiling winning is a feature.

### 5. Declare the manifest as a *request*, granted at creation
`required_capabilities` is what the agent *asks for*. Instantiation renders
it as an approval screen (or auto-approves within the owner's own policy).
The declaration/authorization split stays explicit: authoring a capability
into a template never grants it; a human or a policy does, at create time.

## Secure-by-default WITHOUT painful UX

The tension is real: least-privilege authoring is tedious, and tedium makes
people reach for "just give it everything." Arbor's answer is to make the
*secure* path the *easy* path, five ways:

- **Capability presets as bundles, not blank checks.** Ship named starting
  points — `read-only-researcher`, `repo-contributor` (read + worktree
  write + git/mix under ask), `conversationalist` (chat + memory only). Each
  preset is an *explicit, enumerable* capability set + matching modes, not
  an `:auto` baseline. The user picks a bundle and narrows; they never start
  from "allow everything." (This is the capability-policy review's P3 north
  star as a UX feature.)
- **The minimal-set suggester.** Describe the task in plain language; the
  system proposes the least-privilege capability set (the capability→sandbox
  compiler run in reverse). The user reviews a *proposal*, not a blank form.
  Secure-by-default becomes suggested-by-default.
- **Audition before grant.** Instantiate the draft agent with an *empty*
  capability set in a simulate/shadow session; watch which capabilities it
  *tries* to use; grant a manifest informed by observed behavior. The denial
  log is the authoring worksheet. "Audition, then grant" turns
  least-privilege from guesswork into observation.
- **The interview agent does this conversationally.** For non-authors, the
  Trust Interview Agent walks the capability decisions as scenario
  questions ("if it needs to run git, should it ask first or just do it?")
  and emits the manifest + modes. The secure default is reached by
  conversation, not by reading a URI grammar.
- **Legible warnings, not silent acceptance.** The dangerous-combination
  check fires at author time: `shell` + `net/egress` + `fs/write` is the
  exfiltration triangle — say so, with the reason, and make the user
  confirm intent. Framed as protection ("this combination could send your
  files somewhere"), not scolding.

## Policy-first authoring vs. capability-first (the resolution)

A natural question: since the profile can already grant reach, why not make
the template **policy-first** — author only a trust profile, derive the
capabilities? For simple agents this is genuinely better UX (one artifact,
no mode-without-grant mismatch possible). The answer is **policy-first
*authoring*, capability-first *enforcement*, with a compile step between** —
and the security rule from practice #3 is what makes it sound.

**Why not pure policy-first (what a mode can't express that a token can):**
a capability is a *richer type* than a trust mode. Four things collapse if
the profile is the only artifact:

1. **Constraints** — rate limits, max_uses, expiry, session/task scope live
   on a capability, not a mode. "Spend $10 then stop," "valid until Friday,"
   "10 uses then re-ask" have no policy-mode expression. (The allowance doc
   needs budgets-as-cap-constraints — pure policy-first can't carry them.)
2. **Delegation** — `SpawnWorker` intersects capabilities (parent ∩
   requested). Profiles don't intersect across a boundary; the worker /
   marketplace / subagent story needs tokens you pass and narrow.
3. **Federation** — a capability is a signed, self-contained token that
   verifies on another node and is revocable. A profile is a node-local
   resolution table; it doesn't travel as an artifact.
4. **Provenance** — a capability carries issuer + signature + delegation
   chain. A profile rule carries "the template said so." Once agents
   propose capabilities for each other, that chain is load-bearing.

**The compile step (best of both):** the template's authoring surface is
policy-first — a `:block`-baseline profile with allow/ask rules, nothing
else. Instantiation **desugars** each allow/ask rule into a real, signed,
enumerable capability token with default constraints. You author one
artifact; you get rich tokens. Simple agents never touch the capability
layer; when you need a rate limit, expiry, or delegation, you drop to the
explicit capability form and add it. Profile = source; capabilities =
compiled output; they cannot diverge because one generates the other.

**Why the security rule is the enabler, not a tax:** a `:block` baseline
compiles to a **finite** capability set (unmatched = deny, so the allow/ask
rules are exhaustive and enumerable). An `:auto` baseline **cannot** — it is
infinite reach, no finite token list exists. So "no `:auto` baseline"
(practice #3) isn't only a safety rule; it is the **precondition that makes
policy-first authoring sound**. The constraint that keeps the system secure
is the same constraint that enables the simpler UX. One rule, pointing both
ways. (Corollary: presets ship as block-baseline profiles; the compiler
turns them into explicit capability bundles — the P3 "north star" from the
capability-policy review, delivered as the *default authoring surface*.)

## The template gap (fix to make #1 real)

Today `Arbor.Agent.Template.File` validates `required_capabilities` but has
**no trust-profile field** — the profile is applied from a preset at
`Lifecycle.create`, separate from the template. Consequence: the two axes
are authored and reviewed in two places, which is how a permissive baseline
can pair with a tight capability set unnoticed. Recommendation:

- Add an optional `trust_profile` block to the template format: `baseline`
  (validated ∈ `{block, ask}` — reject `:auto` per practice #3) and `rules`
  (URI → mode). Absent → the chosen preset applies (back-compat).
- `Template.File.validate/1` gains: baseline not `:auto`; every `rules` URI
  is also in `required_capabilities` (no mode without a grant — practice
  #1 mechanically enforced); every capability the manifest expects to use
  unattended has an explicit `:auto` rule OR inherits ask (no silent auto).
- The reviewer/approval screen renders capabilities and modes as one table:
  URI · granted? · mode · why. One artifact, both axes, one review.

## The worked example (the shape to copy)

A repo-contributor agent, authored correctly:

```yaml
# baseline denies the unmatched; every grant is narrow and reasoned;
# dangerous domains sit at ask; nothing starts at auto.
trust_profile:
  baseline: block                      # deny by default (practice #3)
  rules:
    "arbor://fs/read/repo": allow       # read freely, notify
    "arbor://fs/write/worktree": ask    # writes are reviewed
    "arbor://shell/exec/git": ask       # ceiling would force ask anyway
    "arbor://shell/exec/mix": ask
required_capabilities:                  # the allowlist — every rule URI appears here
  - resource: "arbor://orchestrator/execute"
    description: "Run its turn/heartbeat pipelines"
  - resource: "arbor://fs/read/repo"
    description: "Read the codebase it works on"
  - resource: "arbor://fs/write/worktree"
    description: "Write generated changes to an isolated worktree only"
  - resource: "arbor://shell/exec/git"
    description: "Branch/diff/commit for the reviewable change"
  - resource: "arbor://shell/exec/mix"
    description: "Compile and test its own output before proposing"
```

Every mode has a matching grant; nothing is `:auto`; the dangerous domains
sit at `:ask`; the writes are worktree-scoped. This agent can do real work
and a reviewer can see its entire reach in one screen. Earned autonomy later
flips specific `:ask` rules to `:auto` — *for capabilities it already holds*,
with a human accepting the graduation. It never gains new reach by default.

## Day 2 — updating ONE live agent (not the template)

After birth, **the template is a seed, not the source of truth.** A live
agent's authority is its runtime state — capabilities in `CapabilityStore`
+ profile in `Trust.Store`, keyed per-agent, mutable independently of the
template. Editing the template affects only *future* instantiations;
existing agents never re-read it. So "update one agent, not the template"
is the normal path, and the runtime stores exist for exactly it.

**Granting is one policy-first operation:** add an allow/ask rule to *this
agent's* profile → the compile step mints the matching capability
(`Security.grant/1`) for this agent. Source side + token side, one change,
one review. Updating is policy-first for the same reason authoring is.

**Three grant paths, by initiator and by what changes:**

1. **Direct grant (human/owner)** — you add the rule; a token is minted.
   *Adds reach* (a URI the agent never had) → high-stakes, full provenance.
2. **Earned graduation** (`Trust.accept_graduation/2`) — an approval streak
   proposes `:ask`→`:auto` on a **held** capability; a human accepts.
   *Raises mode, not reach* — lower stakes; this is earned autonomy working.
3. **JIT request** — the agent hits a wall, emits a capability *request*
   that routes to the human (`:ask` made concrete: allow-once / session /
   always / deny). **Agent proposes; human disposes. Never self-grant** —
   an agent expanding its own reach alone is the bootstrap-safety /
   two-sources rule violated.

**Two invariants (both are why capabilities stay tokens, not just modes):**

- **Provenance per grant** (`source: :template | :granted | :earned |
  :policy`). An audit distinguishes "has `fs/write` because individually
  granted on DATE by WHO" from "because the template declares it." This is
  the who-granted-this-and-why chain pure policy-first would lose.
- **Template drift is expected.** An individual grant doesn't touch the
  template, so re-instantiating makes a sibling without it — correct, the
  grant was to the *individual*. Therefore: (a) `read_self` /
  introspection reports **runtime-held** caps, never template-declared
  ones; (b) if an individual grant proves broadly useful, a
  **promote-to-template** path lifts it to the class default — the commons
  pattern (individual → reviewed → shared), same shape as skill promotion.

**Revocation is the symmetric inverse, per-agent, instant:**
`Security.revoke/1` kills the token; a `:block` rule added to the one
agent's profile subtracts authority immediately (safe direction —
most-restrictive wins) even before the token expires, touching neither the
template nor any sibling. Short-TTL renewal propagates it cleanly if the
agent is federated.

## The one-sentence version

Author capabilities as a narrow, reasoned allowlist; author modes as
block/ask (never auto baseline); let presets, the minimal-set suggester, and
audition make that the easy path; and enforce at the validator that no mode
exists without a grant and no baseline is `:auto` — so the secure default is
the default, and the reviewer reads one table to know everything the agent
can do.
