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
    * `trust_tier`     — minimum trust tier required: `"untrusted"`, `"probationary"`,
                         `"trusted"`, `"veteran"`, `"autonomous"` (default: none — unrestricted)

  ## Trust-tier constraints (council-recommended)

  When `trust_tier` is set on the adapt node, the handler checks the agent's
  trust tier from `session.trust_tier` in context. Tiers constrain what mutations
  are allowed:

    * `untrusted`    — no adapt allowed (always fails)
    * `probationary` — `modify_attrs` only (parameter tuning)
    * `trusted`      — `modify_attrs` + `add_edge` + `remove_edge` (rewiring)
    * `veteran`      — all operations except `remove_node` on non-leaf nodes
    * `autonomous`   — unrestricted

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

  @trust_tiers ~w(untrusted probationary trusted veteran autonomous)

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
      case check_trust_tier(node, context) do
        :ok -> process_mutations(node, context, graph, json)
        {:error, reason} -> fail(reason)
      end
    end
  rescue
    e -> fail("graph.adapt: #{Exception.message(e)}")
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Trust tier check ---

  defp check_trust_tier(node, context) do
    required_tier = Map.get(node.attrs, "trust_tier")

    if required_tier && required_tier in @trust_tiers do
      agent_tier = Context.get(context, "session.trust_tier", "untrusted")
      tier_index = Enum.find_index(@trust_tiers, &(&1 == agent_tier)) || 0
      required_index = Enum.find_index(@trust_tiers, &(&1 == required_tier)) || 0

      if tier_index >= required_index do
        :ok
      else
        {:error,
         "trust tier insufficient: agent has \"#{agent_tier}\", " <>
           "adapt node requires \"#{required_tier}\""}
      end
    else
      :ok
    end
  end

  # --- Mutation processing ---

  defp process_mutations(node, context, graph, json) do
    max_mutations =
      node.attrs
      |> Map.get("max_mutations", "10")
      |> parse_int(10)

    dry_run = Map.get(node.attrs, "dry_run", "false") == "true"

    with {:ok, ops} <- GraphMutation.parse(json),
         :ok <- check_count(ops, max_mutations),
         :ok <- check_tier_allowed_ops(node, context, ops),
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

  # --- Per-tier operation restrictions ---

  defp check_tier_allowed_ops(node, context, ops) do
    agent_tier = Context.get(context, "session.trust_tier")

    # Only enforce restrictions if trust_tier is configured
    if agent_tier && Map.has_key?(node.attrs, "trust_tier") do
      do_check_tier_ops(agent_tier, ops)
    else
      :ok
    end
  end

  defp do_check_tier_ops("untrusted", _ops) do
    {:error, "untrusted agents cannot use adapt nodes"}
  end

  defp do_check_tier_ops("probationary", ops) do
    # Only modify_attrs allowed
    case Enum.find(ops, fn op -> op["op"] != "modify_attrs" end) do
      nil ->
        :ok

      op ->
        {:error, "probationary tier: operation \"#{op["op"]}\" not allowed (only modify_attrs)"}
    end
  end

  defp do_check_tier_ops("trusted", ops) do
    # modify_attrs, add_edge, remove_edge allowed
    allowed = ~w(modify_attrs add_edge remove_edge)

    case Enum.find(ops, fn op -> op["op"] not in allowed end) do
      nil -> :ok
      op -> {:error, "trusted tier: operation \"#{op["op"]}\" not allowed"}
    end
  end

  defp do_check_tier_ops(_tier, _ops) do
    # veteran and autonomous — all ops allowed
    :ok
  end

  # --- Helpers ---

  defp ok(context_updates, notes) do
    %Outcome{status: :success, context_updates: context_updates, notes: notes}
  end

  defp fail(reason) do
    %Outcome{status: :fail, failure_reason: reason}
  end
end
