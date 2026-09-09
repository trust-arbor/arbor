# Private-turn memory writes

SU-3/M1b1 contains writes from receipt-authenticated private Session turns while
human-scoped Memory storage and retrieval are being qualified. It does not
enable automatic conversation indexing or establish owner-positive recall.

## Source boundary

Session derives the restrictive runtime option `memory_write_policy: :deny`
from its admitted turn authority. Model arguments, DOT context and stored
metadata cannot relax that option. Engine execution passes it through both
`exec` actions and the compute tool loop, and inherited restrictions must survive
nested execution. It is execution control, not a provider option or ownership
credential.

Session turns already run with `resumable: false`; both child-graph routes
inherit that setting. This packet does not qualify durable resume for a
hand-constructed restricted Engine run. Such a route would need to preserve
the restriction in authenticated recovery state before being supported.

Actions checks the resolved action module before authorization side effects or
business execution. A private turn cannot bypass this check by inventing a tool
name, requesting an unadvertised tool, changing a memory's type to `fact`, or
putting a permissive policy in action parameters. Invalid non-nil policy values
also fail closed.

The denied operations include semantic/KG writes, connections and reflection,
identity and cognitive changes, mixed review-and-approval operations,
relationship writes, and code-pattern writes. Pipeline actions that write the
same stores are subject to the same restriction. Pure reads retain their
existing behavior. The production Session memory-update step may complete as an
explicit no-op when it has no notes; it must not report a successful write or
call the Memory writer in that case.

Fresh worker, pipeline-tool, council and ACP start/send launches are refused
because those action paths do not carry the restriction to their child runtime.
Native LLM runtimes are similarly refused, including a fallback to one. The
legacy `acp` provider is also refused when labelled with runtime `arbor`, whether
chosen explicitly or through the client default. The local Arbor runtime and the
Engine's child-graph handlers carry the restriction.

## Limits

This is an additive restriction on the supported private-turn action path.
Unscoped tools and host paths retain their existing behavior. M1a still excludes
recognized conversation records from semantic reads; other historical memory
types are not thereby authenticated as safe to share. Goals, working memory,
relationships, history and other prompt sources need their own ownership work.

The restriction does not isolate arbitrary code running inside the BEAM, nor
does it constitute a policy for every file, network destination or external
agent. A caller-controlled callback, capability ID or principal label would not
be sufficient evidence for a future public scoped Memory API.

## Next ownership slice

Positive scoped reads require two independent proofs:

1. A current, opaque admission derived from the authenticated chat receipt and
   the Session's verified private engagement. It must bind the agent, human,
   engagement and live turn, expire on owner death or turn completion, and stay
   outside JSON context and provider/tool arguments. Ordinary capability
   authorization remains necessary; an observable capability ID is not a bearer
   credential.
2. A durable SystemAuthority attestation binding that admitted origin to the
   exact record identity, canonical body and vector descriptor. Existing taint
   digests establish integrity, not human ownership. An agent-key signature
   cannot substitute for system admission because the agent holds that key.

A cold read verifies historical record authenticity and then checks current
read authority. Expiry of the original writing turn must not destroy historical
proof; a valid historical stamp must not grant a future reader permission.
Unsealed or forged records remain unavailable in the private scoped lane.

M1b1 deliberately grants no exception to its write restriction. Replace a
denial with a scoped operation only when owner-positive, cross-owner-negative,
forgery, stale-turn and cold-storage behavior is covered through public APIs.
