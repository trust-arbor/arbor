defmodule Arbor.Gateway.MCP.Handler do
  @moduledoc """
  MCP server handler for Arbor.

  Provides 4 progressive-disclosure tools for interacting with Arbor:

  - `arbor_actions` — List action categories and tool names (compact overview)
  - `arbor_help` — Get detailed schema/description for a specific action
  - `arbor_run` — Execute an action with parameters
  - `arbor_status` — Inspect agent, memory, and signal state

  Uses runtime bridges (`Code.ensure_loaded?` + `apply/3`) to call into
  arbor_actions, arbor_agent, arbor_memory, and arbor_signals without
  compile-time dependencies (arbor_gateway is Level 2, same as those apps).
  """

  use ExMCP.Server.Handler

  require Logger

  @server_name "arbor"
  @server_version "0.1.0"

  # ===========================================================================
  # Handler Callbacks
  # ===========================================================================

  # init/1 and terminate/2 use defaults from `use ExMCP.Server.Handler`
  # (which injects `use GenServer`). Explicitly defining them here with
  # @impl GenServer triggers "conflicting behaviours" warnings in Elixir 1.19+.

  @impl ExMCP.Server.Handler
  def handle_initialize(params, state) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || "2024-11-05",
       serverInfo: %{name: @server_name, version: @server_version},
       capabilities: %{
         tools: %{}
       }
     }, state}
  end

  @impl ExMCP.Server.Handler
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        name: "arbor_actions",
        description:
          "List all available Arbor action categories and their tools. " <>
            "Returns a compact overview — use arbor_help to get details on a specific action.",
        inputSchema: %{
          type: "object",
          properties: %{
            category: %{
              type: "string",
              description:
                "Optional: filter to a specific category (e.g. 'shell', 'file', 'git', 'memory')"
            }
          }
        }
      },
      %{
        name: "arbor_help",
        description:
          "Get detailed help for a specific Arbor action, including its parameter schema, " <>
            "description, taint roles, and examples.",
        inputSchema: %{
          type: "object",
          properties: %{
            action: %{
              type: "string",
              description:
                "The action name (e.g. 'shell_execute', 'file_read', 'memory_remember')"
            }
          },
          required: ["action"]
        }
      },
      %{
        name: "arbor_run",
        description:
          "Execute an Arbor action. Use arbor_help first to check the required parameters.",
        inputSchema: %{
          type: "object",
          properties: %{
            action: %{
              type: "string",
              description: "The action name to execute (e.g. 'shell_execute')"
            },
            params: %{
              type: "object",
              description: "Parameters to pass to the action"
            },
            agent_id: %{
              type: "string",
              description:
                "Optional: agent ID for authorization. If omitted, executes without auth check."
            }
          },
          required: ["action", "params"]
        }
      },
      %{
        name: "arbor_status",
        description:
          "Inspect Arbor system state: running agents, memory contents, signal activity, " <>
            "trust tiers, and capabilities.",
        inputSchema: %{
          type: "object",
          properties: %{
            component: %{
              type: "string",
              description:
                "What to inspect: 'agents', 'memory', 'signals', 'capabilities', 'goals', 'pipelines', 'overview'",
              enum: ["agents", "memory", "signals", "capabilities", "goals", "pipelines", "overview"]
            },
            agent_id: %{
              type: "string",
              description: "Optional: filter to a specific agent's state"
            }
          },
          required: ["component"]
        }
      }
    ]

    {:ok, tools, nil, state}
  end

  @impl ExMCP.Server.Handler
  def handle_call_tool("arbor_actions", args, state) do
    category = args["category"]
    result = list_actions(category)
    {:ok, %{content: [%{type: "text", text: result}]}, state}
  end

  def handle_call_tool("arbor_help", args, state) do
    action_name = args["action"]
    result = get_action_help(action_name)
    {:ok, %{content: [%{type: "text", text: result}]}, state}
  end

  def handle_call_tool("arbor_run", args, state) do
    action_name = args["action"]
    params = args["params"] || %{}
    agent_id = args["agent_id"]
    result = run_action(action_name, params, agent_id)
    {:ok, %{content: [%{type: "text", text: result}]}, state}
  end

  def handle_call_tool("arbor_status", args, state) do
    component = args["component"]
    agent_id = args["agent_id"]
    result = get_status(component, agent_id)
    {:ok, %{content: [%{type: "text", text: result}]}, state}
  end

  def handle_call_tool(name, _args, state) do
    {:ok,
     %{
       content: [%{type: "text", text: "Unknown tool: #{name}"}],
       isError: true
     }, state}
  end

  # ===========================================================================
  # Tool Implementations
  # ===========================================================================

  defp list_actions(nil) do
    case call_actions(:list_actions, []) do
      {:ok, actions_map} ->
        actions_map
        |> Enum.sort_by(fn {category, _} -> category end)
        |> Enum.map_join("\n\n", fn {category, modules} ->
          tool_names =
            modules
            |> Enum.map(fn mod ->
              try do
                "  - #{mod.name()}: #{truncate(mod.description(), 80)}"
              rescue
                _ -> "  - #{inspect(mod)}"
              end
            end)
            |> Enum.join("\n")

          "## #{category}\n#{tool_names}"
        end)
        |> then(&("# Arbor Actions\n\n" <> &1))

      {:error, reason} ->
        "Error listing actions: #{inspect(reason)}"
    end
  end

  defp list_actions(category) do
    category_atom =
      try do
        String.to_existing_atom(category)
      rescue
        _ -> nil
      end

    case call_actions(:list_actions, []) do
      {:ok, actions_map} ->
        case Map.get(actions_map, category_atom) do
          nil ->
            categories = actions_map |> Map.keys() |> Enum.sort() |> Enum.join(", ")
            "Unknown category '#{category}'. Available: #{categories}"

          modules ->
            modules
            |> Enum.map_join("\n\n", fn mod ->
              try do
                "### #{mod.name()}\n#{mod.description()}"
              rescue
                _ -> "### #{inspect(mod)}"
              end
            end)
            |> then(&("# #{category} actions\n\n" <> &1))
        end

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  defp get_action_help(action_name) do
    case find_action_module(action_name) do
      {:ok, mod} ->
        sections = [
          "# #{action_name}",
          "",
          try_call(mod, :description, [], "No description"),
          "",
          "## Parameters",
          format_schema(try_call(mod, :schema, [], [])),
          "",
          "## Taint Roles",
          format_taint_roles(try_call(mod, :taint_roles, [], %{})),
          "",
          "## Category: #{try_call(mod, :category, [], "unknown")}",
          "## Tags: #{try_call(mod, :tags, [], []) |> Enum.join(", ")}"
        ]

        Enum.join(sections, "\n")

      {:error, :not_found} ->
        "Action '#{action_name}' not found. Use arbor_actions to list available actions."
    end
  end

  defp run_action(action_name, params, agent_id) do
    case find_action_module(action_name) do
      {:ok, mod} ->
        # Atomize known param keys for the action
        atom_params = atomize_params(params)

        result =
          if agent_id do
            call_actions(:authorize_and_execute, [agent_id, mod, atom_params, %{}])
          else
            call_actions(:execute_action, [mod, atom_params, %{}])
          end

        case result do
          {:ok, {:ok, value}} ->
            "## Success\n\n#{format_result(value)}"

          {:ok, {:error, :unauthorized}} ->
            "## Unauthorized\n\nAgent '#{agent_id}' lacks permission for #{action_name}."

          {:ok, {:error, reason}} ->
            "## Error\n\n#{inspect(reason)}"

          {:ok, {:ok, :pending_approval, proposal_id}} ->
            "## Pending Approval\n\nProposal #{proposal_id} created. Awaiting consensus."

          {:error, reason} ->
            "## Error\n\n#{inspect(reason)}"
        end

      {:error, :not_found} ->
        "Action '#{action_name}' not found. Use arbor_actions to list available actions."
    end
  end

  defp get_status("overview", _agent_id) do
    sections = [
      "# Arbor System Status",
      "",
      "## Agents",
      get_agent_summary(),
      "",
      "## Memory",
      get_memory_summary(),
      "",
      "## Signals",
      get_signal_summary(),
      "",
      get_pipeline_status()
    ]

    Enum.join(sections, "\n")
  end

  defp get_status("agents", agent_id) do
    if agent_id do
      get_agent_detail(agent_id)
    else
      "# Running Agents\n\n" <> get_agent_summary()
    end
  end

  defp get_status("memory", agent_id) do
    agent_id = agent_id || find_first_agent_id()

    if agent_id do
      get_memory_detail(agent_id)
    else
      "No agent running. Cannot inspect memory without an agent_id."
    end
  end

  defp get_status("signals", _agent_id) do
    "# Signal Activity\n\n" <> get_signal_summary()
  end

  defp get_status("capabilities", agent_id) do
    agent_id = agent_id || find_first_agent_id()

    if agent_id do
      get_capabilities(agent_id)
    else
      "No agent running. Cannot inspect capabilities without an agent_id."
    end
  end

  defp get_status("goals", agent_id) do
    agent_id = agent_id || find_first_agent_id()

    if agent_id do
      get_goals(agent_id)
    else
      "No agent running. Cannot inspect goals without an agent_id."
    end
  end

  defp get_status("pipelines", _agent_id) do
    get_pipeline_status()
  end

  defp get_status(component, _agent_id) do
    "Unknown component '#{component}'. Use: agents, memory, signals, capabilities, goals, pipelines, overview"
  end

  # ===========================================================================
  # Status Helpers
  # ===========================================================================

  defp get_agent_summary do
    case bridge_call(Arbor.Agent.Registry, :list, []) do
      {:ok, {:ok, agents}} when is_list(agents) ->
        format_agent_list(agents)

      # Registry.list/0 returns {:ok, list} not {:ok, {:ok, list}}
      {:ok, agents} when is_list(agents) ->
        format_agent_list(agents)

      _ ->
        # Try AgentManager
        case bridge_call(Arbor.Dashboard.AgentManager, :list_agents, []) do
          {:ok, agents} when is_list(agents) ->
            if agents == [] do
              "No agents running."
            else
              Enum.map_join(agents, "\n", fn {id, pid} ->
                "- #{id} (#{inspect(pid)})"
              end)
            end

          _ ->
            "Agent registry unavailable."
        end
    end
  end

  defp format_agent_list([]), do: "No agents running."

  defp format_agent_list(agents) do
    Enum.map_join(agents, "\n", fn agent ->
      id = extract_agent_id(agent)
      name = if is_map(agent), do: get_in(agent, [:metadata, :display_name]), else: nil

      if name do
        "- #{name} (`#{id}`)"
      else
        "- #{id}"
      end
    end)
  end

  defp get_agent_detail(agent_id) do
    sections = ["# Agent: #{agent_id}", ""]

    # Try to get profile
    profile =
      case bridge_call(Arbor.Agent.Profile, :load, [agent_id]) do
        {:ok, {:ok, profile}} -> format_map(Map.from_struct(profile))
        _ -> "Profile unavailable."
      end

    caps = get_capabilities(agent_id)
    goals = get_goals(agent_id)

    Enum.join(sections ++ ["## Profile", profile, "", caps, "", goals], "\n")
  end

  defp get_memory_detail(agent_id) do
    sections = ["# Memory: #{agent_id}", ""]

    # Working memory
    wm =
      case bridge_call(Arbor.Memory, :load_working_memory, [agent_id]) do
        {:ok, wm} when is_map(wm) ->
          wm
          |> Map.take([:notes, :recent_actions, :context])
          |> format_map()

        _ ->
          "Working memory unavailable."
      end

    # Self knowledge
    sk =
      case bridge_call(Arbor.Memory, :load_self_knowledge, [agent_id]) do
        {:ok, sk} when is_map(sk) ->
          sk
          |> Map.take([:insights, :preferences, :learned_patterns])
          |> format_map()

        _ ->
          "Self-knowledge unavailable."
      end

    Enum.join(
      sections ++ ["## Working Memory", wm, "", "## Self-Knowledge", sk],
      "\n"
    )
  end

  defp get_memory_summary do
    agent_id = find_first_agent_id()

    if agent_id do
      case bridge_call(Arbor.Memory, :load_working_memory, [agent_id]) do
        {:ok, wm} when is_map(wm) ->
          notes = Map.get(wm, :notes, [])
          "Agent #{agent_id}: #{length(notes)} notes in working memory"

        _ ->
          "Memory system unavailable."
      end
    else
      "No agent running."
    end
  end

  defp get_signal_summary do
    case bridge_call(Arbor.Signals.Bus, :stats, []) do
      {:ok, stats} when is_map(stats) ->
        format_map(stats)

      _ ->
        # Fallback: check if signal system is running
        case bridge_call(Arbor.Signals, :healthy?, []) do
          {:ok, true} -> "Signal bus is running (detailed stats unavailable)."
          {:ok, false} -> "Signal bus is unhealthy."
          _ -> "Signal system unavailable."
        end
    end
  end

  defp get_capabilities(agent_id) do
    case bridge_call(Arbor.Security, :list_capabilities, [agent_id, []]) do
      {:ok, {:ok, caps}} when is_list(caps) ->
        if caps == [] do
          "## Capabilities\nNo capabilities granted."
        else
          cap_list =
            Enum.map_join(caps, "\n", fn cap ->
              resource =
                cond do
                  is_binary(cap) -> cap
                  is_map(cap) -> Map.get(cap, :resource, Map.get(cap, "resource", inspect(cap)))
                  true -> inspect(cap)
                end

              "- #{resource}"
            end)

          "## Capabilities\n#{cap_list}"
        end

      {:ok, caps} when is_list(caps) ->
        "## Capabilities\n#{Enum.map_join(caps, "\n", &"- #{inspect(&1)}")}"

      _ ->
        "## Capabilities\nSecurity system unavailable."
    end
  end

  defp get_goals(agent_id) do
    case bridge_call(Arbor.Memory.GoalStore, :get_active_goals, [agent_id]) do
      {:ok, goals} when is_list(goals) ->
        if goals == [] do
          "## Goals\nNo active goals."
        else
          goal_list =
            Enum.map_join(goals, "\n", fn goal ->
              desc =
                cond do
                  is_map(goal) and Map.has_key?(goal, :description) -> goal.description
                  is_map(goal) and Map.has_key?(goal, "description") -> goal["description"]
                  true -> inspect(goal)
                end

              progress =
                cond do
                  is_map(goal) and Map.has_key?(goal, :progress) ->
                    " (#{Float.round(goal.progress * 100, 1)}%)"

                  true ->
                    ""
                end

              "- #{desc}#{progress}"
            end)

          "## Goals\n#{goal_list}"
        end

      _ ->
        "## Goals\nGoal store unavailable."
    end
  end

  defp get_pipeline_status do
    if Code.ensure_loaded?(Arbor.Orchestrator.JobRegistry) do
      active = apply(Arbor.Orchestrator.JobRegistry, :list_active, [])
      recent = apply(Arbor.Orchestrator.JobRegistry, :list_recent, [])
      format_pipeline_status(active, recent)
    else
      "Pipeline registry not available (orchestrator not started)"
    end
  rescue
    _ -> "Pipeline registry unavailable"
  catch
    :exit, _ -> "Pipeline registry unavailable"
  end

  defp format_pipeline_status(active, recent) do
    sections = []

    sections =
      if active != [] do
        header =
          "## Active Pipelines\n\n| Pipeline | Progress | Current Node | Elapsed |\n|----------|----------|--------------|---------|\n"

        rows =
          Enum.map_join(active, "\n", fn entry ->
            elapsed =
              if entry.started_at,
                do: DateTime.diff(DateTime.utc_now(), entry.started_at, :second),
                else: 0

            progress = "#{entry.completed_count || 0}/#{entry.total_nodes || "?"}"

            "| #{entry.graph_id || entry.pipeline_id} | #{progress} | #{entry.current_node || "-"} | #{elapsed}s |"
          end)

        sections ++ [header <> rows]
      else
        sections ++ ["## Active Pipelines\n\nNo pipelines currently running."]
      end

    sections =
      if recent != [] do
        header =
          "\n\n## Recent Pipelines\n\n| Pipeline | Status | Duration | Finished |\n|----------|--------|----------|----------|\n"

        rows =
          Enum.map_join(Enum.take(recent, 10), "\n", fn entry ->
            status = to_string(entry.status || :unknown)
            duration = if entry.duration_ms, do: "#{div(entry.duration_ms, 1000)}s", else: "-"
            finished = if entry.finished_at, do: Calendar.strftime(entry.finished_at, "%H:%M:%S"), else: "-"
            "| #{entry.graph_id || entry.pipeline_id} | #{status} | #{duration} | #{finished} |"
          end)

        sections ++ [header <> rows]
      else
        sections
      end

    Enum.join(sections, "\n")
  end

  # ===========================================================================
  # Runtime Bridges
  # ===========================================================================

  defp call_actions(function, args) do
    bridge_call(Arbor.Actions, function, args)
  end

  defp bridge_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      try do
        {:ok, apply(module, function, args)}
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    else
      {:error, {:module_not_loaded, module}}
    end
  end

  defp find_action_module(action_name) do
    case call_actions(:all_actions, []) do
      {:ok, modules} when is_list(modules) ->
        found =
          Enum.find(modules, fn mod ->
            try do
              mod.name() == action_name
            rescue
              _ -> false
            end
          end)

        if found, do: {:ok, found}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp find_first_agent_id do
    case bridge_call(Arbor.Agent.Registry, :list, []) do
      {:ok, {:ok, [first | _]}} ->
        extract_agent_id(first)

      {:ok, [first | _]} when is_map(first) ->
        extract_agent_id(first)

      _ ->
        # Try dashboard AgentManager
        case bridge_call(Arbor.Dashboard.AgentManager, :list_agents, []) do
          {:ok, [{id, _pid} | _]} -> id
          _ -> nil
        end
    end
  end

  defp extract_agent_id(agent) when is_map(agent) do
    Map.get(agent, :agent_id) || Map.get(agent, :id) || inspect(agent)
  end

  defp extract_agent_id(agent), do: to_string(agent)

  # ===========================================================================
  # Formatting Helpers
  # ===========================================================================

  defp format_schema(schema) when is_list(schema) do
    schema
    |> Enum.map_join("\n", fn {name, opts} ->
      type = Keyword.get(opts, :type, :any)
      required = if Keyword.get(opts, :required, false), do: " (required)", else: ""

      default =
        if Keyword.has_key?(opts, :default),
          do: " [default: #{inspect(Keyword.get(opts, :default))}]",
          else: ""

      doc = if Keyword.has_key?(opts, :doc), do: " — #{Keyword.get(opts, :doc)}", else: ""
      "- `#{name}`: #{inspect(type)}#{required}#{default}#{doc}"
    end)
  end

  defp format_schema(_), do: "No schema available."

  defp format_taint_roles(roles) when is_map(roles) and map_size(roles) > 0 do
    roles
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, role} ->
      "- `#{name}`: #{role}"
    end)
  end

  defp format_taint_roles(_), do: "No taint roles defined."

  defp format_result(result) when is_map(result) do
    result
    |> inspect(pretty: true, limit: 50, printable_limit: 2000)
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result, pretty: true, limit: 50)

  defp format_map(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n", fn {k, v} ->
      "- **#{k}**: #{truncate(inspect(v, limit: 20), 200)}"
    end)
  end

  defp format_map(other), do: inspect(other)

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _max), do: str

  defp atomize_params(params) when is_map(params) do
    # Only convert to existing atoms to avoid atom table DoS (CLAUDE.md: SafeAtom)
    Map.new(params, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            _ -> k
          end

        {atom_key, v}

      {k, v} ->
        {k, v}
    end)
  end

  defp atomize_params(params), do: params

  defp try_call(mod, fun, args, default) do
    if function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  rescue
    _ -> default
  end
end
