defmodule Arbor.Actions.Agent.SpawnWorker do
  @moduledoc """
  Spawn an ephemeral worker subagent with narrowly scoped capabilities.

  The parent agent describes what the worker needs to do and what capabilities
  it requires. The worker gets a trust profile that is the intersection of the
  parent's permissions and the requested capabilities — it can never have more
  access than its parent.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `task` | string | yes | What the worker should do |
  | `capabilities` | list(string) | yes | Capability intents (e.g., "file read", "web search") |
  | `system_prompt` | string | no | Custom system prompt for the worker |
  | `max_tokens` | integer | no | Token budget for the worker (default: 8000) |
  | `timeout` | integer | no | Timeout in ms (default: 60000) |
  | `max_turns` | integer | no | Max tool-call turns (default: 10) |
  | `context` | string | no | Additional context to pass to the worker |

  ## Authorization

  Requires `arbor://agent/spawn_worker` capability.

  ## Example

      spawn_worker(
        task: "Search the codebase for all uses of FileGuard.authorize",
        capabilities: ["file read", "file search"],
        max_tokens: 4000
      )
  """

  use Jido.Action,
    name: "agent_spawn_worker",
    description:
      "Spawn a temporary worker agent to perform a specific task. " <>
        "The worker gets ONLY the capabilities you request (e.g., 'file read', 'web search'). " <>
        "Use this to delegate research, analysis, or other focused tasks. " <>
        "The worker runs, returns its findings, and is automatically cleaned up.",
    category: "agent",
    tags: ["agent", "spawn", "worker", "delegation", "subagent"],
    schema: [
      task: [type: :string, required: true, doc: "What the worker should do"],
      capabilities: [
        type: {:list, :string},
        required: true,
        doc: "Capability intents: 'file read', 'web search', 'shell execute', etc."
      ],
      system_prompt: [type: :string, doc: "Custom system prompt for the worker"],
      max_tokens: [type: :integer, default: 8000, doc: "Token budget for the worker"],
      timeout: [type: :integer, default: 60_000, doc: "Timeout in milliseconds"],
      max_turns: [type: :integer, default: 10, doc: "Max tool-call turns"],
      context: [type: :string, doc: "Additional context to pass to the worker"]
    ]

  require Logger

  alias Arbor.Actions.Agent.WorkerSignals

  @lifecycle_mod Arbor.Agent.Lifecycle
  @api_agent_mod Arbor.Agent.APIAgent
  @resolver_mod Arbor.Common.CapabilityResolver
  @trust_mod Arbor.Trust
  @executor_registry Arbor.Agent.ExecutorRegistry

  @max_spawn_depth 1

  def taint_roles do
    %{task: :control, capabilities: :control, system_prompt: :control,
      context: :data, max_tokens: :data, timeout: :data, max_turns: :data}
  end

  @impl true
  def run(params, context) do
    agent_id = context[:agent_id]
    task = params[:task]
    capability_intents = params[:capabilities] || []
    timeout = params[:timeout] || 60_000
    _max_tokens = params[:max_tokens] || 8000

    Arbor.Actions.emit_started(__MODULE__, %{task: String.slice(task, 0..100)})

    with :ok <- check_depth(context),
         :ok <- check_resolver_available(),
         {:ok, scoped_rules} <- resolve_and_intersect(agent_id, capability_intents),
         {:ok, worker_id, _worker_sup, _tools} <- create_worker(scoped_rules, params, context),
         :ok <- WorkerSignals.started(agent_id, worker_id, task),
         {:ok, report} <- query_worker(worker_id, task, params, timeout, agent_id) do
      WorkerSignals.completed(agent_id, worker_id, report)

      # Async cleanup — don't block the parent on teardown
      cleanup_worker(worker_id, agent_id)

      Arbor.Actions.emit_completed(__MODULE__, %{
        worker_id: worker_id,
        duration_ms: report.duration_ms,
        tool_calls: length(report.tool_calls)
      })

      {:ok, format_report(report)}
    else
      {:error, reason} ->
        WorkerSignals.failed(agent_id, nil, reason)
        Arbor.Actions.emit_failed(__MODULE__, %{reason: inspect(reason)})
        {:error, format_error(reason)}
    end
  end

  # ── Depth limiting ───────────────────────────────────────────────

  defp check_depth(context) do
    depth = Map.get(context, :spawn_depth, 0)

    if depth < @max_spawn_depth do
      :ok
    else
      {:error, {:max_spawn_depth, depth, @max_spawn_depth}}
    end
  end

  defp check_resolver_available do
    if Code.ensure_loaded?(@resolver_mod) do
      :ok
    else
      {:error, :resolver_unavailable}
    end
  end

  # ── Intent resolution + trust intersection ───────────────────────

  defp resolve_and_intersect(agent_id, intents) do
    # Step 1: Resolve intents to capability URIs via CapabilityResolver
    resolved_uris =
      intents
      |> Enum.flat_map(fn intent ->
        @resolver_mod.search(intent, limit: 1, kind: :action)
        |> Enum.map(fn match -> match.descriptor.metadata[:capability_uri] end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if resolved_uris == [] do
      {:error, {:no_capabilities_resolved, intents}}
    else
      # Step 2: Intersect with parent's trust profile
      intersect_with_parent(agent_id, resolved_uris)
    end
  end

  defp intersect_with_parent(agent_id, requested_uris) do
    if Code.ensure_loaded?(@trust_mod) and
         function_exported?(@trust_mod, :get_trust_profile, 1) do
      case apply(@trust_mod, :get_trust_profile, [agent_id]) do
        {:ok, parent_profile} ->
          rules =
            Map.new(requested_uris, fn uri ->
              # Check parent's effective mode for this URI
              parent_mode = resolve_parent_mode(parent_profile, uri)
              {uri, parent_mode}
            end)
            |> Enum.reject(fn {_uri, mode} -> mode == :block end)
            |> Map.new()

          if map_size(rules) == 0 do
            {:error, {:no_capabilities_allowed, requested_uris}}
          else
            {:ok, rules}
          end

        {:error, :not_found} ->
          # No trust profile — allow requested URIs as :auto (permissive fallback)
          {:ok, Map.new(requested_uris, fn uri -> {uri, :auto} end)}
      end
    else
      # Trust system unavailable — allow requested URIs
      {:ok, Map.new(requested_uris, fn uri -> {uri, :auto} end)}
    end
  rescue
    _ -> {:ok, Map.new(requested_uris, fn uri -> {uri, :auto} end)}
  end

  defp resolve_parent_mode(profile, uri) do
    # Check profile rules for this URI or its prefix
    case Map.get(profile.rules || %{}, uri) do
      nil ->
        # Try prefix match (e.g., "arbor://fs/read" matches "arbor://fs" rule)
        prefix_match =
          (profile.rules || %{})
          |> Enum.find(fn {rule_uri, _mode} ->
            String.starts_with?(uri, rule_uri)
          end)

        case prefix_match do
          {_prefix, mode} -> mode
          nil -> profile.baseline || :block
        end

      mode ->
        mode
    end
  end

  # ── Worker lifecycle ─────────────────────────────────────────────

  defp create_worker(scoped_rules, params, context) do
    parent_id = context[:agent_id]
    spawn_depth = Map.get(context, :spawn_depth, 0)

    # Create ephemeral identity
    worker_name = "worker-#{:erlang.unique_integer([:positive])}"

    create_opts = [
      template: Arbor.Agent.Templates.CouncilEvaluator,
      delegator_id: parent_id
    ]

    case apply(@lifecycle_mod, :create, [worker_name, create_opts]) do
      {:ok, profile} ->
        worker_id = profile.agent_id

        # Apply the scoped trust profile
        apply_scoped_trust(worker_id, scoped_rules)

        # Build system prompt
        system_prompt = params[:system_prompt] || default_worker_prompt(params)

        # Resolve the scoped URIs to explicit tool names so the worker
        # gets exactly the right tools without needing tool discovery
        explicit_tools = resolve_tools_for_uris(Map.keys(scoped_rules))

        # Start with session (for tool loop) but no heartbeat
        {default_provider, default_model} = resolve_defaults()

        start_opts = [
          provider: default_provider,
          model: default_model,
          start_heartbeat: false,
          system_prompt: system_prompt,
          tools: explicit_tools,
          session_timeout: 30_000,
          spawn_depth: spawn_depth + 1
        ]

        case apply(@lifecycle_mod, :start, [worker_id, start_opts]) do
          {:ok, sup_pid} ->
            WorkerSignals.spawned(parent_id, worker_id, Map.keys(scoped_rules), explicit_tools)
            {:ok, worker_id, sup_pid, explicit_tools}

          {:error, reason} ->
            # Cleanup failed start
            try do apply(@lifecycle_mod, :destroy, [worker_id]) rescue _ -> :ok end
            {:error, {:worker_start_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:worker_create_failed, reason}}
    end
  end

  defp apply_scoped_trust(worker_id, scoped_rules) do
    store = Arbor.Trust.Store

    if Code.ensure_loaded?(store) and function_exported?(store, :update_profile, 2) do
      rules =
        scoped_rules
        # Workers need orchestrator access for the session pipeline
        |> Map.put("arbor://orchestrator", :auto)
        # Block spawn_worker (no recursive spawning)
        |> Map.put("arbor://agent/spawn_worker", :block)

      apply(store, :update_profile, [
        worker_id,
        fn profile -> %{profile | baseline: :block, rules: rules} end
      ])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp default_worker_prompt(params) do
    context_section =
      case params[:context] do
        nil -> ""
        ctx -> "\n\n## Context\n#{ctx}"
      end

    cwd = File.cwd!()

    """
    You are a focused research worker. Complete the assigned task thoroughly
    and return your findings. Use your available tools to gather evidence.
    Be specific — cite file paths, line numbers, and exact code when relevant.

    ## Environment
    - Working directory: #{cwd}
    - Use relative paths (e.g., "apps/arbor_agent/lib/..."), not absolute paths
    - The project is an Elixir umbrella with apps in the apps/ directory
    #{context_section}
    """
  end

  # ── Query ────────────────────────────────────────────────────────

  defp query_worker(worker_id, task, params, timeout, _parent_id) do
    max_tokens = params[:max_tokens] || 8000

    # Find the APIAgent host via ExecutorRegistry
    case Registry.lookup(@executor_registry, {:host, worker_id}) do
      [{pid, _}] ->
        start_time = System.monotonic_time(:millisecond)

        # Query with timeout
        task_ref = Task.async(fn ->
          apply(@api_agent_mod, :query, [pid, task, [max_tokens: max_tokens]])
        end)

        case Task.yield(task_ref, timeout) || Task.shutdown(task_ref, :brutal_kill) do
          {:ok, {:ok, response}} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            text = response[:text] || Map.get(response, :text, "")
            usage = response[:usage] || Map.get(response, :usage, %{})
            tool_calls = response[:tool_calls] || Map.get(response, :tool_calls, [])

            {:ok, %{
              result: text,
              tool_calls: normalize_tool_calls(tool_calls),
              usage: usage,
              duration_ms: duration_ms,
              worker_id: worker_id
            }}

          {:ok, {:error, reason}} ->
            {:error, {:worker_query_failed, reason}}

          nil ->
            # Timeout — try to salvage partial results from the session
            duration_ms = System.monotonic_time(:millisecond) - start_time
            partial = extract_partial_results(worker_id)

            if partial != "" do
              Logger.info("[SpawnWorker] Worker timed out after #{timeout}ms, returning partial results")

              {:ok, %{
                result: partial <> "\n\n[Worker timed out after #{div(timeout, 1000)}s — returning partial results]",
                tool_calls: [],
                usage: %{},
                duration_ms: duration_ms,
                worker_id: worker_id,
                partial: true
              }}
            else
              {:error, {:worker_timeout, timeout}}
            end
        end

      [] ->
        {:error, :worker_host_not_found}
    end
  end

  # Try to extract partial results from a timed-out worker's session.
  # The session stores assistant messages from completed tool rounds.
  @branch_sup Arbor.Agent.BranchSupervisor

  defp extract_partial_results(worker_id) do
    if Code.ensure_loaded?(@branch_sup) do
      case apply(@branch_sup, :child_pids, [worker_id]) do
        %{session: session_pid} when is_pid(session_pid) and node(session_pid) == node() ->
          try do
            state = GenServer.call(session_pid, :get_state, 5_000)
            messages = Map.get(state, :messages, [])

            # Extract assistant messages (the worker's intermediate responses)
            messages
            |> Enum.filter(fn msg ->
              Map.get(msg, :role) == :assistant or Map.get(msg, "role") == "assistant"
            end)
            |> Enum.map(fn msg ->
              Map.get(msg, :content) || Map.get(msg, "content") || ""
            end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("\n\n")
          catch
            :exit, _ -> ""
          end

        _ ->
          ""
      end
    else
      ""
    end
  rescue
    _ -> ""
  end

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn
      %{name: name} = call -> %{tool: name, args: Map.get(call, :args, %{})}
      call when is_map(call) -> %{tool: Map.get(call, "name", "unknown"), args: Map.get(call, "args", %{})}
      _ -> %{tool: "unknown", args: %{}}
    end)
  end
  defp normalize_tool_calls(_), do: []

  # ── Cleanup ──────────────────────────────────────────────────────

  defp cleanup_worker(worker_id, parent_id) do
    # Async cleanup — destroy the ephemeral agent without blocking the parent
    Task.start(fn ->
      try do
        apply(@lifecycle_mod, :destroy, [worker_id])
        WorkerSignals.destroyed(parent_id, worker_id)
        Logger.debug("[SpawnWorker] Cleaned up worker #{worker_id}")
      rescue
        e -> Logger.warning("[SpawnWorker] Cleanup failed for #{worker_id}: #{Exception.message(e)}")
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # ── Result formatting ────────────────────────────────────────────

  defp format_report(report) do
    tool_summary =
      if report.tool_calls != [] do
        tools = Enum.map_join(report.tool_calls, ", ", & &1.tool)
        "\n\nTools used: #{tools}"
      else
        ""
      end

    cost = get_in(report, [:usage, :cost])
    cost_str = if cost, do: " ($#{Float.round(cost, 4)})", else: ""

    """
    #{report.result}

    ---
    Worker completed in #{report.duration_ms}ms#{cost_str}.#{tool_summary}
    """
  end

  defp format_error({:max_spawn_depth, depth, max}) do
    "Cannot spawn worker: spawn depth #{depth} exceeds maximum #{max}. Workers cannot spawn their own workers."
  end

  defp format_error({:no_capabilities_resolved, intents}) do
    "Could not resolve any capabilities from: #{Enum.join(intents, ", ")}. " <>
      "Try more specific terms like 'file read', 'web search', 'shell execute'."
  end

  defp format_error({:no_capabilities_allowed, uris}) do
    "Parent agent does not have permission for any of: #{Enum.join(uris, ", ")}. " <>
      "You can only delegate capabilities you already have."
  end

  defp format_error({:worker_timeout, timeout}) do
    "Worker timed out after #{div(timeout, 1000)} seconds."
  end

  defp format_error(other), do: inspect(other)

  # Map capability URIs to the tool names that fall under them.
  # Uses the ActionRegistry (name → module) + canonical URI map (module → URI).
  defp resolve_tools_for_uris(uris) do
    actions_mod = Module.concat([:Arbor, :Actions])
    registry_mod = Module.concat([:Arbor, :Common, :ActionRegistry])

    if Code.ensure_loaded?(actions_mod) and Code.ensure_loaded?(registry_mod) and
         function_exported?(registry_mod, :list_all, 0) and
         function_exported?(actions_mod, :tool_name_to_canonical_uri, 1) do
      apply(registry_mod, :list_all, [])
      |> Enum.filter(fn {name, _mod, _meta} ->
        # Skip underscore aliases (Jido format) — use dot format only
        String.contains?(name, ".")
      end)
      |> Enum.filter(fn {name, _mod, _meta} ->
        case apply(actions_mod, :tool_name_to_canonical_uri, [name]) do
          {:ok, tool_uri} ->
            Enum.any?(uris, fn uri ->
              tool_uri == uri or String.starts_with?(tool_uri, uri)
            end)

          _ ->
            false
        end
      end)
      |> Enum.map(fn {name, _mod, _meta} -> name end)
    else
      []
    end
  rescue
    _ -> []
  end

  # Runtime bridge for LLMDefaults (Level 2 module)
  defp resolve_defaults do
    defaults_mod = Arbor.Agent.LLMDefaults

    if Code.ensure_loaded?(defaults_mod) do
      provider = apply(defaults_mod, :default_provider, [])
      model = apply(defaults_mod, :default_model, [])
      {provider, model}
    else
      {:openrouter, "google/gemini-3-flash-preview"}
    end
  rescue
    _ -> {:openrouter, "google/gemini-3-flash-preview"}
  end
end
