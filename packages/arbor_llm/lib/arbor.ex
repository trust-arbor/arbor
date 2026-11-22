defmodule Arbor do
  @moduledoc false

  # Boundary classifies only the modules compiled by this OTP application.
  # This common namespace groups the preserved historical helper names with LLM;
  # it defines no facade or ownership over modules from other applications.
  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [
      Arbor.Common.OAuth,
      Arbor.Common.PromptSanitizer,
      Arbor.Common.SensitivityClassifier,
      Arbor.Contracts,
      Arbor.Contracts.Security,
      Arbor.Contracts.Tool,
      Arbor.Eval.Subject,
      Arbor.Identifiers,
      Arbor.Signals,
      Finch,
      Jason,
      LLMDB,
      Logger,
      Mint.TransportError,
      Plug,
      Plug.Cowboy,
      Req,
      ReqLLM,
      TypedStruct
    ],
    exports: [{LLM, []}, {Contracts, []}, AI.LLMError, Orchestrator.ToolHooks]
end
