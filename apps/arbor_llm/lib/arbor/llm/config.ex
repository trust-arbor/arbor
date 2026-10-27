defmodule Arbor.LLM.Config do
  @moduledoc "Host-owned runtime collaborators for the LLM boundary."
  @default_auditor if(Mix.env() == :test,
                     do: :disabled,
                     else: Module.concat(["Arbor", "Security"])
                   )

  @doc "Runtime-only upward seam: with_invocation_audit/2 wraps a tool dispatch. Unavailable required auditors fail closed."
  def tool_invocation_auditor,
    do: Application.get_env(:arbor_llm, :tool_invocation_auditor, @default_auditor)

  def sensitivity_policy,
    do: Application.get_env(:arbor_llm, :sensitivity_policy, Module.concat(["Arbor", "AI"]))

  def sensitivity_classifier,
    do:
      Application.get_env(:arbor_llm, :sensitivity_classifier, Arbor.Common.SensitivityClassifier)

  @doc "Host-owned adapters that enforce sensitivity at their actual transport effect."
  def sensitivity_guarded_adapters do
    Application.get_env(:arbor_llm, :sensitivity_guarded_adapters, [
      Arbor.LLM.Adapter.ReqLLM,
      Arbor.LLM.Adapter.OAuthResponses,
      Arbor.LLM.Adapter.LmStudio
    ])
  end
end
