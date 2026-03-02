defmodule Arbor.AI.SensitivityRouter do
  @moduledoc """
  Sensitivity-aware LLM provider/model auto-selection router.

  Pure-function module (no state) that selects the best `{provider, model}`
  pair based on data sensitivity classification. Bridges the gap between
  the taint system (which classifies data) and LLM routing (which picks providers).

  ## How It Works

  1. `BackendTrust.can_see?/3` checks if a `{provider, model}` can handle a sensitivity level
  2. Candidates are filtered by clearance, then sorted by priority (lower = preferred)
  3. The current provider is preferred if it already qualifies (stability)

  ## Configuration

      config :arbor_ai, :routing_candidates, [
        %{provider: :ollama, model: "llama3.2", priority: 1},
        %{provider: :anthropic, model: "claude-sonnet-4-5-20250514", priority: 2},
        %{provider: :openrouter, model: "anthropic/claude-sonnet-4-5-20250514", priority: 3}
      ]
  """

  alias Arbor.AI.BackendTrust

  require Logger

  @type sensitivity :: :public | :internal | :confidential | :restricted

  @type candidate :: %{
          provider: atom(),
          model: String.t(),
          priority: non_neg_integer()
        }

  @doc """
  Select the best `{provider, model}` pair for the given sensitivity level.

  Filters configured candidates by `BackendTrust.can_see?/3`, then sorts by:
  1. Priority (lower = preferred)
  2. Trust level breadth as tiebreaker (more capable = preferred)

  ## Options

  - `:current_provider` — prefer this provider if it qualifies (stability)
  - `:current_model` — prefer this model if it qualifies (stability)
  - `:candidates` — override the configured candidate pool

  ## Returns

  - `{:ok, {provider, model}}` — best candidate found
  - `{:error, :no_candidates}` — no configured candidates can handle this sensitivity
  """
  @spec select(sensitivity(), keyword()) :: {:ok, {atom(), String.t()}} | {:error, :no_candidates}
  def select(sensitivity, opts \\ []) do
    candidates = Keyword.get(opts, :candidates) || configured_candidates()
    current_provider = Keyword.get(opts, :current_provider)
    current_model = Keyword.get(opts, :current_model)

    qualified =
      candidates
      |> Enum.filter(fn %{provider: p, model: m} ->
        BackendTrust.can_see?(p, m, sensitivity)
      end)
      |> Enum.sort_by(fn %{priority: priority} -> priority end)

    case qualified do
      [] ->
        {:error, :no_candidates}

      candidates_list ->
        # Prefer current provider+model if it's in the qualified list (stability)
        preferred =
          if current_provider do
            Enum.find(candidates_list, fn %{provider: p, model: m} ->
              p == current_provider and (current_model == nil or m == current_model)
            end)
          end

        case preferred do
          %{provider: p, model: m} ->
            {:ok, {p, m}}

          nil ->
            %{provider: p, model: m} = hd(candidates_list)
            {:ok, {p, m}}
        end
    end
  end

  @doc """
  Validate that a `{provider, model}` pair can handle the given sensitivity.

  ## Returns

  - `:ok` — the pair has sufficient clearance
  - `{:error, :insufficient_clearance}` — the pair cannot handle this sensitivity
  """
  @spec validate(atom(), String.t(), sensitivity()) :: :ok | {:error, :insufficient_clearance}
  def validate(provider, model, sensitivity)
      when is_atom(provider) and is_binary(model) and is_atom(sensitivity) do
    if BackendTrust.can_see?(provider, model, sensitivity) do
      :ok
    else
      {:error, :insufficient_clearance}
    end
  end

  @doc """
  Main integration point: returns original pair if sufficient, selects alternative if not.

  No-op for `:public` data (all providers can handle public data).

  ## Options

  Same as `select/2`.

  ## Returns

  - `{provider, model}` — original or rerouted pair
  """
  @spec maybe_reroute(atom(), String.t(), sensitivity() | nil, keyword()) ::
          {atom(), String.t()}
  def maybe_reroute(provider, model, nil, _opts), do: {provider, model}
  def maybe_reroute(provider, model, :public, _opts), do: {provider, model}

  def maybe_reroute(provider, model, sensitivity, opts) do
    if BackendTrust.can_see?(provider, model, sensitivity) do
      {provider, model}
    else
      Logger.info(
        "[SensitivityRouter] #{provider}/#{model} cannot handle #{sensitivity} data, rerouting"
      )

      opts =
        opts
        |> Keyword.put(:current_provider, provider)
        |> Keyword.put(:current_model, model)

      case select(sensitivity, opts) do
        {:ok, {new_provider, new_model}} ->
          Logger.info(
            "[SensitivityRouter] Rerouted to #{new_provider}/#{new_model} for #{sensitivity} data"
          )

          {new_provider, new_model}

        {:error, :no_candidates} ->
          Logger.warning(
            "[SensitivityRouter] No candidates for #{sensitivity} data, keeping #{provider}/#{model}"
          )

          {provider, model}
      end
    end
  end

  # Read routing candidates from application config.
  @spec configured_candidates() :: [candidate()]
  defp configured_candidates do
    Application.get_env(:arbor_ai, :routing_candidates, [])
  end
end
