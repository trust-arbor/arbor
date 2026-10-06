defmodule Arbor.Orchestrator.LlmRouting.SensitivityAdapter do
  @moduledoc false
  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.Orchestrator.LlmRouting.Sensitivity

  def provider, do: "orchestrator_sensitive_model"
  def complete(request, opts), do: invoke(:complete, request, [], opts)

  def complete_single_attempt(request, opts),
    do: invoke(:complete_single_attempt, request, [], opts)

  def complete_streaming(request, callback, opts),
    do: invoke(:complete_streaming, request, [callback], opts)

  def complete_streaming_single_attempt(request, callback, opts),
    do: invoke(:complete_streaming_single_attempt, request, [callback], opts)

  def stream(request, opts), do: invoke(:stream, request, [], opts)

  defp invoke(operation, request, middle, opts) do
    case Sensitivity.pop_scope(opts) do
      {nil, _} -> {:error, {:sensitivity_blocked, :policy_unavailable}}
      {scope, public_opts} -> Sensitivity.invoke(scope, operation, request, middle, public_opts)
    end
  end
end
