defmodule Arbor.LLM do
  @moduledoc """
  Arbor's LLM client layer — orchestration semantics on top of req_llm
  transport.

  Currently a skeleton holding the spec-conformant data types
  (`Arbor.LLM.Request`, `Arbor.LLM.Response`, `Arbor.LLM.Message`,
  `Arbor.LLM.ContentPart`, `Arbor.LLM.StreamEvent`, `Arbor.LLM.Tool`,
  `Arbor.LLM.ToolCallValidator`) and the seven typed error structs.
  These are the stable surface the rest of Arbor codes against.

  The behavioural core — `Client`, `ToolLoop`, `ArborActionsExecutor`,
  `Preflight`, `Retry`, `ProviderCatalog` — and the generic req_llm
  adapter land in subsequent sessions. Until then, the legacy
  `Arbor.Orchestrator.UnifiedLLM.*` modules in `arbor_orchestrator`
  continue to serve those concerns.

  See `.arbor/roadmap/1-brainstorming/model-and-runtime-policy.md` for
  the full extract plan.
  """
end
