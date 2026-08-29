defmodule Arbor.Actions.PipelineInternalGraphSyscallGuardTest do
  @moduledoc """
  Standing guard: every registered action used as a DOT graph syscall is
  either tagged `pipeline_internal` or explicitly allowlisted as dual-use.

  DOT targets are derived from tracked pipeline files (`apps/*/priv/**/*.dot`
  and `apps/*/specs/**/*.dot`), not a hand-copied target list.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions
  alias Arbor.Actions.SessionExecution
  alias Arbor.Actions.SessionGoals
  alias Arbor.Actions.SessionLlm
  alias Arbor.Actions.SessionMemory
  alias Arbor.Common.CapabilityIndex

  @action_attr ~r/(?<![A-Za-z0-9_.])action\s*=\s*["']([^"']+)["']/

  @session_graph_syscalls [
    SessionGoals.UpdateGoals,
    SessionGoals.StoreDecompositions,
    SessionGoals.ProcessProposalDecisions,
    SessionGoals.StoreIdentity,
    SessionGoals.PruneStaleIntents,
    SessionExecution.RouteActions,
    SessionExecution.ExecuteActions,
    SessionLlm.BuildPrompt,
    SessionMemory.Recall,
    SessionMemory.Update,
    SessionMemory.Checkpoint,
    SessionMemory.Consolidate,
    SessionMemory.UpdateWorkingMemory,
    SessionMemory.BackgroundChecks,
    Actions.Session.Classify,
    Actions.Session.ModeSelect,
    Actions.Session.ProcessResults
  ]

  defmodule StaleSessionGraphSyscallProvider do
    @moduledoc false

    def list_capabilities(_opts \\ []) do
      [
        {SessionGoals.UpdateGoals, "session_goals_update"},
        {SessionExecution.RouteActions, "session_exec_route_actions"},
        {SessionLlm.BuildPrompt, "session_llm_build_prompt"}
      ]
      |> Enum.map(fn {module, name} ->
        Arbor.Common.CapabilityProviders.ActionProvider.module_to_descriptor(
          name,
          module,
          %{}
        )
      end)
    end
  end

  describe "DOT-target inventory and pipeline_internal classification" do
    test "inventories tracked pipeline action targets" do
      {targets, resolved} = inventory_dot_action_targets()

      assert targets != [], "expected tracked pipeline files to declare action= targets"

      resolved_modules = MapSet.new(resolved, fn {_target, module} -> module end)

      for module <- @session_graph_syscalls do
        assert module in resolved_modules,
               "#{inspect(module)} is a session graph syscall but was not found in tracked DOT files"
      end
    end

    test "non-allowlisted graph syscalls are tagged pipeline_internal" do
      {_targets, resolved} = inventory_dot_action_targets()

      untagged =
        resolved
        |> Enum.map(fn {_target, module} -> module end)
        |> Enum.uniq()
        |> Enum.reject(&Actions.pipeline_internal_action?/1)
        |> Enum.reject(&Actions.dual_use_graph_action?/1)
        |> Enum.sort()

      assert untagged == [],
             "DOT graph syscalls missing pipeline_internal (add the tag, or review into dual_use_graph_actions/0): " <>
               inspect(untagged)
    end

    test "every inventoried target resolves to a registered action" do
      {targets, resolved} = inventory_dot_action_targets()
      resolved_names = MapSet.new(resolved, fn {target, _module} -> target end)
      unresolved = Enum.reject(targets, &MapSet.member?(resolved_names, &1))

      assert unresolved == [],
             "tracked DOT action= targets did not resolve via Arbor.Actions.name_to_module/1: " <>
               inspect(unresolved)
    end

    test "dual-use allowlist modules are registered and disjoint from pipeline_internal" do
      allowlisted = Actions.dual_use_graph_actions()
      assert allowlisted != []
      registered = MapSet.new(Actions.all_actions())

      for module <- allowlisted do
        assert module in registered,
               "#{inspect(module)} is allowlisted as dual-use but is not in all_actions/0"

        refute Actions.pipeline_internal_action?(module),
               "#{inspect(module)} cannot be both pipeline_internal and dual-use"
      end
    end
  end

  describe "disclosure surfaces" do
    test "APIAgent-facing catalog hides session graph syscalls and keeps dual-use tools" do
      exposed = Actions.exposed_actions()
      exposed_names = MapSet.new(exposed, &to_string(&1.name()))

      for module <- @session_graph_syscalls do
        name = to_string(module.name())

        assert Actions.pipeline_internal_action?(module),
               "#{inspect(module)} is a graph syscall and must be pipeline_internal"

        refute module in exposed,
               "#{inspect(module)} leaked into exposed_actions/0 (APIAgent / DOT-session catalog)"

        refute name in exposed_names
      end

      for module <- Actions.dual_use_graph_actions() do
        name = to_string(module.name())
        schema = schema_name(module.to_tool())

        assert module in exposed,
               "#{inspect(module)} is dual-use and must remain in exposed_actions/0"

        assert name in exposed_names
        assert schema == name
      end
    end

    test "DOT-session catalog primitive never lists session_goals/exec/llm syscalls" do
      # ToolDisclosure.profile_tools/1 enumerates Arbor.Actions.exposed_actions/0.
      names =
        Actions.exposed_actions()
        |> Enum.map(&to_string(&1.name()))
        |> MapSet.new()

      refute "session_goals_update" in names
      refute "session_goals_store_decomps" in names
      refute "session_goals_process_proposals" in names
      refute "session_goals_store_identity" in names
      refute "session_goals_prune_stale_intents" in names
      refute "session_exec_route_actions" in names
      refute "session_exec_execute_actions" in names
      refute "session_llm_build_prompt" in names

      assert "file_read" in names
      assert "mix_test" in names
      assert "web_search" in names
    end

    test "security regression: stale indexed pipeline_internal session syscalls stay undisclosed" do
      refute Process.whereis(CapabilityIndex)
      start_supervised!({CapabilityIndex, providers: [StaleSessionGraphSyscallProvider]})

      for query <- [
            "session goals update",
            "session exec route actions",
            "session llm build prompt"
          ] do
        assert {:ok, %{discovered_tool_names: names}} =
                 Actions.Tool.FindTools.run(%{query: query, limit: 10}, %{})

        refute "session_goals_update" in names
        refute "session_exec_route_actions" in names
        refute "session_llm_build_prompt" in names
      end
    end
  end

  defp inventory_dot_action_targets do
    targets =
      repo_root()
      |> pipeline_dot_files()
      |> Enum.flat_map(&dot_action_targets/1)
      |> Enum.uniq()
      |> Enum.sort()

    resolved =
      Enum.flat_map(targets, fn target ->
        case Actions.name_to_module(target) do
          {:ok, module} -> [{target, module}]
          {:error, :unknown_action} -> []
        end
      end)

    {targets, resolved}
  end

  defp pipeline_dot_files(repo_root) do
    ["apps/*/priv/**/*.dot", "apps/*/specs/**/*.dot"]
    |> Enum.flat_map(&Path.wildcard(Path.join(repo_root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
  end

  defp dot_action_targets(path) do
    path
    |> File.read!()
    |> then(&Regex.scan(@action_attr, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp repo_root do
    case Mix.Project.project_file() do
      path when is_binary(path) ->
        Path.expand("../..", Path.dirname(path))

      _ ->
        Path.expand("../../../../..", __DIR__)
    end
  end

  defp schema_name(tool) when is_map(tool) do
    to_string(Map.get(tool, :name) || Map.get(tool, "name") || "")
  end

  defp schema_name(_), do: ""
end
