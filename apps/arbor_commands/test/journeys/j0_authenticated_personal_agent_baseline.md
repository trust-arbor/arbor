# J0 authenticated personal-agent journey — measurement baseline

Exact owner commands (this worker did not execute them):

```bash
./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_baseline_helpers_test.exs

./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_personal_agent_baseline_test.exs --include database --include sqlite --include integration
```

Run from the umbrella root with `./bin/mix`. Do not boot this topology from
`apps/arbor_commands/test/test_helper.exs`. Support lives under
`apps/arbor_commands/test/support/j0_authenticated_baseline*`; production
code is untouched. Helper regressions are fixture-only and must fail against
the original 4dd1fc4d helper code; they are not product-success claims.

## Independently asserted boundaries

| Boundary | How it is asserted |
|---|---|
| Auth | `Arbor.Agent.send_message/4` with a real OIDC human, `SessionToken`, and `DeliveryReceipt` consumption on the Session authenticated path. Proof subject (`conversant`) is distinct from the canonical owner used at `Lifecycle.create/2`. |
| Reply | Public `{:ok, binary}` from `send_message/4` equals the capture-adapter canned reply, not a fabricated Session result. |
| Provider request | `CaptureAdapter.complete/2` forwards the actual `Arbor.LLM.Request` to the test process. |
| Persistence pair | Immediate `assert_committed_pair_now!/4` after the first authenticated preference turn: exactly the expected user and assistant content, consecutive ordinals, and no third row in the fresh engagement (one `load_recent_session_messages/2`, no poll). Missing, malformed, or stale evidence fails. The sqlite poll test remains extra inventory. Control agent also receives a benign turn; its committed pair must exist and must not contain the preference marker. |
| Index | After the preference turn, `Arbor.Memory.recall/2` is queried without calling `Memory.index/2`. Expected: `{:ok, results}` with no marker, or the specific `{:error, :index_not_initialized}`. Any other error fails. |
| Dispatched recall | Erlang call/return (and exception) trace on the public facade `Arbor.Memory.recall/2,3` only. Production `session_memory.recall` reaches that MFA via `apply/3`; a `SessionMemory.bridge/4` fallback that never calls the facade, and internal `IndexOps.recall`, are not accepted evidence. Process coverage is `Arbor.Orchestrator.Session.TaskSupervisor` (the `start_child` owner in `Arbor.Orchestrator.Session.do_send_message_async/5`) installed **before** any turn, not parent+Session `set_on_spawn` alone. Matched on the exact follow-up query. Every facade observation is retained: nested arities may emit multiple events, and repeated queries may return different results. An empty drain after that coverage is a missing observation, not a claim that recall was absent. Independent of the LLM transcript and of SQLite rows. |
| Untouched control | Second conversationalist never receives the preference; its captured provider request must not contain the marker. |
| Outbound denial | Closed `Client` adapters for every known provider except `ollama`, plus middleware; unexpected `openai` `Client.complete/2` returns `{:error, :outbound_denied}`. Every case drains TraceHub and fails if `Arbor.LLM.Adapter.ReqLLM` or ACP `complete` is invoked. |

## Working guarantees

Successful turns acknowledge the pair before the public reply.
`Session.Persistence.persist_turn_entries/5` awaits the atomic user/assistant
append. The journey asserts the exact pair immediately after the fresh
engagement's first `{:ok, reply}` via `assert_committed_pair_now!/4` in
`j0_authenticated_baseline.ex` (no poll, no sleep). The sqlite poll test remains
extra inventory, not an async success loophole.

## Production-path gaps recorded (not repaired)

These are executable observations, not suppressed failures.

1. **Indexing is not on the authenticated Session path.** Production `turn.dot`
   `update_memory` reads `session.turn_data`. No node in that graph writes
   `session.turn_data`. Owner evidence on 4dd1fc4d also logged Session
   `update_memory` context key `session.turn_data` missing — that is product
   wiring, not a fixture authorization to change production. `Arbor.Actions.SessionMemory.Update`
   therefore indexes nothing. `Arbor.Agent.AgentSeed.finalize_query/3` (and
   APIAgent) is the path that currently calls `Arbor.Memory.index/3`;
   `Manager.chat_authenticated/4` never enters that function. The index test
   records absence of the preference rather than seeding `Memory.index/2`.
2. **Follow-up recall is therefore empty.** The recall node is
   `session_memory.recall`, which `apply`s `Arbor.Memory.recall/2` through
   `SessionMemory.bridge/4` with `session.query` equal to the follow-up text
   on the `Task.Supervisor.start_child` turn owner
   (`Arbor.Orchestrator.Session.do_send_message_async/5`).
   Observation is the public facade MFA, not the bridge wrapper or IndexOps.
   An empty trace drain after TaskSupervisor coverage is a missing
   observation, not a claim that the node did not run. The preference marker
   is not expected in the result until the Session path actually indexes.
   Only a result list or the specific `:index_not_initialized` outcome is
   admitted; other returned errors and traced exceptions fail the baseline.
   Same-session provider history is not treated as recall evidence.
3. **`LLM.Client` fake-adapter fallthrough.** `resolve_known_cloud_adapter/2`
   returns `Arbor.LLM.Adapter.ReqLLM` for unknown-to-the-client but
   registry-known cloud providers. This packet closes that route in the test
   environment (per-provider `ClosedAdapter` map + deny middleware + trace)
   and includes an explicit `openai` negative case. Production is unchanged.

## Teardown

Suite and per-case cleanup state lives in *unlinked* Agent owners, and the
TraceHub tracer is unlinked, because ExUnit 1.19.5 test processes exit
`:shutdown` before `on_exit` (and `start_supervised` children die at the same
point). The bag is started and the single suite `on_exit` is registered
*before* security env mutation, OTP starts, grants, sessions, or tracing.
`setup_all` must not register a second `stop_suite!/1`. Partial bootstrap
failures still restore env, default LLM client, Repo config, `ARBOR_HOME`,
and only children this file started; `stop_suite!/1` uses nested `try/after`
so one cleanup failure cannot skip global restoration. Every case drains
TraceHub through `:erlang.trace_delivered/1` before uninstall and fails if
ReqLLM/ACP `complete` was traced. The registered name `Arbor.Orchestrator.Session.TaskSupervisor` is started
when missing as `{Task.Supervisor, name: Arbor.Orchestrator.Session.TaskSupervisor}`
(not as if that atom were a start_link module) and only that owned child is
stopped. A stopped preexisting child spec fails setup explicitly rather than
being restarted without cleanup ownership. It is traced before any turn so `Task.Supervisor.start_child` workers
are observed rather than only the `Task.start` fallback. A created tracer or
cleanup owner that is dead/unreadable fails closed after remaining cleanup;
never-created optional hubs are not treated as empty-success drains. OTP
applications started via `ensure_all_started/1` are left running: stopping
them would race later files in the same arbor_commands
BEAM. Security's canonical test tree is restored through
`TestBootstrap.restore_supervised_tree!/0` when that supervisor exists.

Remaining fixture/product limits: indexing and follow-up recall on the
authenticated Session path are still measurements, not success claims;
successful turns acknowledge the SQLite pair before the public reply
(immediate assertion) while the poll test remains extra inventory; production
`LLM.Client` fake-adapter fallthrough is unchanged outside this harness. Do
not treat this note as evidence that the helper or journey commands were run.

## Constraints honored

- Temporary `ARBOR_HOME` and SQLite database; `async: false`; process-global
  Application env / LLM client / traces restored.
- No mock `turn.dot`, no auth bypass, no fabricated identities, no ignored
  Engine errors, no `Memory.index` seed.
- Authentication is the public `Arbor.Agent.send_message/4` facade.
