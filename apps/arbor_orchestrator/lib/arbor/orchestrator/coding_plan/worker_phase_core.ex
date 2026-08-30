defmodule Arbor.Orchestrator.CodingPlan.WorkerPhaseCore do
  @moduledoc false

  # Closed milestone ids used to project semantic worker phase from
  # Engine-owned PipelineStatus completed_nodes. Semantic preflight pins
  # these names so a graph edit cannot silently retarget the gate.
  @mark_implementation_phase "mark_implementation_phase"
  @build_implement_prompt "build_implement_prompt"
  @init_design_defaults "init_design_defaults"
  @init_worker_phase "init_worker_phase"
  @build_design_prompt "build_design_prompt"

  @derivation_nodes [
    @mark_implementation_phase,
    @build_implement_prompt,
    @init_design_defaults,
    @init_worker_phase,
    @build_design_prompt
  ]

  # Same bound as RunLifecycle.Adapter public completed_nodes.
  @max_completed_nodes 256

  @type phase :: :design | :implement | :unknown

  @doc false
  @spec derivation_nodes() :: [String.t()]
  def derivation_nodes, do: @derivation_nodes

  @doc false
  @spec admit_completed_nodes(term()) :: [String.t()]
  def admit_completed_nodes(nodes) when is_list(nodes) do
    take_binaries(nodes, @max_completed_nodes, [])
  end

  def admit_completed_nodes(_nodes), do: []

  # Examine at most `@max_completed_nodes` cons cells. Non-binaries in that
  # window are dropped; an improper tail fail-closes the whole admission.
  defp take_binaries(_rest, 0, acc), do: Enum.reverse(acc)

  defp take_binaries([head | rest], remaining, acc)
       when remaining > 0 and is_binary(head) do
    take_binaries(rest, remaining - 1, [head | acc])
  end

  defp take_binaries([_head | rest], remaining, acc) when remaining > 0 do
    take_binaries(rest, remaining - 1, acc)
  end

  defp take_binaries([], _remaining, acc), do: Enum.reverse(acc)

  defp take_binaries(_improper, _remaining, _acc), do: []

  @doc false
  @spec project(term()) :: phase()
  def project(nodes) do
    completed = MapSet.new(admit_completed_nodes(nodes))

    cond do
      MapSet.member?(completed, @mark_implementation_phase) ->
        :implement

      MapSet.member?(completed, @build_implement_prompt) ->
        :implement

      Enum.any?(
        [@init_design_defaults, @init_worker_phase, @build_design_prompt],
        &MapSet.member?(completed, &1)
      ) ->
        :design

      true ->
        :unknown
    end
  end

  @doc false
  @spec to_status(phase() | term()) :: String.t() | nil
  def to_status(:design), do: "design"
  def to_status(:implement), do: "implement"
  def to_status(_phase), do: nil
end
