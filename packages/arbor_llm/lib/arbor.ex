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
      ReqLLM
    ],
    exports: [{LLM, []}, AI.LLMError, Orchestrator.ToolHooks]
end
