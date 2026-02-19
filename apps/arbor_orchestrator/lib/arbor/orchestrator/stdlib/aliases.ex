defmodule Arbor.Orchestrator.Stdlib.Aliases do
  @moduledoc """
  Alias resolution layer mapping all existing handler type strings to 15 canonical core types.

  This module is the foundation of the handler primitives redesign. It provides
  a mapping from every existing type string to one of 15 canonical types, plus
  optional attribute injection to preserve semantic intent.

  ## Canonical Types (15)

  | Domain | Types |
  |--------|-------|
  | Control Flow | start, exit, branch, parallel, fan_in |
  | Computation | compute, transform, exec |
  | State | read, write |
  | Composition | compose, map, adapt |
  | Coordination | wait |
  | Governance | gate |

  ## Resolution

  `canonical_type/1` returns the canonical type name for any type string.
  Core types map to themselves. Aliases map to their canonical form.

  `resolve/1` returns `{canonical_type, injected_attrs}` for aliases that
  need attribute injection to preserve intent, or `:passthrough` for types
  that need no transformation.
  """

  @canonical_types ~w(
    start exit branch parallel fan_in
    compute transform exec
    read write
    compose map adapt
    wait
    gate
  )

  # Maps every type string to its canonical type.
  # Core types map to themselves; aliases map to their canonical form.
  @alias_map %{
    # === Core types (identity mapping) ===
    "start" => "start",
    "exit" => "exit",
    "branch" => "branch",
    "parallel" => "parallel",
    "fan_in" => "fan_in",
    "compute" => "compute",
    "transform" => "transform",
    "exec" => "exec",
    "read" => "read",
    "write" => "write",
    "compose" => "compose",
    "map" => "map",
    "adapt" => "adapt",
    "wait" => "wait",
    "gate" => "gate",

    # === Control Flow aliases ===
    "conditional" => "branch",
    "parallel.fan_in" => "fan_in",

    # === Computation aliases ===
    "codergen" => "compute",
    "routing.select" => "compute",
    "prompt.ab_test" => "compute",
    "drift_detect" => "compute",
    "retry.escalate" => "compute",

    # === Execution aliases ===
    "tool" => "exec",
    "shell" => "exec",

    # === Read aliases ===
    "memory.recall" => "read",
    "memory.working_load" => "read",
    "memory.stats" => "read",
    "memory.recall_store" => "read",
    "eval.dataset" => "read",

    # === Write aliases ===
    "file.write" => "write",
    "memory.consolidate" => "write",
    "memory.index" => "write",
    "memory.working_save" => "write",
    "memory.store_file" => "write",
    "accumulator" => "write",
    "eval.persist" => "write",
    "eval.report" => "write",

    # === Composition aliases ===
    "graph.invoke" => "compose",
    "graph.compose" => "compose",
    "graph.adapt" => "adapt",
    "pipeline.run" => "compose",
    "feedback.loop" => "compose",
    "stack.manager_loop" => "compose",
    # Consensus — compose of sub-pipeline (long-term migration)
    "consensus.propose" => "compose",
    "consensus.ask" => "compose",
    "consensus.await" => "compose",
    "consensus.check" => "compose",
    "consensus.decide" => "compose",
    # Session — compose internals (long-term migration)
    "session.classify" => "compose",
    "session.memory_recall" => "compose",
    "session.mode_select" => "compose",
    "session.llm_call" => "compose",
    "session.tool_dispatch" => "compose",
    "session.format" => "compose",
    "session.memory_update" => "compose",
    "session.checkpoint" => "compose",
    "session.background_checks" => "compose",
    "session.process_results" => "compose",
    "session.route_actions" => "compose",
    "session.update_goals" => "compose",
    "session.store_decompositions" => "compose",
    "session.process_proposal_decisions" => "compose",
    "session.consolidate" => "compose",
    "session.update_working_memory" => "compose",
    "session.store_identity" => "compose",
    # Eval compute/exec aliases
    "eval.run" => "compute",
    "eval.aggregate" => "compute",

    # === Coordination aliases ===
    "wait.human" => "wait",

    # === Governance aliases ===
    "output.validate" => "gate",
    "pipeline.validate" => "gate"
  }

  # Resolution map: aliases that need attribute injection to preserve semantic intent.
  # Only includes entries where injected attributes are needed. Types that map
  # cleanly without attrs are not listed (canonical_type/1 suffices).
  @resolve_map %{
    # Exec — target attribute distinguishes tool vs shell vs action
    "tool" => {"exec", %{"target" => "tool"}},
    "shell" => {"exec", %{"target" => "shell"}},

    # Read — source attribute distinguishes memory vs file vs eval
    "memory.recall" => {"read", %{"source" => "memory", "op" => "recall"}},
    "memory.working_load" => {"read", %{"source" => "memory", "op" => "working_load"}},
    "memory.stats" => {"read", %{"source" => "memory", "op" => "stats"}},
    "memory.recall_store" => {"read", %{"source" => "memory", "op" => "recall_store"}},
    "eval.dataset" => {"read", %{"source" => "eval_dataset"}},

    # Write — target + mode attributes
    "file.write" => {"write", %{"target" => "file"}},
    "memory.consolidate" => {"write", %{"target" => "memory", "op" => "consolidate"}},
    "memory.index" => {"write", %{"target" => "memory", "op" => "index"}},
    "memory.working_save" => {"write", %{"target" => "memory", "op" => "working_save"}},
    "memory.store_file" => {"write", %{"target" => "memory", "op" => "store_file"}},
    "accumulator" => {"write", %{"target" => "accumulator", "mode" => "append"}},
    "eval.persist" => {"write", %{"target" => "eval", "op" => "persist"}},
    "eval.report" => {"write", %{"target" => "eval", "op" => "report"}},

    # Compute — purpose attribute distinguishes LLM vs routing vs testing
    "codergen" => {"compute", %{"purpose" => "llm"}},
    "routing.select" => {"compute", %{"purpose" => "routing"}},
    "prompt.ab_test" => {"compute", %{"purpose" => "ab_test"}},
    "drift_detect" => {"compute", %{"purpose" => "drift_detect"}},
    "retry.escalate" => {"compute", %{"purpose" => "retry_escalate"}},
    "eval.run" => {"compute", %{"purpose" => "eval_run"}},
    "eval.aggregate" => {"compute", %{"purpose" => "eval_aggregate"}},

    # Compose — mode attribute distinguishes invoke vs pipeline vs feedback
    "graph.invoke" => {"compose", %{"mode" => "invoke"}},
    "graph.compose" => {"compose", %{"mode" => "compose"}},
    "pipeline.run" => {"compose", %{"mode" => "pipeline"}},
    "feedback.loop" => {"compose", %{"mode" => "feedback"}},
    "stack.manager_loop" => {"compose", %{"mode" => "manager_loop"}},

    # Wait — source attribute
    "wait.human" => {"wait", %{"source" => "human"}},

    # Gate — predicate attribute
    "output.validate" => {"gate", %{"predicate" => "output_valid"}},
    "pipeline.validate" => {"gate", %{"predicate" => "pipeline_valid"}}
  }

  @doc "Returns the 15 canonical core type names."
  @spec canonical_types() :: [String.t()]
  def canonical_types, do: @canonical_types

  @doc """
  Returns the canonical type for any type string.

  Core types map to themselves. Aliases map to their canonical form.
  Unknown types return the input unchanged (passthrough).
  """
  @spec canonical_type(String.t()) :: String.t()
  def canonical_type(type) when is_binary(type) do
    Map.get(@alias_map, type, type)
  end

  @doc """
  Resolves a type string to its canonical form with optional attribute injection.

  Returns `{canonical_type, injected_attrs}` for aliases that need attribute
  injection to preserve semantic intent, or `:passthrough` for types that
  need no transformation (core types or unknown types).
  """
  @spec resolve(String.t()) :: {String.t(), map()} | :passthrough
  def resolve(type) when is_binary(type) do
    case Map.get(@resolve_map, type) do
      {canonical, attrs} -> {canonical, attrs}
      nil -> :passthrough
    end
  end

  @doc """
  Returns all type strings that map to a given canonical type.

  Includes the canonical type itself if it appears in the alias map.
  """
  @spec aliases_for(String.t()) :: [String.t()]
  def aliases_for(canonical_type) when is_binary(canonical_type) do
    @alias_map
    |> Enum.filter(fn {_alias, canonical} -> canonical == canonical_type end)
    |> Enum.map(fn {alias_name, _} -> alias_name end)
    |> Enum.sort()
  end

  @doc "Returns true if the given type string is a canonical core type."
  @spec canonical?(String.t()) :: boolean()
  def canonical?(type) when is_binary(type) do
    type in @canonical_types
  end

  @doc "Returns the full alias map (all type strings → canonical types)."
  @spec alias_map() :: %{String.t() => String.t()}
  def alias_map, do: @alias_map
end
