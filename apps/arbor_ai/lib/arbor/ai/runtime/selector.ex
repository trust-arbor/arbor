defmodule Arbor.AI.Runtime.Selector do
  @moduledoc """
  Pure policy chain that picks a `{provider, runtime}` pair for a turn.

  Given a `%Arbor.Contracts.LLM.ModelEntry{}` (which lists which providers
  can serve a model and which runtimes each provider supports) and an
  optional per-turn policy, the selector resolves the chain:

      1. Per-turn override        (policy.runtime, policy.provider)
      2. Model-scoped pins        (policy.model_runtime_pins[canonical_id])
      3. Provider-scoped pins     (policy.provider_runtime_pins[provider_id])
      4. Default runtime          (policy.default_runtime, defaults to :arbor)
      5. Auto-claim a provider    (first provider supporting the chosen runtime)

  ## Why this is pure

  No GenServer state, no Application config reads, no llm_db lookups. The
  caller assembles a `%ModelEntry{}` (via `ModelProfile.entry/1`) and a
  policy map, then calls `choose/2`. This keeps the selection logic
  trivial to test exhaustively and lets the chain run inside hot turn
  paths without lock contention.

  Per-agent runtime pins are intentionally NOT a policy field — they're
  deprecated in favor of per-turn overrides and per-model pins
  (see `.arbor/roadmap/1-brainstorming/model-and-runtime-policy.md`).
  """

  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

  @type fallback_entry :: %{
          optional(:runtime) => atom(),
          optional(:provider) => atom(),
          optional(:model) => String.t()
        }

  @type policy :: %{
          optional(:runtime) => atom(),
          optional(:provider) => atom(),
          optional(:model_runtime_pins) => %{String.t() => atom()},
          optional(:provider_runtime_pins) => %{atom() => atom()},
          optional(:default_runtime) => atom(),
          # Ordered list of overrides to try when the primary attempt
          # fails with a fallback-eligible error. Each entry is a partial
          # override: omit a field to inherit it from the original
          # request/policy. The Selector itself ignores this field —
          # `Arbor.AI.Runtime.Dispatch.dispatch/2` reads it and drives
          # the retry loop. See its moduledoc for the eligibility rules.
          optional(:fallback_chain) => [fallback_entry()]
        }

  @type selection :: %{provider: ProviderEntry.t(), runtime: atom()}

  @type error ::
          :no_providers
          | {:requested_provider_not_available, atom()}
          | {:requested_runtime_not_supported, atom()}
          | {:no_provider_supports_runtime, atom()}

  @default_runtime :arbor

  @doc """
  Pick a `{provider, runtime}` for a turn.

  Returns `{:ok, %{provider: %ProviderEntry{}, runtime: atom}}` on
  success. Failure modes:

    * `:no_providers` — the model entry has no provider list
    * `{:requested_provider_not_available, id}` — `policy.provider`
      doesn't appear in the model's provider list
    * `{:requested_runtime_not_supported, runtime}` — `policy.runtime`
      isn't in the chosen provider's runtime list
    * `{:no_provider_supports_runtime, runtime}` — no provider in the
      model's list supports the runtime selected by the policy chain
  """
  @spec choose(ModelEntry.t(), policy()) :: {:ok, selection()} | {:error, error()}
  def choose(model_entry, policy \\ %{})

  def choose(%ModelEntry{providers: []}, _policy), do: {:error, :no_providers}

  def choose(%ModelEntry{} = model_entry, policy) do
    with {:ok, runtime} <- pick_runtime(model_entry, policy),
         {:ok, provider} <- pick_provider(model_entry, runtime, policy) do
      {:ok, %{provider: provider, runtime: runtime}}
    end
  end

  # ---- Runtime picking ----

  defp pick_runtime(%ModelEntry{} = entry, policy) do
    cond do
      # 1. Per-turn override
      not is_nil(policy[:runtime]) ->
        {:ok, policy[:runtime]}

      # 2. Model-scoped pin
      pinned = get_in(policy, [:model_runtime_pins, entry.canonical_id]) ->
        {:ok, pinned}

      # 3. Provider-scoped pin (only consultable when policy pins a provider)
      pinned = pinned_for_requested_provider(policy) ->
        {:ok, pinned}

      true ->
        # 4. Default runtime
        {:ok, policy[:default_runtime] || @default_runtime}
    end
  end

  defp pinned_for_requested_provider(%{provider: requested} = policy)
       when is_atom(requested) do
    get_in(policy, [:provider_runtime_pins, requested])
  end

  defp pinned_for_requested_provider(_), do: nil

  # ---- Provider picking ----
  #
  # If policy.provider is set, that provider MUST appear in the model's
  # provider list, AND it MUST support the chosen runtime. Else error
  # — silently swapping providers under a caller's explicit pin would
  # be surprising.
  #
  # Without a pinned provider, auto-claim: walk the model's providers
  # in declared order, return the first one supporting the chosen
  # runtime.

  defp pick_provider(%ModelEntry{providers: providers} = _entry, runtime, %{provider: pinned})
       when is_atom(pinned) do
    case Enum.find(providers, fn p -> p.id == pinned end) do
      nil ->
        {:error, {:requested_provider_not_available, pinned}}

      %ProviderEntry{} = provider ->
        if runtime in provider.runtimes do
          {:ok, provider}
        else
          {:error, {:requested_runtime_not_supported, runtime}}
        end
    end
  end

  defp pick_provider(%ModelEntry{providers: providers}, runtime, _policy) do
    case Enum.find(providers, fn p -> runtime in p.runtimes end) do
      nil -> {:error, {:no_provider_supports_runtime, runtime}}
      %ProviderEntry{} = provider -> {:ok, provider}
    end
  end
end
