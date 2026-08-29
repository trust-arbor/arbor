defmodule Arbor.Actions.PipelineInternalGraphSyscallGuardTest do
  @moduledoc """
  Standing guard: every registered action used as a DOT graph syscall is
  either tagged `pipeline_internal` or explicitly allowlisted as dual-use.

  DOT targets are derived from Git-tracked pipeline files
  (`apps/*/priv/**/*.dot` and `apps/*/specs/**/*.dot`). Inventory fails
  closed when Git (or the contained source-inventory manifest) cannot be
  established, and unresolved `action=` targets fail the suite.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions
  alias Arbor.Actions.SessionExecution
  alias Arbor.Actions.SessionGoals
  alias Arbor.Actions.SessionLlm
  alias Arbor.Common.CapabilityIndex
  alias Arbor.Contracts.Coding.SourceInventory

  @action_attr ~r/(?<![A-Za-z0-9_.])action\s*=\s*["']([^"']+)["']/
  @repo_root Path.expand("../../../../..", __DIR__)

  @session_graph_syscalls [
    SessionGoals.UpdateGoals,
    SessionGoals.StoreDecompositions,
    SessionGoals.ProcessProposalDecisions,
    SessionGoals.StoreIdentity,
    SessionGoals.PruneStaleIntents,
    SessionExecution.RouteActions,
    SessionExecution.ExecuteActions,
    SessionLlm.BuildPrompt,
    Actions.SessionMemory.Recall,
    Actions.SessionMemory.Update,
    Actions.SessionMemory.Checkpoint,
    Actions.SessionMemory.Consolidate,
    Actions.SessionMemory.UpdateWorkingMemory,
    Actions.SessionMemory.BackgroundChecks,
    Actions.Session.Classify,
    Actions.Session.ModeSelect,
    Actions.Session.ProcessResults
  ]

  # Test-owned dual-use allowlist. Direct agent use is justified by tool
  # schema plus non-graph call sites (APIAgent/MCP/Agent.Capabilities).
  # Graph-only syscalls must carry `pipeline_internal` instead of appearing here.
  @dual_use_graph_actions [
    # File I/O — Agent.Capabilities fs.read/write and MCP tool exposure;
    # also example and scheduler pipeline nodes.
    Arbor.Actions.File.Read,
    Arbor.Actions.File.Write,
    # Mix test runner — conversational mix_test tool and TDD/code-review nodes.
    Arbor.Actions.Mix.Test,
    # Git/GitHub — agent VCS catalog (Git.Commit in Agent.Capabilities;
    # branch/PR in git/github tools) and code-review/coding pipeline nodes.
    Arbor.Actions.Git.Branch,
    Arbor.Actions.Git.Commit,
    Arbor.Actions.Git.PR,
    Arbor.Actions.Github.PR,
    # Web search — Agent.Capabilities web.search plus scheduler trend pipelines.
    Arbor.Actions.Web.Search,
    Arbor.Actions.Web.ExaSearch,
    Arbor.Actions.Web.TinyfishSearch,
    # ACP sessions — Agent.Capabilities physical acp.* tools and coding-change
    # pipeline worker sessions.
    Arbor.Actions.Acp.StartSession,
    Arbor.Actions.Acp.SendMessage,
    Arbor.Actions.Acp.SessionStatus,
    Arbor.Actions.Acp.CloseSession
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
      allowlisted = MapSet.new(@dual_use_graph_actions)

      untagged =
        resolved
        |> Enum.map(fn {_target, module} -> module end)
        |> Enum.uniq()
        |> Enum.reject(&Actions.pipeline_internal_action?/1)
        |> Enum.reject(&MapSet.member?(allowlisted, &1))
        |> Enum.sort()

      assert untagged == [],
             "DOT graph syscalls missing pipeline_internal (add the tag, or review into the test-owned dual-use allowlist): " <>
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

    test "dual-use allowlist modules are registered, inventoried, and disjoint from pipeline_internal" do
      {_targets, resolved} = inventory_dot_action_targets()
      inventoried = MapSet.new(resolved, fn {_target, module} -> module end)
      registered = MapSet.new(Actions.all_actions())

      for module <- @dual_use_graph_actions do
        assert module in registered,
               "#{inspect(module)} is allowlisted as dual-use but is not in all_actions/0"

        assert MapSet.member?(inventoried, module),
               "#{inspect(module)} is allowlisted as dual-use but is not a tracked DOT action= target"

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

      for module <- @dual_use_graph_actions do
        name = to_string(module.name())
        schema = schema_name(module.to_tool())

        assert module in exposed,
               "#{inspect(module)} is dual-use and must remain in exposed_actions/0"

        assert name in exposed_names
        assert schema == name
      end
    end

    test "DOT-session catalog primitive never lists session_goals/exec/llm syscalls" do
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
      @repo_root
      |> pipeline_dot_files()
      |> Enum.flat_map(&dot_action_targets/1)
      |> Enum.uniq()
      |> Enum.sort()

    resolved =
      Enum.flat_map(targets, fn target ->
        case Actions.name_to_module(target) do
          {:ok, module} when is_atom(module) ->
            [{target, module}]

          {:error, :unknown_action} ->
            []

          other ->
            flunk(
              "Arbor.Actions.name_to_module/1 returned unexpected result for #{inspect(target)}: " <>
                inspect(other)
            )
        end
      end)

    {targets, resolved}
  end

  defp pipeline_dot_files(repo_root) do
    case tracked_pipeline_dot_relpaths(repo_root, inventory_env_from_system()) do
      {:ok, relpaths} ->
        abs_paths = Enum.map(relpaths, &Path.join(repo_root, &1))
        missing = Enum.reject(abs_paths, &File.regular?/1)

        if missing == [] do
          Enum.sort(abs_paths)
        else
          flunk(
            "Git-tracked pipeline files are missing or not regular files: " <> inspect(missing)
          )
        end

      {:error, reason} ->
        flunk("failed to establish Git-tracked pipeline inventory: #{inspect(reason)}")
    end
  end

  defp tracked_pipeline_dot_relpaths(root, env) when is_binary(root) and is_map(env) do
    case Map.get(env, "ARBOR_MIX_CONTAINED") do
      "1" -> contained_tracked_pipeline_dot_relpaths(env)
      _ -> git_tracked_pipeline_dot_relpaths(root)
    end
  end

  defp git_tracked_pipeline_dot_relpaths(root) when is_binary(root) do
    try do
      case System.cmd("git", ["ls-files", "-z", "--", "apps"],
             cd: root,
             stderr_to_stdout: true
           ) do
        {output, 0} when is_binary(output) ->
          relpaths =
            output
            |> String.split(<<0>>, trim: true)
            |> Enum.filter(&tracked_pipeline_dot_path?/1)
            |> Enum.sort()

          {:ok, relpaths}

        {output, code} ->
          {:error, {:git_ls_files_failed, code, output}}
      end
    rescue
      error -> {:error, {:git_ls_files_failed, error}}
    catch
      kind, reason -> {:error, {:git_ls_files_failed, {kind, reason}}}
    end
  end

  defp contained_tracked_pipeline_dot_relpaths(env) when is_map(env) do
    case resolve_source_inventory_path(env) do
      {:error, reason} ->
        {:error, {:contained_inventory, reason, :before_filesystem}}

      {:ok, path} ->
        max_bytes = SourceInventory.max_encoded_bytes()

        with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
             :ok <- admit_manifest_byte_size(size, max_bytes),
             {:ok, bytes} <- File.read(path),
             {:ok, decoded} <- Jason.decode(bytes),
             {:ok, inventory} <- SourceInventory.new(decoded) do
          relpaths =
            inventory
            |> SourceInventory.paths()
            |> Enum.filter(&tracked_pipeline_dot_path?/1)
            |> Enum.sort()

          {:ok, relpaths}
        else
          {:error, :enoent} ->
            {:error, {:contained_inventory, :enoent, path}}

          {:error, :oversized_manifest} ->
            {:error, {:contained_inventory, :oversized_manifest, path}}

          {:error, reason} ->
            {:error, {:contained_inventory, reason, path}}

          other ->
            {:error, {:contained_inventory, other, path}}
        end
    end
  end

  defp admit_manifest_byte_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size >= 0 and max_bytes > 0 do
    if size <= max_bytes, do: :ok, else: {:error, :oversized_manifest}
  end

  defp admit_manifest_byte_size(_size, _max_bytes), do: {:error, :oversized_manifest}

  defp resolve_source_inventory_path(env) when is_map(env) do
    case Map.fetch(env, "ARBOR_SOURCE_INVENTORY_PATH") do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      {:ok, _value} -> {:error, :invalid_inventory_path}
      :error -> {:error, :missing_inventory_path}
    end
  end

  defp inventory_env_from_system do
    %{}
    |> put_env_if_present("ARBOR_MIX_CONTAINED")
    |> put_env_if_present("ARBOR_SOURCE_INVENTORY_PATH")
  end

  defp put_env_if_present(env, key) do
    case System.get_env(key) do
      nil -> env
      value -> Map.put(env, key, value)
    end
  end

  defp tracked_pipeline_dot_path?(path) when is_binary(path) do
    String.ends_with?(path, ".dot") and
      case Path.split(path) do
        ["apps", app, "priv" | rest] -> valid_app_name?(app) and rest != []
        ["apps", app, "specs" | rest] -> valid_app_name?(app) and rest != []
        _ -> false
      end
  end

  defp tracked_pipeline_dot_path?(_path), do: false

  defp valid_app_name?(app) when is_binary(app) do
    app != "" and app != "." and app != ".." and not String.contains?(app, "/")
  end

  defp valid_app_name?(_app), do: false

  defp dot_action_targets(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> then(&Regex.scan(@action_attr, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, reason} ->
        flunk("failed to read tracked pipeline file #{path}: #{inspect(reason)}")
    end
  end

  defp schema_name(tool) when is_map(tool) do
    to_string(Map.get(tool, :name) || Map.get(tool, "name") || "")
  end

  defp schema_name(_), do: ""
end
