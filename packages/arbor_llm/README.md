# Arbor LLM

Bounded model clients, streaming, OAuth acquisition, tool loops and composable
call plugs, adopted from Arbor Main into an independent OTP package.

```elixir
{:arbor_llm, "~> 0.1.0"}
```

The public facade remains `Arbor.LLM`. Existing `Arbor.LLM.*` data, error and
protocol module identities are preserved. The pure historical
`Arbor.AI.LLMError` and `Arbor.Orchestrator.ToolHooks` modules also belong to
this package; consumers continue using those names through their LLM dependency.

The canonical `:arbor_llm` application remains active. Its normal callback owns
`Arbor.LLM.Supervisor`, the OAuth pending and recovery-proof stores, and the
isolated loopback-listener supervisor. Package loading does not acquire an Arbor
Kernel Runtime, AI, Orchestrator, capability authority or product supervisor.

The first-party dependency closure is passive Kernel, Support and OAuth, plus
Signals as a code-only dependency for existing taint helpers. Signals is not
started by this package. ReqLLM, LLMDB and the HTTP libraries are public package
dependencies. Existing streaming, request deadlines, response budgets,
cancellation and typed failure behavior are retained.

## Host composition

The host explicitly selects sensitivity policy and classification, invocation
auditing, tool execution, dispatch, provider extensions and product observation.
Required admission failures remain closed; missing configuration is not evidence
of permission. In particular, a standalone consumer must provide its own trusted
egress policy before an actual model transport can run. Product wiring belongs
to Arbor's host and the existing AI/Orchestrator owners, which depend on this
package rather than becoming package dependencies.

OAuth acquisition uses the existing public OAuth package. Callers own its HTTP
pool lifetime. Credential storage and OpenCode disclosure acknowledgements have
explicit `:arbor_llm` path settings; qualification consumers must use private
paths without changing the user's home directory. No credentials are required
to load the package or run its isolated local protocol fixtures.

The packaged `priv/opencode_zen/admission.json` is the existing recorded model
admission evidence. The provider's disclosure acknowledgement and the actual
transport admission checks remain required; moving the evidence grants no
additional endpoint or model authority.

## Building and qualification

Default dependencies use public version requirements. Build-only local source
overrides are `ARBOR_KERNEL_PATH`, `ARBOR_SUPPORT_PATH`, `ARBOR_OAUTH_PATH` and
`ARBOR_SIGNALS_PATH`. They do not propagate the parent's Mix environment or add
runtime source loaders. Arbor's composition supplies its own path overrides.

The package enables strict alias-aware Boundary compilation. Owning tests and
security regression tests remain alongside the implementation. Adoption and cold
consumer receipts record the exact source, test and runtime qualifications for
a reviewed revision; this README does not substitute for those receipts.

The published payload contains `lib`, `priv`, `mix.exs`, this README and the MIT
license. Tests, configuration, qualification fixtures and source-map evidence
are excluded. Publication requires a separate explicit decision.
