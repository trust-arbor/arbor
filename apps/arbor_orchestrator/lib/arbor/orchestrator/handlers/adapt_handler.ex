defmodule Arbor.Orchestrator.Handlers.AdaptHandler do
  @moduledoc """
  Handler for `graph.adapt` nodes that enable self-modifying pipelines.

  When executed, reads mutation instructions and applies them to the pipeline
  graph. The engine detects the mutated graph via a special context key and
  swaps it in for subsequent execution.

  ## Node attributes

    * `mutations`      — JSON string of mutation operations (static)
    * `mutations_key`  — context key containing JSON mutations (dynamic, takes precedence)
    * `max_mutations`  — maximum number of operations allowed (default: `"10"`)
    * `dry_run`        — `"true"` to validate without applying (default: `"false"`)
    * `trust_tier`     — IGNORED (no-op). The trust-tier band was retired; adapt
                         mutations are governed by the agent's granular
                         baseline/rules + capability checks, not by a tier.

  ## Engine integration

  The handler stores the mutated graph under context key `__adapted_graph__`
  (as a serializable reference). The engine picks this up after node execution
  and swaps the graph. Metadata is stored under `adapt.{node_id}.version`
  and `adapt.{node_id}.applied_ops`.

  Ported from homelab Attractor, adapted for arbor_orchestrator's struct-based Context.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.GraphMutation

  import Arbor.Orchestrator.Handlers.Helpers

  @impl true
  def execute(node, context, graph, _opts) do
    mutations_key = Map.get(node.attrs, "mutations_key")

    json =
      if mutations_key do
        Context.get(context, mutations_key)
      else
        Map.get(node.attrs, "mutations")
      end

    if is_nil(json) or json == "" do
      fail("no mutations provided for adapt node \"#{node.id}\"")
    else
      process_mutations(node, context, graph, json)
    end
  rescue
    e -> fail("graph.adapt: #{Exception.message(e)}")
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Mutation processing ---

  defp process_mutations(node, context, graph, json) do
    max_mutations =
      node.attrs
      |> Map.get("max_mutations", "10")
      |> parse_int(10)

    dry_run = Map.get(node.attrs, "dry_run", "false") == "true"

    with {:ok, ops} <- GraphMutation.parse(json),
         :ok <- check_count(ops, max_mutations),
         completed_nodes <- get_completed_nodes(context),
         :ok <- GraphMutation.validate(ops, graph, completed_nodes) do
      if dry_run do
        ok(%{}, "dry run: #{length(ops)} mutation(s) validated successfully")
      else
        case GraphMutation.apply_mutations(ops, graph) do
          {:ok, new_graph} ->
            version = Map.get(new_graph.attrs, "__mutation_version__", 0)

            ok(
              %{
                "__adapted_graph__" => new_graph,
                "adapt.#{node.id}.version" => version,
                "adapt.#{node.id}.applied_ops" => length(ops)
              },
              "applied #{length(ops)} mutation(s), version=#{version}"
            )

          {:error, reason} ->
            fail(reason)
        end
      end
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp check_count(ops, max) do
    if length(ops) > max do
      {:error, "too many mutations: #{length(ops)} exceeds max of #{max}"}
    else
      :ok
    end
  end

  defp get_completed_nodes(context) do
    context
    |> Context.get("__completed_nodes__", [])
    |> MapSet.new()
  end

  # --- Helpers ---

  defp ok(context_updates, notes) do
    %Outcome{status: :success, context_updates: context_updates, notes: notes}
  end

  defp fail(reason) do
    %Outcome{status: :fail, failure_reason: reason}
  end
end
