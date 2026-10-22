defmodule Arbor.Orchestrator.CodingPlan.ReviewPanelCore do
  @moduledoc """
  Pure assessment of the review council's seats against the providers this
  host can call, using the same fallback rules the LLM handler applies at
  call time (`Arbor.Orchestrator.LlmRouting.ProviderFallbackCore`).

  A seat is `:preferred` when its pinned provider is available, `:fallback`
  when the handler would reroute it, and `:unresolved` when nothing in the
  fallback chain is available (that seat will abstain). The panel is
  `:passed` only when every seat runs on its preferred provider; any
  fallback or unresolved seat makes it `:degraded`. Binding decisions
  additionally require a minimum number of distinct `provider:model`
  seats (default 2, configurable). A degraded panel, or one that
  collapses onto too few models, still returns a decision — but that
  decision is not binding (arxiv.org/abs/2610.29178).
  """

  alias Arbor.Orchestrator.LlmRouting.ProviderFallbackCore

  @type seat :: %{id: String.t(), provider: String.t() | nil, model: String.t() | nil}
  @type seat_result :: %{
          id: String.t(),
          preferred: {String.t() | nil, String.t() | nil},
          resolved: {String.t() | nil, String.t() | nil} | nil,
          outcome: :preferred | :fallback | :unresolved
        }
  @type diversity :: :ok | :insufficient
  @type panel :: %{
          status: :passed | :degraded,
          binding: boolean(),
          diversity: diversity(),
          total: non_neg_integer(),
          preferred: non_neg_integer(),
          fallback: non_neg_integer(),
          unresolved: non_neg_integer(),
          distinct_providers: non_neg_integer(),
          distinct_provider_models: non_neg_integer(),
          seats: [seat_result()]
        }

  @default_min_distinct_provider_models 2

  @doc "Default minimum distinct `provider:model` seats for a binding decision."
  @spec default_min_distinct_provider_models() :: pos_integer()
  def default_min_distinct_provider_models, do: @default_min_distinct_provider_models

  @spec assess(
          [seat()],
          (String.t() -> boolean()),
          map(),
          [{String.t(), String.t()}],
          keyword()
        ) :: panel()
  def assess(seats, available?, specific, generic, opts \\ [])

  def assess(seats, available?, specific, generic, opts)
      when is_list(seats) and is_function(available?, 1) do
    results =
      seats
      |> Enum.filter(&valid_seat?/1)
      |> Enum.map(fn seat ->
        case ProviderFallbackCore.resolve(
               seat.provider,
               seat.model,
               available?,
               specific,
               generic
             ) do
          {:ok, resolved, :preferred} ->
            %{
              id: seat.id,
              preferred: {seat.provider, seat.model},
              resolved: resolved,
              outcome: :preferred
            }

          {:ok, resolved, {:fallback, _from}} ->
            %{
              id: seat.id,
              preferred: {seat.provider, seat.model},
              resolved: resolved,
              outcome: :fallback
            }

          {:error, :no_available_provider, _tried} ->
            %{
              id: seat.id,
              preferred: {seat.provider, seat.model},
              resolved: nil,
              outcome: :unresolved
            }
        end
      end)

    counts = Enum.frequencies_by(results, & &1.outcome)
    total = length(results)
    preferred = Map.get(counts, :preferred, 0)
    min_distinct = min_distinct_provider_models(opts)

    resolved_pairs =
      results
      |> Enum.map(& &1.resolved)
      |> Enum.reject(&is_nil/1)

    distinct =
      resolved_pairs
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> length()

    distinct_provider_models =
      resolved_pairs
      |> Enum.uniq()
      |> length()

    status = if(total > 0 and preferred == total, do: :passed, else: :degraded)
    diversity = if distinct_provider_models >= min_distinct, do: :ok, else: :insufficient

    %{
      status: status,
      binding: status == :passed and diversity == :ok,
      diversity: diversity,
      total: total,
      preferred: preferred,
      fallback: Map.get(counts, :fallback, 0),
      unresolved: Map.get(counts, :unresolved, 0),
      distinct_providers: distinct,
      distinct_provider_models: distinct_provider_models,
      seats: results
    }
  end

  def assess(_seats, _available?, _specific, _generic, _opts),
    do: empty_degraded_panel()

  @doc "One-line human summary for a readiness diagnostic."
  @spec message(panel()) :: String.t()
  def message(%{status: :passed, binding: true, total: total, distinct_provider_models: models}),
    do:
      "All #{total} review seats can be called from this host (#{models} distinct provider:model seats; binding)."

  def message(%{status: :passed, binding: false, total: total, distinct_provider_models: models}),
    do:
      "All #{total} review seats can be called from this host (#{models} distinct provider:model seats; decision is non-binding)."

  def message(%{status: :passed, total: total, distinct_providers: d}),
    do: "All #{total} review seats can be called from this host (#{d} distinct providers)."

  def message(%{total: 0}), do: "The reviewed council graph declares no seats."

  def message(panel) do
    fallback_ids = ids(panel, :fallback)
    unresolved_ids = ids(panel, :unresolved)

    parts =
      [
        "#{panel.preferred} of #{panel.total} review seats run on their preferred provider",
        if(fallback_ids != [],
          do: "#{panel.fallback} fall back (#{Enum.join(fallback_ids, ", ")})"
        ),
        if(unresolved_ids != [],
          do: "#{panel.unresolved} will abstain (#{Enum.join(unresolved_ids, ", ")})"
        ),
        "#{panel.distinct_providers} distinct provider(s) will vote",
        binding_clause(panel)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "; ") <> "."
  end

  @doc "What the operator can do about a degraded panel."
  @spec remedy(panel()) :: String.t()
  def remedy(%{status: :passed, diversity: :insufficient}),
    do: diversity_remedy()

  def remedy(%{unresolved: 0} = panel),
    do:
      maybe_append_diversity(
        panel,
        "Add or log in the preferred providers (docs/arbor/COUNCIL_SETUP.md) to restore the reviewed model diversity."
      )

  def remedy(panel),
    do:
      maybe_append_diversity(
        panel,
        "Log in or configure a provider for the abstaining seats, or extend config :arbor_orchestrator, :llm_fallback_providers (docs/arbor/COUNCIL_SETUP.md)."
      )

  # Diagnostic text is capped at 256 bytes by the Diagnostic contract; list a
  # few seat ids and summarize the rest.
  @listed_ids 3
  defp ids(panel, outcome) do
    all = panel.seats |> Enum.filter(&(&1.outcome == outcome)) |> Enum.map(& &1.id)

    case Enum.split(all, @listed_ids) do
      {shown, []} -> shown
      {shown, rest} -> shown ++ ["+#{length(rest)} more"]
    end
  end

  defp valid_seat?(%{id: id, provider: provider}) when is_binary(id) and is_binary(provider),
    do: id != "" and provider != ""

  defp valid_seat?(_), do: false

  defp min_distinct_provider_models(opts) when is_list(opts) do
    case Keyword.get(opts, :min_distinct_provider_models) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_min_distinct_provider_models
    end
  end

  defp min_distinct_provider_models(_opts), do: @default_min_distinct_provider_models

  defp binding_clause(%{binding: false}), do: "decision is non-binding"
  defp binding_clause(_panel), do: nil

  defp maybe_append_diversity(%{diversity: :insufficient}, message),
    do: message <> " " <> diversity_remedy()

  defp maybe_append_diversity(_panel, message), do: message

  defp diversity_remedy,
    do:
      "Remap seats so at least #{@default_min_distinct_provider_models} distinct provider:model pairs vote, or raise :min_binding_provider_models only after the host can honour it (docs/arbor/COUNCIL_SETUP.md)."

  defp empty_degraded_panel do
    %{
      status: :degraded,
      binding: false,
      diversity: :insufficient,
      total: 0,
      preferred: 0,
      fallback: 0,
      unresolved: 0,
      distinct_providers: 0,
      distinct_provider_models: 0,
      seats: []
    }
  end
end
