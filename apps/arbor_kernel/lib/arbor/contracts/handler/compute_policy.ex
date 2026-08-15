defmodule Arbor.Contracts.Handler.ComputePolicy do
  @moduledoc """
  Behaviour for compute backend selection policies.

  When multiple Computable backends are registered, the ComputePolicy
  determines which one to use for a given request. Different policies
  optimize for different goals: cost, latency, privacy, etc.

  Council requirement: "Compute Selection as Policy" (8/13 approval).

  ## Example

      defmodule CostFirstPolicy do
        @behaviour Arbor.Contracts.Handler.ComputePolicy

        @impl true
        def select(candidates, context) do
          # candidates is [{name, module, metadata}, ...]
          sorted = Enum.sort_by(candidates, fn {_name, _mod, meta} ->
            Map.get(meta, :cost_per_token, 999)
          end)

          case sorted do
            [{name, _mod, _meta} | _] -> {:ok, name}
            [] -> {:error, :no_candidates}
          end
        end
      end
  """

  @type candidate :: {name :: String.t(), module :: module(), metadata :: map()}

  @doc """
  Select the best compute backend from a list of candidates.

  `candidates` is a list of `{name, module, metadata}` tuples
  representing available Computable backends. `context` provides
  request-specific information to inform the selection.

  Returns `{:ok, name}` with the selected backend name, or
  `{:error, reason}` if no suitable backend is available.
  """
  @callback select(candidates :: [candidate()], context :: map()) ::
              {:ok, String.t()} | {:error, term()}
end
