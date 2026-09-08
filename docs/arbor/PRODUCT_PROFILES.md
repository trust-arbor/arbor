# Product Profiles and Architecture

**Direction accepted:** 2026-09-07. This is a delivery and architecture decision,
not a claim that selectable release profiles or all security coverage already ship.

## Who Arbor Is For

| Audience | Experience | Priority |
|---|---|---|
| Single users | Several persistent agents, each with its own memories, relationships, goals, and ongoing work | First delivery target |
| Developers | Individual workers, orchestration, and the reviewed software factory | Retain existing capabilities; extend when needed for useful delivery |
| Enterprises | Both experiences plus organization-wide policy, separation of duties, retention, governance, and audit integration | Separate follow-up requirements, not prerequisites for personal use |

These are overlapping product needs, not trust levels. A personal installation does
not get weaker consent, authorization, isolation, or credential protection.
Single-user also does not mean single-agent. The initial deployment target is one
owner on one host, with multiple concurrent agents. Multi-host operation is a
separate deployment requirement, not an implicit property of that first profile.

## Near-Term Architecture

Build a **modular OTP application with a fixed trusted host, optional first-party
features, and sandboxed external plugins**. Keep the completed separation between
the passive `arbor_kernel` and active `arbor_kernel_runtime`. Do not make conversion
of every subsystem into a plugin a delivery goal.

- DOT programs are the default behavior-extension format. Use the existing Engine
  for composed workflows, direct gated actions for atomic contributions, and
  contained external providers only when new executable primitives are needed.
- Keep existing public facades, supervision, capability enforcement, and useful
  boundary checks. Extract only where a concrete user workflow or optional
  dependency needs it; retain a working adapter instead of generalizing prematurely.
- First-party features can be statically assembled with ordinary release/config
  selection. They do not all need independent signing identities, activation
  generations, hot swapping, or a generic invocation proxy.
- Keep the Engine in `arbor_orchestrator` for now. Its conceptual role as a pipeline
  kernel does not require physically moving it into Kernel Runtime. Durable,
  branchy programs use DOT; mechanical commits use a functional core and shell.
- Independently supplied executable plugins require a real OS-enforced boundary,
  authenticated host-mediated operations, and least authority. Existing ACP/MCP
  transport is not by itself a sandbox or proof that all invocation paths enforce
  authorization. Do not expose host-only bypass paths as plugin APIs.
- Packaging, optional startup, and isolation are separate properties. All code
  loaded into the host BEAM is trusted code, including optional first-party modules.
  Distributed Erlang membership is also broad trust, not hostile-code isolation.
  See the [OTP security model](https://www.erlang.org/docs/28/system/secure_coding.html).

A smaller core is useful when it reduces mandatory dependencies, memory/startup
cost, privileged code, and configuration burden. Fewer files or umbrella apps is
not itself success. Do not declare a minimal TCB merely because services moved to
another package.

### Behavior Extensions on the Existing Engine

A behavior package contains named DOT entry points, supporting skills/prompts/config,
input/output contracts, content hashes/provenance and requested permissions. It can
optionally bind to existing commands or schedules under their host owners. The first
candidate is a useful personal-agent routine, such as user-invoked goal review,
using existing actions before building external-provider infrastructure.

Reuse graph composition, authorization, checkpoints/recovery and diagnostics. The
missing package admission/versioning layer must bind approved bytes and transitive
subgraphs; today's mutable graph-name registry is discovery, not verified installation.
Use caller-bound execution and explicit context passing. Package metadata requests
scope but cannot grant it; graph approval nodes do not replace effect-level consent.

This avoids another execution framework and makes behavior inspectable and reusable.
It does not make arbitrary DOT safe, shrink installed dependencies by itself, or
turn checkpoints into transactions for external effects. Restrict admitted primitives,
pin active-run versions, and keep revocation, cleanup and emergency recovery owned
outside optional graph nodes. Tight loops, streaming and mechanical state updates
remain actions or supervised services. Host code still provides the enforcement;
the graph describes the work it permits.

## Personal Profile and Recovery

The intended normal personal profile includes authenticated user access, agent
lifecycle and scheduling, the Engine, durable local memory/goals/relationships,
scoped tools, a trusted skill catalog, model routing, consent, and bounded local
security diagnostics. Start with existing local persistence, not mandatory Postgres
or a new replaceable vector service. Cloud models are optional destinations subject
to policy, not implicit permission to export everything in an agent's context.

The software factory, fleet discovery, enterprise integrations, and unselected
Voice/device stacks must not be required merely to chat with and manage agents.
Measure what can actually be omitted before promising a lean release.

Recovery is a different profile from the normal agent experience. It must support
inspection, disabling a failed optional component, and restoring local operation
without an LLM or that component. Its exact deployment closure needs evidence for
the supported release, but proving the globally smallest closure is not a prerequisite
for every personal-agent feature.

## Security Floor

These are acceptance requirements. Coverage is partial and must be demonstrated
end to end; see [Security Architecture](SECURITY_ARCHITECTURE.md).

1. **Consent before sensitive disclosure.** Before sensitive data leaves Arbor's
   approved local boundary, the authenticated user must explicitly approve its
   recipient and purpose. Show enough information about the data to make the choice
   meaningful. Login, a configured provider, ordinary tool approval, earned autonomy,
   and a delegated worker's answer are not blanket disclosure consent.
2. **No hidden outbound path.** Cover prompts and recalled context, summaries,
   embeddings, council/fallback models, ACP workers, MCP tools, searches, Voice,
   telemetry, and exports. A local CLI can call a cloud service. A LAN/on-premises
   service can still be external to the approved boundary. Unknown sensitivity or
   destination cannot fail open; do not send unknown data to an external classifier
   to decide whether it may be sent.
3. **Bounded consent, not approval fatigue.** A deliberate user submission to a
   clearly disclosed route can authorize that interaction's disclosed data. It does
   not silently include unrelated memories or downstream destinations. Any standing
   consent must be an explicit, narrow, revocable user choice. Material data, purpose,
   or route changes need fresh consent. Autonomous work waits or uses an authorized
   local/redacted route when consent is unavailable. Hard policy prohibitions remain
   prohibitions; a model cannot grant itself an exception.
4. **Prompt-injection containment.** Documents, tool results, memory content, and
   imported skills are data, not authority. Preserve provenance/taint through recall,
   delegation, and recovery; enforce capabilities at effects, not in prompts alone.
   Hostile content remains blocked at enforced external egress. This is layered risk
   reduction, not a claim that arbitrary prompt injection can be perfectly detected.
5. **A trusted skill library.** Separate discovery, import, review, and activation.
   Bind approved content to an immutable version/digest and provenance; changes
   invalidate approval. A signature identifies provenance, not harmlessness. Skills
   cannot self-approve, enlarge grants, or become executable host code merely by
   appearing in an indexed directory. Reuse existing catalog/import/activation gates.
6. **Local security and recovery still count.** Per-agent state and capabilities,
   credentials, replay rejection, revocation, cancellation, and restart behavior need
   behavioral tests even on one host. Preserve the current multi-node signed-request
   fail-closed gate until a supported shared-authority design replaces it. Do not
   disable security synchronization simply to make a dependency disappear.
7. **Useful, private evidence.** Keep attributable approval, denial, revocation, and
   recovery receipts with bounded/redacted data. Enterprise retention, fleet audit,
   and compliance integrations can wait; local accountability cannot. Diagnostics
   must not become another sensitive-data export path.

## Evidence Proportional to the Claim

| Claim | Required evidence |
|---|---|
| A personal-agent change works safely | User-path regression, relevant owner/consumer tests, and security negative cases |
| A broad dependency or release change integrates | Owner-admitted CrossApp or equivalent reviewed integration plan against an immutable tree |
| Factory restart/resume works | Deterministic multi-window and crash-boundary qualification, separate from the product feature |
| Several nodes share security authority safely | Multi-node failure/replay/revocation evidence for an explicit consistency contract |

Do not weaken an already admitted validation plan to obtain a pass. Exact inventory,
tree/toolchain/baseline binding, owner-observed results, and no partial-prefix
acceptance remain intact. A lighter lane requires a reviewed owner-controlled policy;
the worker never chooses which tests count. CrossApp integration tests are not a
proof of distributed authority correctness, and an executable protocol model is not
a proof that a future runtime implements it.

## Delivery Order

1. Inventory one real personal-agent journey and its privacy/security paths; reuse
   existing canaries and identify missing coverage before inventing infrastructure.
2. Close concrete consent, skill-trust, agent-isolation, and continuity gaps. Make
   only the Platform/Interface/Cognition boundary changes those packets need.
3. Qualify the selected personal profile, restart/recovery, and resource footprint.
4. Expand external plugins, factory qualification, and shared authority under their
   own milestones when an actual use case justifies them.

The private roadmap's controlling decision is
`2026-09-07-single-user-first-modular-arbor`; the first work item is
`single-user-agent-experience-and-security`. This public document is self-contained
for installations that do not have the separate `.arbor` planning repository.
