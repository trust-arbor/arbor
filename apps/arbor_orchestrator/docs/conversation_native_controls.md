# Conversation execution controls

2026-10-03

The Session opens a private conversation source from its winning command claim
before starting the Engine. Failed source admission refuses the entire bound
turn. An ordinary turn without a command binding keeps its existing behavior.

The source is a process-local option containing the owning Session PID, the
current turn generation and an opaque Authority handle. It is never derived
from graph attributes, user metadata or Engine context. Subgraphs preserve this
option and the original task identity. The reviewed native actions that launch
child Engines receive it in their existing private child-options carrier.

For an `exec` node with `target="action"`, the mandatory middleware admits this
path only when the actual resolved handler is the built-in ExecHandler and the
actual executor is the fixed ActionsExecutor. The handler identity comes from
the execution call, never from graph data, an option or a second registry lookup;
any execution-manifest binding is also verified. This remains strict for runs
without a manifest. The middleware checks current scoped capability membership
for the derived action resource. It does not consume that capability or create an
approval. The fixed Actions facade performs the full proof, identity, reflex,
constraints, trust, egress and audit authorization before executing the exact
action. The handler gate and any other declared capability requirements retain
their ordinary checks. An overridden executor or handler cannot select this
deferral. This avoids a second approval created by middleware before the actual
action producer can own its invocation.

Native approval source control travels through ExecHandler, ActionsExecutor,
the Actions authorization boundary and the configured Security escalation
router. Actions removes the handle from ordinary action-visible context and
keeps it only for its synchronous call stack; nested synchronous facade calls
inherit the same source, and all exit paths restore the previous stack owner.
Only the three reviewed child-Engine launch actions receive the private nested
options carrier. Arbitrary action-spawned workers do not inherit process state.

ToolLoop forwards source control only to its native executor. Direct streaming
and nonstreaming LLM calls, and ToolLoop provider calls, remove the option before
Dispatch or Client reaches a provider adapter. It does not appear in the prompt,
request arguments, persisted checkpoints or public conversation projections.

The Session checks the exact generation and handle when the router requests an
approval. Authority derives the conversation attachment from the live source,
checks the producer's original agent and task, and refuses raw answers for the
attached request. A current general human session and the original scoped
approval-answer capability remain required; terminal conversation leases grant
chat access only. Cancellation or source retirement abandons pending requests.

These controls are opt-in with the bound conversation command path. They do not
change the production dashboard routes or terminal dependency pins. Source
presence is not authority: every operation still requires its existing grants.
