defmodule Arbor.Orchestrator.Handlers.RoutingHandler do
  @moduledoc """
  Handler for LLM routing graph nodes.

  Supports node type `routing.select` — filters candidates by pre-computed
  context flags and selects the first passing backend+model pair.

  All filter data (availability, trust, quota, budget) is pre-computed by the
  caller and passed via initial_values. This handler does zero I/O.

  ## Node Attributes

  - `candidates` — JSON array of `[backend, model]` pairs, e.g.
    `[["anthropic","opus"],["anthropic","sonnet"]]`

  ## Context Inputs

  - `tier` — routing tier string ("critical", "complex", etc.)
  - `budget_status` — "normal", "low", or "over"
  - `exclude` — comma-separated backend names to skip
  - `avail_<backend>` — "true" if backend is available
  - `trust_<backend>` — "true" if backend meets min trust
  - `quota_<backend>` — "true" if backend has quota remaining
  - `free_<backend>` — "true" if backend is free-tier

  ## Context Outputs (on success)

  - `selected_backend` — chosen backend name
  - `selected_model` — chosen model shorthand
  - `routing_reason` — "tier_match" or "fallback"
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node

  @impl true
  def execute(%Node{} = node, %Context{} = context, _graph, _opts) do
    candidates = parse_candidates(node.attrs["candidates"] || "[]")
    exclude = parse_exclude(Context.get(context, "exclude", ""))
    budget_status = Context.get(context, "budget_status", "normal")
    tier = Context.get(context, "tier", "moderate")

    selected =
      candidates
      |> reject_excluded(exclude)
      |> filter_available(context)
      |> filter_trust(context)
      |> filter_quota(context)
      |> apply_budget_filter(context, budget_status, tier)
      |> List.first()

    case selected do
      {backend, model} ->
        reason = if String.contains?(node.id, "fallback"), do: "fallback", else: "tier_match"

        %Outcome{
          status: :success,
          context_updates: %{
            "selected_backend" => backend,
            "selected_model" => model,
            "routing_reason" => reason
          },
          notes: "Selected #{backend}/#{model} (#{reason})"
        }

      nil ->
        %Outcome{
          status: :fail,
          failure_reason: "No candidates passed filters"
        }
    end
  end

  @impl true
  def idempotency, do: :read_only

  # --- Candidate parsing ---

  defp parse_candidates(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn
          [backend, model] -> {backend, model}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_candidates(_), do: []

  defp parse_exclude(""), do: []

  defp parse_exclude(str) when is_binary(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_exclude(_), do: []

  # --- Filters ---

  defp reject_excluded(candidates, exclude) do
    Enum.reject(candidates, fn {backend, _model} -> backend in exclude end)
  end

  defp filter_available(candidates, context) do
    Enum.filter(candidates, fn {backend, _model} ->
      Context.get(context, "avail_#{backend}", "false") == "true"
    end)
  end

  defp filter_trust(candidates, context) do
    Enum.filter(candidates, fn {backend, _model} ->
      Context.get(context, "trust_#{backend}", "true") == "true"
    end)
  end

  defp filter_quota(candidates, context) do
    Enum.filter(candidates, fn {backend, _model} ->
      Context.get(context, "quota_#{backend}", "true") == "true"
    end)
  end

  defp apply_budget_filter(candidates, context, budget_status, tier) do
    cond do
      # Critical tasks ignore budget constraints
      tier == "critical" ->
        candidates

      # Over budget: only free backends
      budget_status == "over" ->
        Enum.filter(candidates, fn {backend, _model} ->
          Context.get(context, "free_#{backend}", "false") == "true"
        end)

      # Low budget: sort free first, allow paid as fallback
      budget_status == "low" ->
        {free, paid} =
          Enum.split_with(candidates, fn {backend, _model} ->
            Context.get(context, "free_#{backend}", "false") == "true"
          end)

        free ++ paid

      # Normal budget: no filtering
      true ->
        candidates
    end
  end
end
