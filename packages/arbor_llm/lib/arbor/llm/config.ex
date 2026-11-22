defmodule Arbor.LLM.Config do
  @moduledoc "Host-owned runtime collaborators for the LLM boundary."

  @doc "Runtime-only upward seam: with_invocation_audit/2 wraps a tool dispatch. Unavailable required auditors fail closed."
  def tool_invocation_auditor,
    do: Application.get_env(:arbor_llm, :tool_invocation_auditor)

  def sensitivity_policy,
    do: Application.get_env(:arbor_llm, :sensitivity_policy)

  def dispatcher, do: Application.get_env(:arbor_llm, :llm_dispatcher)
  def tool_executor, do: Application.get_env(:arbor_llm, :tool_executor)
  def preprocessor_provider, do: Application.get_env(:arbor_llm, :preprocessor_provider)
  def signal_module, do: Application.get_env(:arbor_llm, :signal_module)
  def telemetry_store, do: Application.get_env(:arbor_llm, :telemetry_store)
  def disclosure_prompt, do: Application.get_env(:arbor_llm, :disclosure_prompt)

  def discover_local_providers,
    do: Application.get_env(:arbor_llm, :discover_local_providers, true)

  @doc "Trusted host registry of external provider strings to adapter modules."
  def external_provider_adapters,
    do: Application.get_env(:arbor_llm, :external_provider_adapters, %{})

  @doc "Select the trusted registry; request options cannot supply adapter modules."
  def external_provider_adapters(opts) do
    adapters =
      case external_provider_adapters() do
        registry when is_map(registry) and not is_struct(registry) ->
          registry
          |> Enum.filter(fn {provider, module} ->
            valid_provider_name?(provider) and is_atom(module) and
              module not in [nil, true, false]
          end)
          |> Map.new()

        _ ->
          %{}
      end

    if Keyword.get(opts, :discover_acp, true), do: adapters, else: Map.delete(adapters, "acp")
  end

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

  defp valid_provider_name?(provider) when is_binary(provider) do
    provider != "" and String.valid?(provider) and
      not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, provider)
  end

  defp valid_provider_name?(_provider), do: false
end
