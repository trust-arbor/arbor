defmodule Arbor.LLM.Config do
  @moduledoc "Host-owned runtime collaborators for the LLM boundary."
  @default_auditor if(Mix.env() == :test,
                     do: :disabled,
                     else: Module.concat(["Arbor", "Security"])
                   )

  @doc "Runtime-only upward seam: with_invocation_audit/2 wraps a tool dispatch. Unavailable required auditors fail closed."
  def tool_invocation_auditor,
    do: Application.get_env(:arbor_llm, :tool_invocation_auditor, @default_auditor)
end
